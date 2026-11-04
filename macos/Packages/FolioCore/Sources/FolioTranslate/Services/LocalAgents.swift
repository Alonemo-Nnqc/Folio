import Foundation

/// Coding agents that can translate from the command line with the user's own login, no key needed in Folio.
/// Each has a documented way to answer one prompt and exit; the arguments follow its own `--help` and documentation.
public enum LocalAgent: String, Sendable, Hashable, CaseIterable {
    case claude, codex, gemini, grok, antigravity, copilot, cursor, qwen, opencode, kiro, cline, kimi, droid, amp, goose, pi, hermes, openclaw, deepseek

    /// The command, under its usual name.
    public var command: String { commands[0] }

    /// Names the command goes by, most specific first.
    public var commands: [String] {
        switch self {
        case .claude: ["claude"]
        case .codex: ["codex"]
        case .gemini: ["gemini"]
        case .grok: ["grok"]
        case .antigravity: ["agy"]
        case .copilot: ["copilot"]
        case .cursor: ["cursor-agent", "agent"]
        case .qwen: ["qwen"]
        case .opencode: ["opencode"]
        case .kiro: ["kiro-cli"]
        case .cline: ["cline"]
        case .kimi: ["kimi"]
        case .droid: ["droid"]
        case .amp: ["amp"]
        case .goose: ["goose"]
        case .pi: ["pi"]
        case .hermes: ["hermes"]
        case .openclaw: ["openclaw"]
        case .deepseek: ["dsh"]
        }
    }

    /// The translation service that uses this agent.
    public var serviceID: String {
        switch self {
        case .claude: "claudecode"
        case .codex: "codex"
        case .gemini: "geminicli"
        case .grok: "grokcli"
        case .antigravity: "antigravitycli"
        case .copilot: "copilotcli"
        case .cursor: "cursoragent"
        case .qwen: "qwencode"
        case .opencode: "opencode"
        case .kiro: "kirocli"
        case .cline: "clinecli"
        case .kimi: "kimicli"
        case .droid: "droidcli"
        case .amp: "ampcli"
        case .goose: "gooseagent"
        case .pi: "picli"
        case .hermes: "hermesagent"
        case .openclaw: "openclawagent"
        case .deepseek: "deepseekharness"
        }
    }

    /// The thinking levels the command takes, lowest first (empty: it has no such option).
    public var effortLevels: [String] {
        switch self {
        case .claude, .antigravity: ["low", "medium", "high", "xhigh", "max"]
        case .codex: ["minimal", "low", "medium", "high", "xhigh", "max"]
        case .grok: ["low", "medium", "high"]
        case .pi: ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
        case .hermes: ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
        default: []
        }
    }

    /// The level used until the user chooses: translating needs little thinking, and thinking is most of the time an
    /// agent takes (agy, 4000 characters: 20 s at low, 65 s at high).
    public var defaultEffort: String? {
        switch self {
        case .claude, .antigravity, .codex, .grok, .hermes: "low"
        case .pi: "off"
        default: nil
        }
    }

    /// The level a model's own name says ("gemini-3.8-flash-high", "provider/model:high"). Such a model is that level:
    /// agy refuses to be told another one. "-max" alone says nothing: "gpt-5.1-codex-max" is a model of that name.
    public static func effort(inModelName model: String?) -> String? {
        guard let model = model?.trimmingCharacters(in: .whitespaces).lowercased(),
              let match = model.firstMatch(of: /(?:[-:](low|medium|high|xhigh|thinking)|:(off|minimal|max))$/) else { return nil }
        return String(match.output.1 ?? match.output.2 ?? "")
    }

    /// Naming a model takes the level with it: agy accepts `--effort` only for its default model
    /// ("--effort is not supported for model \"claude-sonnet-4-6\"").
    public var modelDecidesEffort: Bool { self == .antigravity }

