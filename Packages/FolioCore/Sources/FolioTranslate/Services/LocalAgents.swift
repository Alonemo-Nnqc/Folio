import Foundation

/// Coding agents that can translate from the command line with the user's own login, no key needed in Folio.
public enum LocalAgent: String, Sendable, Hashable, CaseIterable {
    case claude, codex, gemini, qwen, opencode, cursor

    public var command: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .gemini: "gemini"
        case .qwen: "qwen"
        case .opencode: "opencode"
        case .cursor: "cursor-agent"
        }
    }

    /// The translation service that uses this agent.
    public var serviceID: String {
        switch self {
        case .claude: "claudecode"
        case .codex: "codex"
        case .gemini: "geminicli"
        case .qwen: "qwencode"
        case .opencode: "opencode"
        case .cursor: "cursoragent"
        }
    }

    /// The command on this Mac: `customPath` when it runs, else the first match on the login shell's PATH and
    /// the usual install folders.
    public func locate(customPath: String? = nil) -> URL? {
        let fileManager = FileManager.default
        if let customPath, !customPath.isEmpty {
            let expanded = (customPath as NSString).expandingTildeInPath
            return fileManager.isExecutableFile(atPath: expanded) ? URL(filePath: expanded) : nil
        }
        let home = fileManager.homeDirectoryForCurrentUser
        var seen: Set<String> = []
        for folder in (ShellEnvironment.loginPATH() + ShellEnvironment.fallbackFolders(home: home)) where seen.insert(folder).inserted {
            let path = (folder as NSString).appendingPathComponent(command)
            if fileManager.isExecutableFile(atPath: path) { return URL(filePath: path) }
        }
        return nil
    }

    /// The installed agents, in catalog order.
    public static func installed() -> [LocalAgent] { allCases.filter { $0.locate() != nil } }

    /// Arguments for one request. The prompt goes to stdin unless `promptArgument` is true.
    func arguments(model: String?, system: String, outputFile: URL) -> (arguments: [String], promptArgument: Bool, combineSystem: Bool) {
        let model = model?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        switch self {
        case .claude:
            // No tools, no saved session, little thinking: a translation needs none of them.
            var args = ["-p", "--output-format", "json", "--tools", "", "--no-session-persistence", "--effort", "low", "--system-prompt", system]
            if let model { args += ["--model", model] }
            return (args, false, false)
        case .codex:
            var args = ["exec", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only", "--color", "never",
                        "-c", "model_reasoning_effort=\"low\"", "-o", outputFile.path]
            if let model { args += ["-m", model] }
            return (args + ["-"], false, true)
        case .gemini:
            var args = ["-o", "json"]
            if let model { args += ["-m", model] }
            return (args + ["-p", " "], false, true)
        case .qwen:
            var args: [String] = []
            if let model { args += ["-m", model] }
            return (args + ["-p", " "], false, true)
        case .opencode:
            var args = ["run"]
            if let model { args += ["-m", model] }
            return (args, true, true)
        case .cursor:
            var args = ["-p", "--output-format", "text"]
            if let model { args += ["--model", model] }
            return (args, true, true)
        }
    }

    /// The model's answer in what the command printed.
    func answer(stdout: String, outputFile: URL) throws -> String {
        switch self {
        case .claude:
            // The whole output is one JSON object; its `result` may itself contain code fences.
            let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let object = ((try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any]) ?? LLMBatch.jsonObject(in: stdout) else { return stdout }
            if object["is_error"] as? Bool == true {
                throw ProviderError(kind: .process, detail: (object["result"] as? String) ?? stdout)
            }
            return object["result"] as? String ?? stdout
        case .codex:
            return (try? String(contentsOf: outputFile, encoding: .utf8)) ?? stdout
        case .gemini:
            if let object = LLMBatch.jsonObject(in: stdout), let response = object["response"] as? String { return response }
            return stdout
        default:
            return stdout
        }
    }
}

