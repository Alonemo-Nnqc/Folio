import Foundation

/// How Folio decides an agent is really on this Mac (AI-04). A configuration folder proves nothing: it
/// survives uninstalling, and other tools create them. An agent counts only when
///  - its app bundle is in an Applications folder and has its executable, or
///  - its command is an executable on the user's PATH (dangling symlinks fail) and answers `--version`.
///
/// An app opened from Finder does not get the PATH of the user's shell, so the PATH is read from a login,
/// interactive shell, as VS Code and Zed resolve their shell environment; Node-based CLIs (npm, nvm, Volta)
/// also need it to find `node` when they run.
enum ShellEnvironment {
    /// Folders where command-line agents are usually installed, searched after the shell's PATH.
    static func fallbackFolders(home: URL) -> [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", home.appending(path: ".local/bin").path,
         home.appending(path: ".npm-global/bin").path, home.appending(path: ".bun/bin").path,
         home.appending(path: ".volta/bin").path, home.appending(path: "Library/pnpm").path,
         home.appending(path: ".cargo/bin").path, home.appending(path: ".claude/local").path,
         home.appending(path: ".opencode/bin").path]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedLoginPATH: [String]?

    /// The PATH of the user's login shell, read once (until `reset()`); empty when the shell does not answer.
    static func loginPATH() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        if let cachedLoginPATH { return cachedLoginPATH }
        let path = readLoginPATH()
        cachedLoginPATH = path
        return path
    }

    /// Forget the cached PATH (设置 ▸ AI ▸ 重新检测: the user may just have installed something).
    static func reset() {
        lock.lock()
        cachedLoginPATH = nil
        lock.unlock()
    }

    private static func readLoginPATH() -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return [] }
        // Markers around the value: interactive shells may print greetings or prompts around it.
        let marker = "__FOLIO_PATH__"
        let print = shell.hasSuffix("/fish") ? "printf '\(marker)%s\(marker)' (string join : $PATH)"
            : "printf '\(marker)%s\(marker)' \"$PATH\""
        guard let result = CommandProbe.run(shell, ["-ilc", print], environment: nil, timeout: 5),
              let range = result.output.range(of: marker),
              let end = result.output.range(of: marker, range: range.upperBound..<result.output.endIndex) else { return [] }
        return result.output[range.upperBound..<end.lowerBound].split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
    }
}

/// Runs a short command with a deadline and collects what it printed.
enum CommandProbe {
    struct Result {
        let status: Int32
        let output: String
    }

    /// nil when the command could not start or did not finish in time (it is then killed).
    static func run(_ executable: String, _ arguments: [String], environment: [String: String]?, timeout: TimeInterval) -> Result? {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        // A file rather than a pipe: a chatty command can never block on a full pipe buffer.
        let log = FileManager.default.temporaryDirectory.appending(path: "folio-probe-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        guard let output = try? FileHandle(forWritingTo: log) else { return nil }
        defer { try? output.close() }
        process.standardOutput = output
        process.standardError = output
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            return nil
        }
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return Result(status: process.terminationStatus, output: text)
    }

    /// The first version number in a `--version` answer ("2.1.3 (Claude Code)", "codex-cli 0.50.0").
    static func version(in output: String) -> String? {
        output.firstMatch(of: /\d+\.\d+(?:\.\d+)?(?:[-+][0-9A-Za-z.]+)?/).map { String($0.output) }
    }
}

/// Where an agent was found and which version answered.
struct AgentInstallation: Sendable, Hashable {
    let location: String
    let version: String?
    let isApp: Bool
}

extension AgentIntegrator {
    /// The folders searched for agents' commands: the login shell's PATH, then the usual install folders.
    var commandFolders: [String] {
        if let commandFoldersOverride { return commandFoldersOverride }
        var seen = Set<String>()
        return (ShellEnvironment.loginPATH() + ShellEnvironment.fallbackFolders(home: home)).filter { seen.insert($0).inserted }
    }

    /// The environment agents' commands run in: Folio's own, with the shell's PATH.
    var commandEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (commandFolders + [environment["PATH"] ?? ""]).joined(separator: ":")
        environment["HOME"] = home.path
        // Some CLIs print colours or update notices unless told they are not talking to a person.
        environment["NO_COLOR"] = "1"
        environment["CI"] = "1"
        return environment
    }

    /// An executable named `name` on the search path (symlinks resolved; a dangling link does not count).
    func findCommand(_ name: String) -> String? {
        for folder in commandFolders {
            let path = "\(folder)/\(name)"
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), !isFolder.boolValue,
                  FileManager.default.isExecutableFile(atPath: path) else { continue }
            return path
        }
        return nil
    }

    func installation(of descriptor: AgentDescriptor) -> AgentInstallation? {
        for app in descriptor.apps {
            for folder in applicationFolders {
                // Info.plist is read directly: `Bundle` caches by path, so a bundle seen half-installed
                // would stay that way until Folio quits.
                let url = folder.appending(path: app)
                guard let data = try? Data(contentsOf: url.appending(path: "Contents/Info.plist")),
                      let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let executable = info["CFBundleExecutable"] as? String,
                      FileManager.default.isExecutableFile(atPath: url.appending(path: "Contents/MacOS/\(executable)").path)
                else { continue }
                return AgentInstallation(location: url.path, version: info["CFBundleShortVersionString"] as? String, isApp: true)
            }
        }
        for command in descriptor.commands {
            guard let path = findCommand(command) else { continue }
            guard verifiesCommands else { return AgentInstallation(location: path, version: nil, isApp: false) }
            let environment = commandEnvironment
            for arguments in descriptor.versionArguments {
                guard let result = CommandProbe.run(path, arguments, environment: environment, timeout: 8), result.status == 0 else { continue }
                return AgentInstallation(location: path, version: CommandProbe.version(in: result.output), isApp: false)
            }
        }
        return nil
    }
}