    /// The options asking for a level. `effort`: the user's choice, nil for the usual level, "" to leave it to the agent.
    func effortArguments(_ effort: String?, model: String?) -> [String] {
        let named = model?.trimmingCharacters(in: .whitespaces).isEmpty == false
        guard Self.effort(inModelName: model) == nil, !(modelDecidesEffort && named),
              let level = effort ?? defaultEffort, !level.isEmpty else { return [] }
        switch self {
        case .claude, .antigravity: return ["--effort", level]
        case .codex: return ["-c", "model_reasoning_effort=\"\(level)\""]
        case .grok: return ["--reasoning-effort", level]
        case .pi: return ["--thinking", level]
        case .hermes: return ["--reasoning", level]
        default: return []
        }
    }

    /// For a command name other programs use too: what its `--help` has to say (a pattern, and how much of the help
    /// to read). `agent` may be Cursor's or another agent's; `goose` also names a database tool, `pi` and `amp` many things.
    func signature(of command: String) -> (pattern: String, within: Int)? {
        switch (self, command) {
        case (.cursor, "agent"): (#"(?i)cursor"#, 200)
        case (.pi, _): (#"(?i)coding (assistant|agent)"#, 400)
        case (.amp, _): (#"(?i)\bamp\b"#, 2000)
        case (.droid, _): (#"(?i)droid|factory"#, 2000)
        case (.goose, _): (#"(?i)session|recipe"#, 4000)
        case (.hermes, _): (#"(?i)hermes agent"#, 8000)
        case (.kimi, _): (#"(?i)kimi"#, 2000)
        case (.deepseek, _): (#"(?i)deepseek"#, 2000)
        default: nil
        }
    }

    nonisolated(unsafe) private static var genuine: [String: Bool] = [:]
    private static let genuineLock = NSLock()

    /// Whether the program at `path` is this agent and not another one of that name.
    private func isGenuine(path: String, command: String) -> Bool {
        guard let signature = signature(of: command) else { return true }
        let key = "\(rawValue)|\(path)"
        if let known = Self.genuineLock.withLock({ Self.genuine[key] }) { return known }
        guard let result = CommandProbe.run(path, ["--help"], environment: LocalProcess.environment(), timeout: 10) else { return false }
        let found = String(result.output.prefix(signature.within)).range(of: signature.pattern, options: .regularExpression) != nil
        Self.genuineLock.withLock { Self.genuine[key] = found }
        return found
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
        let folders = (ShellEnvironment.loginPATH() + ShellEnvironment.fallbackFolders(home: home)).filter { seen.insert($0).inserted }
        for command in commands {
            for folder in folders {
                let path = (folder as NSString).appendingPathComponent(command)
                var isFolder: ObjCBool = false
                guard fileManager.fileExists(atPath: path, isDirectory: &isFolder), !isFolder.boolValue,
                      fileManager.isExecutableFile(atPath: path), isGenuine(path: path, command: command) else { continue }
                return URL(filePath: path)
            }
        }
        return nil
    }

    /// The installed agents, in catalog order.
    public static func installed() -> [LocalAgent] {
        // Each may have to answer `--help`; side by side, so one slow program does not hold up the list.
        final class Found: @unchecked Sendable {
            var flags = [Bool](repeating: false, count: LocalAgent.allCases.count)
            let lock = NSLock()
        }
        let found = Found()
        DispatchQueue.concurrentPerform(iterations: allCases.count) { k in
            let located = allCases[k].locate() != nil
            found.lock.withLock { found.flags[k] = located }
        }
        return allCases.indices.filter { found.flags[$0] }.map { allCases[$0] }
    }

    /// The version the command reports, if it answers.
    public func version(at url: URL) -> String? {
        // Some check for updates first (Hermes): a slow network must not make them look broken.
        guard let result = CommandProbe.run(url.path, ["--version"], environment: LocalProcess.environment(), timeout: 25), result.status == 0 else { return nil }
        return CommandProbe.version(in: result.output)
    }

    /// Arguments for one request. The prompt goes to stdin unless `promptArgument` is true (it then comes last, so an
    /// option taking it ends the list). `combineSystem`: the agent has no option for a system prompt.
    func arguments(model: String?, effort: String? = nil, system: String, outputFile: URL) -> (arguments: [String], promptArgument: Bool, combineSystem: Bool) {
        let model = model?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let thinking = effortArguments(effort, model: model)
        switch self {
        case .claude:
            // No tools, no saved session, little thinking: a translation needs none of them.
            var args = ["-p", "--output-format", "json", "--tools", "", "--no-session-persistence",
                        "--strict-mcp-config", "--disable-slash-commands", "--system-prompt", system] + thinking
            if let model { args += ["--model", model] }
            return (args, false, false)
        case .codex:
            // Without the user's MCP servers, which each take time to start.
            var args = ["exec", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only", "--color", "never",
                        "-c", "mcp_servers={}", "-o", outputFile.path] + thinking
            if let model { args += ["-m", model] }
            return (args + ["-"], false, true)
        case .gemini:
            var args = ["-o", "json", "-e", "none"]
            if let model { args += ["-m", model] }
            return (args + ["-p", " "], false, true)
        case .grok:
            var args = ["--output-format", "plain", "--no-subagents", "--disable-web-search", "--no-plan", "--max-turns", "1", "--verbatim"] + thinking
            if let model { args += ["-m", model] }
            return (args + ["-p"], true, true)
        case .antigravity:
            var args = ["--output-format", "text", "--sandbox", "--disable-slash-commands"] + thinking
            if let model { args += ["--model", model] }
            return (args + ["-p"], true, true)
        case .copilot:
            var args = ["-s"]
            if let model { args += ["--model", model] }
            return (args + ["-p"], true, true)
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
        case .kiro:
            var args = ["chat", "--no-interactive"]
            if let model { args += ["--model", model] }
            return (args, true, true)
        case .cline:
            // Plan mode: it answers and changes nothing.
            var args = ["--json", "-p"]
            if let model { args += ["-m", model] }
            return (args, true, true)
        case .kimi:
            var args = ["--quiet"]
            if let model { args += ["-m", model] }
            return (args + ["-p"], true, true)
        case .droid:
            var args = ["exec", "-o", "text"]
            if let model { args += ["-m", model] }
            return (args, true, true)
        case .amp:
            return (["-x"], true, true)
        case .goose:
            var args = ["run", "--no-session", "-q"]
            if let model { args += ["--model", model] }
            return (args + ["-t"], true, true)
        case .pi:
            // No tools, extensions or project files, nothing saved: only the model.
            var args = ["-p", "--no-session", "--no-tools", "--no-extensions", "--no-skills", "--no-prompt-templates",
                        "--no-context-files", "--no-mcp", "--offline", "--system-prompt", system] + thinking
            if let model { args += ["--model", model] }
            return (args, true, false)
        case .hermes:
            var args = ["--ignore-rules"] + thinking
            if let model { args += ["-m", model] }
            return (args + ["-z"], true, true)
        case .openclaw:
            var args = ["infer", "model", "run", "--local", "--json"]
            if let model { args += ["--model", model] }
            return (args + ["--prompt"], true, true)
        case .deepseek:
            return (["--profile", "headless"], true, true)
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
        case .openclaw:
            guard let object = LLMBatch.jsonObject(in: stdout) else { return stdout }
            if object["ok"] as? Bool == false {
                throw ProviderError(kind: .process, detail: (object["error"] as? String) ?? (object["message"] as? String) ?? stdout)
            }
            let outputs = object["outputs"] as? [[String: Any]]
            return outputs?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? stdout
        case .cline:
            // A JSON object per line; the last `run_result` holds the answer.
            for line in stdout.split(whereSeparator: \.isNewline).reversed() {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], object["type"] as? String == "run_result" else { continue }
                if let text = object["text"] as? String { return text }
            }
            return stdout
        default:
            return stdout
        }
    }
}

/// What a failed agent run means: something to wait out, something the user has to set up, or a mishap worth another try.
enum AgentFailure {
    /// `agent-setup <command>: …` is how the error classifier knows the agent itself needs attention.
    static func setup(_ agent: LocalAgent, _ text: String) -> ProviderError {
        ProviderError(kind: .agentSetup, detail: "agent-setup \(agent.command): " + firstMeaningfulLine(text))
    }

    /// The command would not take the thinking level with this model.
    static func refusesTheLevel(_ text: String) -> Bool {
        text.range(of: #"(--effort|--reasoning(-effort)?|--thinking|reasoning[_ ]effort)[^\n]{0,60}(not supported|unsupported|conflicts?|invalid|unknown)|(not supported|unsupported|conflicts? with|invalid|unknown)[^\n]{0,60}(--effort|--reasoning|--thinking|reasoning[_ ]effort)"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func classify(_ text: String, agent: LocalAgent) -> ProviderError {
        var clean = stripANSI(text)
        let said = firstMeaningfulLine(clean)
        // An error printed as JSON: only what it says counts, not the names of its other fields.
        if clean.contains("{\"") || clean.contains("{\n") { clean = said }
        let detail = "agent \(agent.command): " + said
        func has(_ pattern: String) -> Bool { clean.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
        if ProviderError.isContentRefusal(clean) { return ProviderError(kind: .refused, detail: detail) }
        if has(#"too many requests|rate.?limit|\b429\b|resource.?exhausted"#) { return ProviderError(kind: .http(429), detail: detail) }
        if has(#"\b(http|status|code)[ :=]*402\b|insufficient.?(balance|quota|credit)|out of credits|usage limit|quota exceeded|exceeded your"#) {
            return ProviderError(kind: .http(402), detail: detail)
        }
        if refusesTheLevel(clean) { return setup(agent, clean) }
        if has(#"(model|deployment)[^\n]{0,80}(not found|does not exist|not available|not supported|unavailable|invalid)|unknown model|invalid model|no such model"#) {
            return ProviderError(kind: .http(404), detail: detail + " model_not_found")
        }
        if has(#"not (logged|signed) in|please (log|sign) ?in|log ?in (first|required)|run .{0,30}(login|auth)|no inference provider|not authenticated|authentication (is )?(required|failed)|unauthori[sz]ed|\b401\b|invalid.?api.?key|no api key|missing api key|set an api key|not configured|no (provider|model) (is )?(configured|selected)|first.?run|onboard|error authenticating|failed to authenticate|oauth|session expired|ineligible|no longer supported|migrate to"#) {
            return setup(agent, clean)
        }
        if has(#"unknown (option|flag|argument)|unrecognized (option|argument)|unexpected argument|invalid option|no such option|update required|please (update|upgrade)"#) {
            return setup(agent, clean)
        }
        if let code = clean.firstMatch(of: /(?i)\bHTTP[ \/:]*(?:1\.1 )?(\d{3})\b/)?.output.1, let status = Int(code) {
            return ProviderError(kind: .http(status), detail: detail + " http \(status)")
        }
        return ProviderError(kind: .process, detail: detail)
    }

    /// An error printed as if it were the answer (exit status 0): text with no JSON that opens like an error report.
    static func inReply(_ reply: String, agent: LocalAgent) -> ProviderError? {
        let clean = stripANSI(reply).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return ProviderError(kind: .invalidResponse, detail: "agent \(agent.command): empty reply") }
        guard !clean.contains("{"), clean.range(of: #"(?i)^(api error|error\b|http[ /]?\d{3}|\w*error:|request failed|failed to)"#, options: .regularExpression) != nil else { return nil }
        return classify(clean, agent: agent)
    }

    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: #"\u001B\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
    }

    /// The line that says what went wrong: an error is often preceded by progress and followed by a stack trace.
    static func firstMeaningfulLine(_ text: String) -> String {
        let cleaned = text.replacingOccurrences(of: #"^exit \d+:\s*"#, with: "", options: .regularExpression)
        // An error printed as JSON: what it says, not its first brace.
        if let message = TranslationErrorClassifier.firstMatch(#""(?:message|error|detail|result)"\s*:\s*"((?:[^"\\]|\\.)+)""#, in: cleaned) {
            return String(message.prefix(400))
        }
        let lines = cleaned.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("at ") }
        let line = lines.first { $0.range(of: #"(?i)error|fail|denied|not |no |invalid|too many|unknown|please|http \d"#, options: .regularExpression) != nil } ?? lines.first ?? text
        return String(line.replacingOccurrences(of: #"^(?i)(error:\s*)+"#, with: "", options: .regularExpression).prefix(400))
    }
}

/// Translates with a local agent: large batches (each call starts the agent), a few at a time.
struct AgentProvider: ChatModel {
    var agent: LocalAgent
    var executable: URL
    var model: String?
    /// The thinking level chosen; nil: the usual one, "": the agent's own.
    var effort: String?
    /// Set once a model has refused the usual level, so later batches do not ask again.
    let usualLevelRefused = RefusalMemory()
    var limits = ProviderLimits(batchCharacters: 5000, batchItems: 60, concurrency: 4, usesContext: true, startupSeconds: 8, secondsPerCharacter: 0.006)

    func complete(system: String, user: String) async throws -> String {
        do {
            return try await complete(system: system, user: user, effort: usualLevelRefused.value ? "" : effort)
        } catch let error as ProviderError where effort == nil && !usualLevelRefused.value && AgentFailure.refusesTheLevel(error.detail) {
            // The usual level is our idea, not the user's: it must never be what stops a model they chose from working.
            // A level they chose themselves stays, and its refusal is shown.
            usualLevelRefused.value = true
            return try await complete(system: system, user: user, effort: "")
        }
    }

    private func complete(system: String, user: String, effort: String?) async throws -> String {
        let outputFile = FileManager.default.temporaryDirectory.appending(path: "folio-agent-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outputFile) }
        let (arguments, promptArgument, combine) = agent.arguments(model: model, effort: effort, system: system, outputFile: outputFile)
        let prompt = combine ? system + "\n\n---\n\nTranslate this JSON object:\n" + user : user
        do {
            let stdout = try await LocalProcess.run([executable.path] + arguments + (promptArgument ? [prompt] : []),
                                                    input: promptArgument ? "" : prompt, timeout: 600)
            let reply = AgentFailure.stripANSI(try agent.answer(stdout: stdout, outputFile: outputFile))
            if let failure = AgentFailure.inReply(reply, agent: agent) { throw failure }
            return reply
        } catch let error as ProviderError where error.kind == .process {
            throw AgentFailure.classify(error.detail, agent: agent)
        }
    }
}

/// A fact learned during a translation, shared by the requests running side by side.
final class RefusalMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Runs a command with text on stdin and returns its stdout. The environment has the login shell's PATH (agents
/// built on Node need it), the real HOME and proxy settings; the working directory is an empty folder.
enum LocalProcess {
    static func run(_ command: [String], input: String, timeout: TimeInterval) async throws -> String {
        // When the job ends (another batch failed, the user cancelled) the command stops at once, instead of running
        // on for minutes with nobody waiting for it.
        let handle = Handle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try runBlocking(command, input: input, timeout: timeout, handle: handle) })
                }
            }
        } onCancel: {
            handle.stop()
        }
    }

    /// The running command, for stopping it from elsewhere; stopping before it starts stops it as it starts.
    final class Handle: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var stopped = false

        func started(_ process: Process) {
            let stop = lock.withLock { self.process = process; return stopped }
            if stop { Self.end(process) }
        }

        func stop() {
            let process = lock.withLock { stopped = true; return self.process }
            if let process { Self.end(process) }
        }

        private static func end(_ process: Process) {
            guard process.isRunning else { return }
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(pid, SIGKILL) } }
        }
    }

    /// Runs the command on this thread until it ends.
    static func runBlocking(_ command: [String], input: String, timeout: TimeInterval, handle: Handle? = nil) throws -> String {
        let workDirectory = FileManager.default.temporaryDirectory.appending(path: "folio-translate-work", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(filePath: command[0])
        process.arguments = Array(command.dropFirst())
        process.environment = environment()
        process.currentDirectoryURL = workDirectory
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // A command that ended without reading its input must not take the app with it: writing to its pipe would
        // raise SIGPIPE, which ends the whole process.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        // Waited for on a semaphore. `Process.waitUntilExit` runs this thread's run loop while it waits, which fires
        // whatever was scheduled there earlier, on this thread: PDFKit's delayed notifications reached the reader's
        // thumbnail view that way and it updated from here, which aborts the app.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let out = PipeReader(stdout.fileHandleForReading), err = PipeReader(stderr.fileHandleForReading)
        do { try process.run() } catch {
            out.stop()
            err.stop()
            throw ProviderError(kind: .process, detail: "command '\(command[0])' not found: \(error.localizedDescription)")
        }
        Running.shared.add(process)
        defer { Running.shared.remove(process) }
        handle?.started(process)
        DispatchQueue.global().async {
            try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        // A helper the command left running (a language server, say) may keep the pipes open: their end is not awaited for long.
        let output = String(decoding: out.finish(), as: UTF8.self), errors = err.finish()
        if timedOut {
            throw ProviderError(kind: .network, detail: "timed out after \(Int(timeout)) s")
        }
        if process.terminationReason == .uncaughtSignal {
            throw ProviderError(kind: .cancelled, detail: "cancelled")
        }
        if process.terminationStatus != 0 {
            // The start of its output too: a JSON report says what went wrong in its first fields.
            let printed = output.count <= 2400 ? output : String(output.prefix(1600)) + "\n" + String(output.suffix(800))
            let message = String(decoding: errors.suffix(1500), as: UTF8.self) + "\n" + printed
            throw ProviderError(kind: .process, detail: "exit \(process.terminationStatus): " + message)
        }
        // Nothing printed but a message on the side: that message is what happened.
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !errors.isEmpty {
            throw ProviderError(kind: .process, detail: "exit 0: " + String(decoding: errors.suffix(1500), as: UTF8.self))
        }
        return output
    }

    /// Collects what a pipe delivers, on a queue of its own.
    private final class PipeReader: @unchecked Sendable {
        private let handle: FileHandle
        private var data = Data()
        private let lock = NSLock()
        private let ended = DispatchSemaphore(value: 0)

        init(_ handle: FileHandle) {
            self.handle = handle
            handle.readabilityHandler = { [self] readable in
                let chunk = readable.availableData
                if chunk.isEmpty {
                    readable.readabilityHandler = nil
                    ended.signal()
                } else {
                    lock.withLock { data.append(chunk) }
                }
            }
        }

        func stop() { handle.readabilityHandler = nil }

        /// What arrived, once the pipe has ended or a moment has passed.
        func finish() -> Data {
            _ = ended.wait(timeout: .now() + 2)
            handle.readabilityHandler = nil
            return lock.withLock { data }
        }
    }

    /// What the agent would see in the user's terminal: an app opened from Finder has none of the shell's settings,
    /// and agents read their keys, gateways and proxies from them. Terminal-specific variables stay out.
    static func environment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var env = ShellEnvironment.loginEnvironment()
        for key in ["PWD", "OLDPWD", "SHLVL", "_", "PS1", "RPROMPT", "COLORTERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID",
                    "ITERM_SESSION_ID", "ITERM_PROFILE", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT", "CODEX_SANDBOX"] {
            env[key] = nil
        }
        for key in ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "http_proxy", "https_proxy", "all_proxy", "no_proxy",
                    "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "SSL_CERT_FILE", "SSL_CERT_DIR"] where env[key] == nil {
            if let value = inherited[key] { env[key] = value }
        }
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
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