/// Translates with a local agent: large batches (each call starts the agent), a few at a time.
struct AgentProvider: ChatModel {
    var agent: LocalAgent
    var executable: URL
    var model: String?
    var limits = ProviderLimits(batchCharacters: 7000, batchItems: 60, concurrency: 3, usesContext: true)

    func complete(system: String, user: String) async throws -> String {
        let outputFile = FileManager.default.temporaryDirectory.appending(path: "folio-agent-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outputFile) }
        let (arguments, promptArgument, combine) = agent.arguments(model: model, system: system, outputFile: outputFile)
        let prompt = combine ? system + "\n\n---\n\nTranslate this JSON object:\n" + user : user
        let stdout = try await LocalProcess.run([executable.path] + arguments + (promptArgument ? [prompt] : []),
                                                input: promptArgument ? "" : prompt, timeout: 600)
        return try agent.answer(stdout: stdout, outputFile: outputFile)
    }
}

/// Runs a command with text on stdin and returns its stdout. The environment has the login shell's PATH (agents
/// built on Node need it), the real HOME and proxy settings; the working directory is an empty folder.
enum LocalProcess {
    static func run(_ command: [String], input: String, timeout: TimeInterval) async throws -> String {
        let workDirectory = FileManager.default.temporaryDirectory.appending(path: "folio-translate-work", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(filePath: command[0])
                process.arguments = Array(command.dropFirst())
                process.environment = environment()
                process.currentDirectoryURL = workDirectory
                let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
                process.standardInput = stdin
                process.standardOutput = stdout
                process.standardError = stderr
                var out = Data(), err = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { out = stdout.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.enter()
                DispatchQueue.global().async { err = stderr.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                do { try process.run() } catch {
                    continuation.resume(throwing: ProviderError(kind: .process, detail: "command '\(command[0])' not found: \(error.localizedDescription)"))
                    return
                }
                Running.shared.add(process)
                DispatchQueue.global().async {
                    try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                    try? stdin.fileHandleForWriting.close()
                }
                let deadline = DispatchTime.now() + timeout
                var timedOut = false
                while process.isRunning {
                    if DispatchTime.now() > deadline {
                        timedOut = true
                        process.terminate()
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                process.waitUntilExit()
                group.wait()
                Running.shared.remove(process)
                let output = String(decoding: out, as: UTF8.self)
                if timedOut {
                    continuation.resume(throwing: ProviderError(kind: .network, detail: "timed out after \(Int(timeout)) s"))
                } else if process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: ProviderError(kind: .cancelled, detail: "cancelled"))
                } else if process.terminationStatus != 0 {
                    let message = String(decoding: err.suffix(1500), as: UTF8.self) + "\n" + String(output.suffix(800))
                    continuation.resume(throwing: ProviderError(kind: .process, detail: "exit \(process.terminationStatus): " + message))
                } else {
                    continuation.resume(returning: output)
                }
            }
        }
    }

    static func environment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var env: [String: String] = ["LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "NO_COLOR": "1", "TERM": "dumb"]
        for key in ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "http_proxy", "https_proxy", "all_proxy", "no_proxy",
                    "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "SSL_CERT_FILE", "SSL_CERT_DIR"] {
            if let value = inherited[key] { env[key] = value }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        var seen: Set<String> = []
        env["PATH"] = (ShellEnvironment.loginPATH() + ShellEnvironment.fallbackFolders(home: home) + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
            .filter { seen.insert($0).inserted }.joined(separator: ":")
        return env
    }

    /// Processes still running, so cancelling a translation stops them.
    final class Running: @unchecked Sendable {
        static let shared = Running()
        private var processes: [ObjectIdentifier: Process] = [:]
        private let lock = NSLock()

        func add(_ process: Process) { lock.withLock { processes[ObjectIdentifier(process)] = process } }
        func remove(_ process: Process) { _ = lock.withLock { processes.removeValue(forKey: ObjectIdentifier(process)) } }
        func terminateAll() {
            let all = lock.withLock { Array(processes.values) }
            for process in all where process.isRunning { process.terminate() }
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
