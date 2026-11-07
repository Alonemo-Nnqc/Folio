import Foundation

/// How Folio decides an agent is really on this Mac (AI-04). A configuration folder proves nothing: it
/// survives uninstalling, and other tools create them. An agent counts only when
///  - its app bundle is in an Applications folder and has its executable, or
///  - its command is an executable on the user's PATH (dangling symlinks fail) and answers `--version`.
///
/// An app opened from Finder does not get the PATH of the user's shell, so the PATH is read from a login,
/// interactive shell, as VS Code and Zed resolve their shell environment; Node-based CLIs (npm, nvm, Volta)
/// also need it to find `node` when they run.
public enum ShellEnvironment {
    /// Folders where command-line agents are usually installed, searched after the shell's PATH.
    public static func fallbackFolders(home: URL) -> [String] {
        var folders = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        folders += [".local/bin", ".npm-global/bin", ".npm/bin", ".bun/bin", ".volta/bin", "Library/pnpm", ".local/share/pnpm", ".cargo/bin", ".deno/bin",
                    ".asdf/shims", ".local/share/mise/shims", ".claude/local", ".opencode/bin", ".grok/bin", ".cursor/bin", ".kimi/bin", ".kiro/bin",
                    ".factory/bin", ".amp/bin", ".codex/packages/standalone/current/bin", ".antigravity/antigravity/bin"]
            .map { home.appending(path: $0).path }
        // A global npm install lives in the folder of each Node version a version manager keeps.
        for (root, suffix) in [(".nvm/versions/node", "bin"), (".fnm/node-versions", "installation/bin"),
                               (".local/share/fnm/node-versions", "installation/bin"), ("Library/Application Support/fnm/node-versions", "installation/bin"),
                               (".local/share/mise/installs/node", "bin"), (".asdf/installs/nodejs", "bin")] {
            let parent = home.appending(path: root)
            let versions = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
            folders += versions.sorted().reversed().map { parent.appending(path: "\($0)/\(suffix)").path }
        }
        return folders
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: [String: String]?
    /// A shell that did not answer is not asked again at once, but it is asked again.
    nonisolated(unsafe) private static var lastFailure: Date?

    /// The PATH of the user's login shell, read once (until `reset()`); empty when the shell does not answer.
    public static func loginPATH() -> [String] {
        (loginEnvironment()["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
    }

    /// The environment of the user's login shell, read once (until `reset()`); empty when the shell does not answer.
    public static func loginEnvironment() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        if let lastFailure, Date().timeIntervalSince(lastFailure) < 60 { return [:] }
        guard let environment = readLoginEnvironment() else {
            lastFailure = Date()
            return [:]
        }
        cached = environment
        return environment
    }

    /// Forget what was read (设置 ▸ AI ▸ 重新检测: the user may just have installed something).
    public static func reset() {
        lock.lock()
        cached = nil
        lastFailure = nil
        lock.unlock()
    }

    private static func readLoginEnvironment() -> [String: String]? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        // Markers around the value: interactive shells may print greetings or prompts around it.
        let marker = "__FOLIO_ENV__"
        let command = "printf '\(marker)'; /usr/bin/env -0; printf '\(marker)'"
        guard let result = CommandProbe.run(shell, ["-ilc", command], environment: nil, timeout: 10),
              let range = result.output.range(of: marker),
              let end = result.output.range(of: marker, range: range.upperBound..<result.output.endIndex) else { return nil }
        var environment: [String: String] = [:]
        for entry in result.output[range.upperBound..<end.lowerBound].split(separator: "\0") {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return environment["PATH"] == nil ? nil : environment
    }
}

/// Runs a short command with a deadline and collects what it printed.
public enum CommandProbe {
    public struct Result: Sendable {
        public let status: Int32
        public let output: String
    }

    /// nil when the command could not start or did not finish in time (it is then killed).
    public static func run(_ executable: String, _ arguments: [String], environment: [String: String]?, timeout: TimeInterval) -> Result? {
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
    public static func version(in output: String) -> String? {
        output.firstMatch(of: /\d+\.\d+(?:\.\d+)?(?:[-+][0-9A-Za-z.]+)?/).map { String($0.output) }
    }
}

