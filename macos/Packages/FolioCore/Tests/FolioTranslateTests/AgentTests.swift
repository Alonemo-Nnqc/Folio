import Foundation
import Testing
@testable import FolioTranslate

/// A stand-in for an agent's command: records its arguments and prints `output`.
private struct FakeAgent {
    let folder: URL
    let script: URL
    var argumentsFile: URL { folder.appending(path: "arguments.txt") }

    init(output: String, status: Int32 = 0, stderr: String = "") throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "folio-fake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        script = folder.appending(path: "agent")
        let outputFile = folder.appending(path: "output.txt"), errorFile = folder.appending(path: "error.txt")
        try output.write(to: outputFile, atomically: true, encoding: .utf8)
        try stderr.write(to: errorFile, atomically: true, encoding: .utf8)
        let body = """
        #!/bin/sh
        for a in "$@"; do printf '%s\\n' "$a"; done > '\(argumentsFile.path)'
        cat > /dev/null
        cat '\(errorFile.path)' >&2
        cat '\(outputFile.path)'
        exit \(status)
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    func provider(_ agent: LocalAgent, model: String? = nil) -> AgentProvider { AgentProvider(agent: agent, executable: script, model: model) }
    func arguments() throws -> String { try String(contentsOf: argumentsFile, encoding: .utf8) }
}

@Suite struct AgentInvocationTests {
    private let output = URL(filePath: "/tmp/out.txt")

    @Test func everyAgentHasAServiceAndOneShotArguments() {
        for agent in LocalAgent.allCases {
            #expect(TranslationServiceCatalog.service(id: agent.serviceID) != nil, "\(agent)")
            let (arguments, promptArgument, combine) = agent.arguments(model: nil, system: "SYSTEM", outputFile: output)
            // Without a system prompt option, the prompt carries it; with one, the option does.
            #expect(combine != arguments.contains("SYSTEM"), "\(agent)")
            if !promptArgument { #expect(!arguments.isEmpty, "\(agent)") }
        }
    }

    @Test func thePromptFollowsTheOptionThatTakesIt() {
        let expected: [LocalAgent: String] = [.grok: "-p", .antigravity: "-p", .copilot: "-p", .kimi: "-p", .amp: "-x", .goose: "-t", .hermes: "-z", .openclaw: "--prompt"]
        for (agent, option) in expected {
            let (arguments, promptArgument, _) = agent.arguments(model: "m1", system: "S", outputFile: output)
            #expect(promptArgument, "\(agent)")
            #expect(arguments.last == option, "\(agent): \(arguments)")
            if agent != .amp { #expect(arguments.contains("m1"), "\(agent)") }
        }
    }

    @Test func agentsWithoutAModelOptionIgnoreIt() {
        #expect(!LocalAgent.amp.arguments(model: "m1", system: "S", outputFile: output).arguments.contains("m1"))
        #expect(!LocalAgent.deepseek.arguments(model: "m1", system: "S", outputFile: output).arguments.contains("m1"))
    }

    @Test func aCommandOfTheSameNameIsNotMistakenForTheAgent() throws {
        // On a real Mac `agent` was another agent's command, and it even mentions Cursor further down its help.
        let grok = try FakeAgent(output: "Grok Build TUI\n\nUsage: agent [OPTIONS]\n" + String(repeating: " ", count: 300) + "Run this machine as a Cursor private worker\n")
        #expect(LocalAgent.cursor.signature(of: "agent") != nil)
        #expect(LocalAgent.cursor.signature(of: "cursor-agent") == nil)
        let signature = try #require(LocalAgent.cursor.signature(of: "agent"))
        let help = try String(contentsOf: grok.folder.appending(path: "output.txt"), encoding: .utf8)
        #expect(String(help.prefix(signature.within)).range(of: signature.pattern, options: .regularExpression) == nil)
        #expect("Cursor Agent\nUsage: agent".range(of: signature.pattern, options: .regularExpression) != nil)
        let goose = try #require(LocalAgent.goose.signature(of: "goose"))
        #expect("goose [OPTIONS] DRIVER DBSTRING COMMAND".range(of: goose.pattern, options: .regularExpression) == nil)
        #expect("Commands: session  recipe  run".range(of: goose.pattern, options: .regularExpression) != nil)
    }

    @Test func runsTheCommandAndReadsItsAnswer() async throws {
        let plain = try FakeAgent(output: "progress line\n{\"1\": \"译文\"}\n")
        #expect(try await plain.provider(.antigravity, model: "gemini-x").complete(system: "S", user: "U").contains("译文"))
        let sent = try plain.arguments()
        #expect(sent.contains("gemini-x"))
        #expect(sent.contains("Translate this JSON object:\nU"))

        let openclaw = try FakeAgent(output: "[agents] synced\n{\"ok\": true, \"outputs\": [{\"text\": \"{\\\"1\\\": \\\"译文\\\"}\"}]}\n")
        #expect(try await openclaw.provider(.openclaw).complete(system: "S", user: "U") == "{\"1\": \"译文\"}")

        let cline = try FakeAgent(output: "{\"type\": \"agent_event\"}\n{\"type\": \"run_result\", \"text\": \"{\\\"1\\\": \\\"译文\\\"}\"}\n")
        #expect(try await cline.provider(.cline).complete(system: "S", user: "U") == "{\"1\": \"译文\"}")

        let coloured = try FakeAgent(output: "\u{1B}[32m{\"1\": \"译文\"}\u{1B}[0m\n")
        #expect(try await coloured.provider(.kiro).complete(system: "S", user: "U").trimmingCharacters(in: .whitespacesAndNewlines) == "{\"1\": \"译文\"}")
    }
}

@Suite struct AgentFailureTests {
    private func failure(_ agent: LocalAgent = .grok, output: String = "", stderr: String = "", status: Int32 = 1) async throws -> ProviderError {
        let fake = try FakeAgent(output: output, status: status, stderr: stderr)
        do {
            _ = try await fake.provider(agent).complete(system: "S", user: "U")
        } catch let error as ProviderError {
            return error
        }
        Issue.record("expected a failure")
        return ProviderError(kind: .process, detail: "")
    }

    @Test func rateLimitsAreWaitedOut() async throws {
        let error = try await failure(stderr: "error: Too many requests\n")
        #expect(error.kind == .http(429))
        #expect(error.isRetryable)
    }

    @Test func whatTheUserMustSetUpIsNotRetried() async throws {
        for text in ["hermes -z: agent failed: No inference provider configured. Run 'hermes model' to choose.",
                     "Error: not logged in. Please run /login", "error: unexpected argument '--foo' found",
                     "Error authenticating: IneligibleTierError: This client is no longer supported"] {
            let error = try await failure(.hermes, stderr: text)
            #expect(error.kind == .agentSetup, "\(text)")
            #expect(!error.isRetryable)
            #expect(error.detail.hasPrefix("agent-setup hermes:"))
        }
    }

    @Test func anErrorPrintedAsTheAnswerIsAnError() async throws {
        let json = "{\"ok\": true, \"outputs\": [{\"text\": \"HTTP 403: No permission to access group\"}]}"
        #expect(try await failure(.openclaw, output: json, status: 0).kind == .http(403))
        #expect(try await failure(.grok, output: "Error: request failed", status: 0).kind == .process)
        #expect(try await failure(.grok, output: "   ", status: 0).kind == .invalidResponse)
    }

    @Test func anUnknownModelSaysSo() async throws {
        let error = try await failure(stderr: "Error: model 'x' not found")
        #expect(TranslationErrorClassifier.classify(message: error.detail).reason == .modelNotFound)
    }

    @Test func messagesNameTheAgentAndTheCause() {
        let setup = TranslationErrorClassifier.classify(message: "agent-setup hermes: No inference provider configured.")
        #expect(setup.reason == .agentSetup)
        #expect(setup.message.contains("hermes"))
        #expect(setup.message.contains("No inference provider configured"))
        #expect(!setup.message.contains(".。"))
        let denied = TranslationErrorClassifier.classify(message: "agent openclaw: HTTP 403: No permission http 403")
        #expect(denied.reason == .authentication)
        #expect(denied.message.contains("openclaw"))
        #expect(denied.message.contains("No permission"))
        #expect(!denied.message.contains("API Key"))
    }

    @Test func anOutdatedGatewayIsNotBlamedOnTheInstalledCLI() {
        let body = "Error code: 426 - {\"error\":\"Your Grok CLI version (0.2.119) is outdated. Please update to version 1.0.13 or later via `grok update` or the installation documentation.\"} https://127.0.0.1:8000/"
        let failure = TranslationErrorClassifier.classify(message: body)
        #expect(failure.reason == .clientOutdated)
        #expect(failure.message.contains("0.2.119"))
        #expect(failure.message.contains("1.0.13"))
        #expect(failure.message.contains("127.0.0.1:8000"))
        #expect(failure.message.contains("grok2api"))
    }
}

@Suite struct AgentEnvironmentTests {
    @Test func theAgentGetsAWorkingEnvironmentWithoutTerminalLeftovers() {
        let environment = LocalProcess.environment()
        #expect(environment["PATH"]?.contains("/usr/bin") == true)
        #expect(environment["NO_COLOR"] == "1")
        #expect(environment["TERM"] == "dumb")
        #expect(environment["CLAUDECODE"] == nil)
        #expect(environment["PWD"] == nil)
    }

    @Test func installFoldersIncludeTheUsualPlaces() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "folio-home-\(UUID().uuidString)")
        let nvm = home.appending(path: ".nvm/versions/node/v22.1.0/bin")
        try FileManager.default.createDirectory(at: nvm, withIntermediateDirectories: true)
        let folders = ShellEnvironment.fallbackFolders(home: home)
        #expect(folders.contains(nvm.path))
        #expect(folders.contains(home.appending(path: ".grok/bin").path))
        #expect(folders.contains(home.appending(path: ".local/bin").path))
    }
}

@Suite struct AgentModelListTests {
    @Test func listsReadFromTheAgentsOwnCommands() async throws {
        let grok = try FakeAgent(output: "Default model: grok-4.7\n\nAvailable models:\n  - grok-4.6\n  * grok-4.7 (default)\n")
        #expect(await AgentModels.models(for: .grok, executable: grok.script) == ["grok-4.6", "grok-4.7"])
        let antigravity = try FakeAgent(output: "Fetching available models...\ngemini-3.8-flash-low\tGemini 3.8 Flash (Low)\nclaude-sonnet-4-6\tClaude Sonnet 4.6\n")
        #expect(await AgentModels.models(for: .antigravity, executable: antigravity.script) == ["gemini-3.8-flash-low", "claude-sonnet-4-6"])
        let pi = try FakeAgent(output: "provider  model            context\ndeepseek  deepseek-flash   1M\n")
        #expect(await AgentModels.models(for: .pi, executable: pi.script) == ["deepseek/deepseek-flash"])
    }

    @Test func aServiceTestReportsAClosedPortInPlainWords() async {
        let outcome = await TranslationServiceTest.run(serviceID: "openaicompatible", fields: ["--openai-compatible-base-url": "http://127.0.0.1:9/v1", "--openai-compatible-model": "m"], secrets: [:])
        #expect(!outcome.succeeded)
        #expect(!outcome.message.isEmpty)
    }
}

@Suite struct LocalProcessTests {
    /// Runs `body` on a thread with a timer waiting on its run loop, as PDFKit leaves one; true if the timer fired.
    private func timerFires(while body: @escaping @Sendable () -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                final class Flag: @unchecked Sendable { var fired = false }
                let flag = Flag()
                RunLoop.current.add(Timer(timeInterval: 0, repeats: false) { _ in flag.fired = true }, forMode: .default)
                body()
                continuation.resume(returning: flag.fired)
            }
            thread.start()
        }
    }

    @Test func waitingForACommandDoesNotRunTheThreadsRunLoop() async {
        // `Process.waitUntilExit` would fire the timer: that is how PDFKit's notification reached the reader's
        // thumbnails on a background thread and aborted the app.
        let fired = await timerFires { _ = try? LocalProcess.runBlocking(["/bin/sleep", "0.2"], input: "", timeout: 10) }
        #expect(!fired)
    }

    @Test func aCommandThatIgnoresItsInputDoesNotEndTheApp() throws {
        // Ends before the input is written: without protection the write raises SIGPIPE and the test process dies.
        let big = String(repeating: "x", count: 2_000_000)
        #expect(try LocalProcess.runBlocking(["/bin/sh", "-c", "exec <&-; echo done"], input: big, timeout: 10) == "done\n")
    }

    @Test func aHelperKeepingThePipesOpenDoesNotHoldUpTheResult() throws {
        let started = Date()
        let output = try LocalProcess.runBlocking(["/bin/sh", "-c", "sleep 30 & echo answer"], input: "", timeout: 10)
        #expect(output == "answer\n")
        #expect(Date().timeIntervalSince(started) < 8)
    }

    @Test func anErrorPrintedAsJSONSaysWhatItSays() {
        let text = "Internal error: {\n  \"message\": \"Invalid API key\",\n  \"http_status\": 401\n}"
        #expect(AgentFailure.firstMeaningfulLine(text) == "Invalid API key")
    }
}

@Suite struct CentredBlockTests {
    private func line(_ minX: Double, _ maxX: Double, baseline: Double) -> LayoutLine {
        var c = PageChar(text: "x", rect: CGRect(x: minX, y: baseline - 2, width: maxX - minX, height: 12), isSpace: false, isNewline: false,
                         size: 10, baseline: baseline, font: .unknown, color: .black, run: nil, isRotated: false)
        c.glyphs = []
        return LayoutLine(chars: [c], inkRect: c.rect, baseline: baseline, size: 10, font: .unknown, color: .black, isRotated: false)
    }

    @Test func aListItemIsNotCentred() {
        // A bullet line, then lines after the bullet, the last a little short: the lines' middles come close.
        let item = LayoutBlock(kind: .paragraph, lines: [line(317.2, 553.5, baseline: 600), line(325.7, 553.5, baseline: 588), line(325.7, 533.6, baseline: 576)], translate: true)
        #expect(!item.isCentered)
    }

    @Test func centredLinesAre() {
        let block = LayoutBlock(kind: .caption, lines: [line(100, 300, baseline: 600), line(150, 250, baseline: 588)], translate: true)
        #expect(block.isCentered)
    }

    @Test func aTitleOfTwoLinesOfOneWidthIsCentredByItsPlace() {
        var title = LayoutBlock(kind: .title, lines: [line(165, 450, baseline: 660), line(170, 445, baseline: 640)], translate: true)
        #expect(!title.isCentered, "nothing says so yet")
        title.centeredInColumn = true
        #expect(title.isCentered)
    }

    @Test func aParagraphOfFullLinesStaysFlush() {
        var paragraph = LayoutBlock(kind: .paragraph, lines: [line(165, 450, baseline: 660), line(165, 450, baseline: 648)], translate: true)
        paragraph.centeredInColumn = true
        #expect(!paragraph.isCentered)
    }
}

@Suite struct ProgressEstimateTests {
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSinceReferenceDate: 0)
        func advance(_ seconds: Double) { now = now.addingTimeInterval(seconds) }
    }
    private let limits = ProviderLimits(batchCharacters: 1000, batchItems: 10, concurrency: 2, usesContext: false, startupSeconds: 2, secondsPerCharacter: 0.01)

    @Test func movesWhileARequestRunsAndNeverGoesBack() {
        let clock = Clock()
        let estimate = ProgressEstimate(done: 0, total: 2000, limits: limits, clock: { clock.now })
        let a = estimate.begin(characters: 1000)   // expected: 12 s
        var last = estimate.fraction()
        #expect(last == 0)
        var steps: [Double] = []
        for _ in 0..<60 {
            clock.advance(0.2)
            let value = estimate.fraction()
            #expect(value >= last)
            steps.append(value - last)
            last = value
        }
        // Steady for the whole expected time: no stops, no jumps.
        #expect(steps.allSatisfy { $0 > 0 && $0 < 0.01 }, "\(steps)")
        #expect(abs(last - 0.45) < 0.01, "\(last)")
        estimate.finish(a)
        #expect(abs(estimate.fraction() - 0.5) < 0.001)
    }

    @Test func aRequestTakingLongerKeepsMovingWithoutCountingAsDone() {
        let clock = Clock()
        let estimate = ProgressEstimate(done: 0, total: 1000, limits: limits, clock: { clock.now })
        _ = estimate.begin(characters: 1000)
        clock.advance(36)
        let later = estimate.fraction()
        clock.advance(36)
        let muchLater = estimate.fraction()
        #expect(muchLater > later)
        #expect(muchLater < 0.99)
    }

    @Test func itLearnsHowLongRequestsTake() {
        let clock = Clock()
        let estimate = ProgressEstimate(done: 0, total: 4000, limits: limits, clock: { clock.now })
        let first = estimate.begin(characters: 1000)
        clock.advance(102)    // far slower than expected
        estimate.finish(first)
        let settled = estimate.fraction()
        _ = estimate.begin(characters: 1000)
        clock.advance(50)     // about half of the 102 s it now expects
        let share = (estimate.fraction() - settled) * 4
        #expect(abs(share - 0.44) < 0.05, "\(share)")
    }

    @Test func aFailedRequestDoesNotTakeTheBarBack() {
        let clock = Clock()
        let estimate = ProgressEstimate(done: 0, total: 1000, limits: limits, clock: { clock.now })
        let a = estimate.begin(characters: 1000)
        clock.advance(6)
        let before = estimate.fraction()
        estimate.abandon(a)
        #expect(estimate.fraction() == before)
    }

    @Test func aFinishedTextCountsFromTheStart() {
        let estimate = ProgressEstimate(done: 500, total: 1000, limits: limits)
        #expect(abs(estimate.fraction() - 0.5) < 0.001)
    }

    @Test func reportsOnlyGoForward() {
        final class Sink: @unchecked Sendable {
            var values: [Double] = []
            let lock = NSLock()
        }
        let sink = Sink()
        let progress = MonotonicProgress { event in
            if case .progress(let value) = event { sink.lock.withLock { sink.values.append(value) } }
        }
        for value in [0.1, 0.05, 0.1, 0.2, 0.2001, 0.3, 1.0, 1.0] { progress.report(value) }
        #expect(sink.values == [0.1, 0.2, 0.3, 1.0])
    }
}

@Suite struct AgentArgumentSpeedTests {
    private let output = URL(filePath: "/tmp/out.txt")

    @Test func agentsAreAskedNotToThinkAtLength() {
        func arguments(_ agent: LocalAgent) -> [String] { agent.arguments(model: nil, system: "S", outputFile: output).arguments }
        #expect(arguments(.antigravity).contains("--effort"))
        #expect(arguments(.grok).contains("--reasoning-effort"))
        #expect(arguments(.pi).contains("--thinking"))
        #expect(arguments(.claude).contains("--effort"))
        #expect(arguments(.codex).contains("mcp_servers={}"))
    }

    @Test func aModelNamedForALevelIsNotToldAnother() {
        // The real refusal: "--model gemini-3.8-flash-high conflicts with --effort=low".
        func arguments(model: String?, effort: String? = nil) -> [String] {
            LocalAgent.antigravity.arguments(model: model, effort: effort, system: "S", outputFile: output).arguments
        }
        #expect(!arguments(model: "gemini-3.8-flash-high").contains("--effort"))
        #expect(!arguments(model: "gemini-3.8-flash-low", effort: "high").contains("--effort"))
        #expect(!arguments(model: "claude-opus-4-6-thinking").contains("--effort"))
        // The real refusal: "--effort is not supported for model "claude-sonnet-4-6"": agy takes it only for its default.
        #expect(!arguments(model: "claude-sonnet-4-6").contains("--effort"))
        #expect(LocalAgent.claude.arguments(model: "claude-sonnet-4-6", system: "S", outputFile: output).arguments.contains("--effort"))
        // A name, not a level.
        #expect(LocalAgent.effort(inModelName: "gpt-5.1-codex-max") == nil)
        #expect(LocalAgent.effort(inModelName: "openai/gpt-5:max") == "max")
        #expect(LocalAgent.effort(inModelName: "gemini-3.8-flash-high") == "high")
        #expect(arguments(model: nil).contains("low"))
    }

    @Test func theChosenLevelIsWhatTheAgentGets() {
        let high = LocalAgent.antigravity.arguments(model: nil, effort: "high", system: "S", outputFile: output).arguments
        #expect(high.contains("--effort") && high.contains("high") && !high.contains("low"))
        // "": its own setting.
        #expect(!LocalAgent.antigravity.arguments(model: nil, effort: "", system: "S", outputFile: output).arguments.contains("--effort"))
        #expect(LocalAgent.codex.arguments(model: nil, effort: "high", system: "S", outputFile: output).arguments.contains("model_reasoning_effort=\"high\""))
        #expect(LocalAgent.pi.arguments(model: nil, effort: "medium", system: "S", outputFile: output).arguments.contains("medium"))
        #expect(LocalAgent.grok.arguments(model: nil, effort: "high", system: "S", outputFile: output).arguments.contains("--reasoning-effort"))
    }

    @Test func settingsOfferTheLevelsTheAgentTakes() throws {
        let model = "--antigravity-cli-model"
        guard case let .choices(choices, fallback) = ReasoningEffort.support(serviceID: "antigravitycli", fields: [:]) else {
            Issue.record("agy has levels")
            return
        }
        #expect(fallback == "low")
        #expect(choices.map(\.value) == ["low", "medium", "high", "xhigh", "max", ""])
        guard case .decidedByModel = ReasoningEffort.support(serviceID: "antigravitycli", fields: [model: "gemini-3.8-flash-high"]),
              case .decidedByModel = ReasoningEffort.support(serviceID: "antigravitycli", fields: [model: "claude-sonnet-4-6"]) else {
            Issue.record("the model decides")
            return
        }
        #expect(ReasoningEffort.support(serviceID: "qwencode", fields: [:]) == .none)
        var fields: [String: String] = [:]
        ReasoningEffort.set("high", serviceID: "antigravitycli", fields: &fields)
        #expect(ReasoningEffort.current(serviceID: "antigravitycli", fields: fields) == "high")
        #expect(ReasoningEffort.current(serviceID: "antigravitycli", fields: [:]) == "low")
        // Fields the service has none of do not count: nothing else may read this one as a value of its own.
        #expect(TranslationServiceCatalog.service(id: "antigravitycli")?.fields.contains { $0.option == "--antigravity-cli-effort" } == false)
    }

    @Test func anotherLevelIsAnotherTranslationForTheCache() {
        func signature(_ fields: [String: String]) -> String {
            TranslationJob.signature(of: TranslationRequest(input: URL(fileURLWithPath: "/a.pdf"), outputDirectory: URL(fileURLWithPath: "/"),
                                                            serviceID: "antigravitycli", fieldValues: fields))
        }
        // What was cached before levels could be chosen is still what the usual level makes.
        #expect(signature([:]) == signature(["--antigravity-cli-effort": "low"]))
        #expect(!signature([:]).contains("thinking"))
        #expect(signature([:]) != signature(["--antigravity-cli-effort": "high"]))
        #expect(signature(["--antigravity-cli-effort": ""]) != signature(["--antigravity-cli-effort": "high"]))
    }

    @Test func aModelRefusingTheUsualLevelStillTranslates() async throws {
        let fake = try FakeAgent(output: "")
        let calls = fake.folder.appending(path: "calls")
        let body = """
        #!/bin/sh
        cat > /dev/null
        echo x >> '\(calls.path)'
        case "$*" in *--reasoning-effort*) echo 'error: --reasoning-effort is not supported for model "m"' >&2; exit 1;; esac
        echo answer
        """
        try body.write(to: fake.script, atomically: true, encoding: .utf8)
        func count() throws -> Int { try String(contentsOf: calls, encoding: .utf8).split(separator: "\n").count }

        let provider = AgentProvider(agent: .grok, executable: fake.script, model: "m")
        #expect(try await provider.complete(system: "S", user: "U").contains("answer"))
        #expect(try count() == 2)
        // Learned: the next batch does not ask again.
        #expect(try await provider.complete(system: "S", user: "U").contains("answer"))
        #expect(try count() == 3)
        // A level the user chose is not dropped behind their back.
        let chosen = AgentProvider(agent: .grok, executable: fake.script, model: "m", effort: "high")
        await #expect(throws: ProviderError.self) { try await chosen.complete(system: "S", user: "U") }
    }

    @Test func aRefusedCombinationSaysSo() {
        for text in ["exit 1: error: invalid model selection (--model \"m-high\" --effort \"low\"): --model m-high conflicts with --effort=low",
                     "error: invalid model selection (--model \"m\" --effort \"low\"): --effort is not supported for model \"m\"",
                     "400: Unsupported value for reasoning_effort: model does not support it"] {
            #expect(AgentFailure.refusesTheLevel(text), "\(text)")
            #expect(AgentFailure.classify(text, agent: .antigravity).kind == .agentSetup, "\(text)")
        }
        #expect(!AgentFailure.refusesTheLevel("rate limit exceeded"))
        #expect(!AgentFailure.refusesTheLevel("error: model claude-x not found"))
    }

    @Test func aJSONErrorIsReadByWhatItSays() {
        // The report has a field named `fallback_credit`: that is not a quota problem.
        let report = #"{"type":"result","is_error":true,"result":"Failed to authenticate: OAuth session expired","usage":{"fallback_credit":null}}"#
        let error = AgentFailure.classify("exit 1: " + report, agent: .claude)
        #expect(error.kind == .agentSetup)
        #expect(error.detail.contains("OAuth session expired"))
    }
}

@Suite struct MachineBatchTests {
    @Test func placeholdersATranslatorMangledStillWork() {
        let typesetter = Typesetter(language: "zh")
        let formula = FormulaSpan(rect: CGRect(x: 0, y: 0, width: 20, height: 10), baseline: 2, size: 10)
        let text = typesetter.attributedString("结果 ｛v1｝ 如下", fontSize: 10, bold: false, serif: true, italic: false, color: .black, formulas: [formula], scale: 1).string
        #expect(text.contains("\u{FFFC}"))
        #expect(!text.contains("v1"))
    }
}
