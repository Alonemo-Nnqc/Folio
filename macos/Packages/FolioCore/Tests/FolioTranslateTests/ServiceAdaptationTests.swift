import Foundation
import Network
import PDFKit
import Testing
@testable import FolioTranslate

/// A translation service on this Mac's loopback address, answering as the test says: what the engine does with
/// services that turn parameters down, cut replies off, skip texts or give them back untranslated.
final class LocalService: @unchecked Sendable {
    /// The request's path and JSON body in, an HTTP status and a JSON body out.
    typealias Handler = @Sendable (_ path: String, _ body: [String: Any]) -> (status: Int, json: Any)
    private let listener: NWListener
    private let handler: Handler
    private let lock = NSLock()
    private var received: [[String: Any]] = []
    let port: UInt16

    /// The bodies of the requests so far, in the order they came.
    var requests: [[String: Any]] { lock.withLock { received } }
    var base: String { "http://127.0.0.1:\(port)/v1" }

    /// Starts the service, and returns once it listens. (Waiting for that without giving the thread back would hold up
    /// every other test: tests share a few threads, and the listener needs one of them to get ready.)
    static func start(_ handler: @escaping Handler) async throws -> LocalService {
        // Loopback only: nothing listens on the network.
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        final class Box: @unchecked Sendable { weak var service: LocalService?; var resumed = false; let lock = NSLock() }
        let box = Box()
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            box.service?.read(connection, Data())
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready, .failed, .cancelled:
                    let first = box.lock.withLock { let first = !box.resumed; box.resumed = true; return first }
                    if first { continuation.resume() }
                default: break
                }
            }
            listener.start(queue: .global())
        }
        let service = LocalService(listener: listener, handler: handler)
        box.service = service
        return service
    }

    private init(listener: NWListener, handler: @escaping Handler) {
        self.listener = listener
        self.handler = handler
        port = listener.port?.rawValue ?? 0
    }

    deinit { listener.cancel() }

    private func read(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                let length = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                let body = buffer[headerEnd.upperBound...]
                if body.count >= length {
                    let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                    let json = (try? JSONSerialization.jsonObject(with: Data(body.prefix(length)))) as? [String: Any] ?? [:]
                    self.lock.withLock { self.received.append(json) }
                    let (status, answer) = self.handler(path, json)
                    if let events = answer as? Events {
                        // A reply written piece by piece: the connection's end is the reply's.
                        let head = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n".utf8)
                        connection.send(content: head, completion: .contentProcessed { _ in self.write(events.lines[...], pause: events.pause, to: connection) })
                        return
                    }
                    let payload = (try? JSONSerialization.data(withJSONObject: answer)) ?? Data()
                    var response = Data("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n".utf8)
                    response.append(payload)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
            }
            if isComplete || error != nil { return connection.cancel() }
            self.read(connection, buffer)
        }
    }

    /// The lines of an event stream, sent one after the other with a pause between them.
    struct Events {
        var lines: [String]
        var pause = 0.02
    }

    private func write(_ lines: ArraySlice<String>, pause: Double, to connection: NWConnection) {
        guard let line = lines.first else { return connection.cancel() }
        connection.send(content: Data((line + "\n\n").utf8), completion: .contentProcessed { [weak self] _ in
            DispatchQueue.global().asyncAfter(deadline: .now() + pause) {
                guard let self else { return connection.cancel() }
                self.write(lines.dropFirst(), pause: pause, to: connection)
            }
        })
    }

    /// A Chat Completions answer written in `pieces`, as a stream.
    static func chatStream(_ pieces: [String], finish: String = "stop") -> (status: Int, json: Any) {
        func line(_ object: [String: Any]) -> String { "data: " + String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self) }
        var lines = pieces.map { line(["choices": [["delta": ["content": $0]]]]) }
        lines.append(line(["choices": [["delta": [:] as [String: Any], "finish_reason": finish]]]))
        lines.append("data: [DONE]")
        return (200, Events(lines: lines))
    }

    /// A Chat Completions answer with `content`.
    static func chat(_ content: String, finish: String = "stop") -> (status: Int, json: Any) {
        (200, ["choices": [["message": ["role": "assistant", "content": content], "finish_reason": finish]]])
    }

    /// The system prompt and the texts (`{"1": …}`) of a request the engine sent.
    static func parts(_ body: [String: Any]) -> (system: String, texts: [String: String]) {
        let messages = body["messages"] as? [[String: Any]] ?? []
        let system = messages.first { $0["role"] as? String == "system" }?["content"] as? String ?? ""
        let user = messages.first { $0["role"] as? String == "user" }?["content"] as? String ?? ""
        let object = LLMBatch.jsonObject(in: user.components(separatedBy: "\n\nShort items").first ?? user) ?? [:]
        return (system, object.compactMapValues { $0 as? String })
    }

    static func json(_ object: [String: String]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }
}

private func chatProvider(_ service: LocalService, model: String = "test-model", temperature: Double? = 0.2,
                          optional: Set<String> = ["temperature"]) -> OpenAIChatProvider {
    OpenAIChatProvider(endpoint: URL(string: service.base + "/chat/completions")!, apiKey: "k", model: model, temperature: temperature,
                       optional: optional, limits: ProviderLimits(batchCharacters: 2600, batchItems: 30, concurrency: 8, usesContext: true))
}

private let context = TranslationContext(sourceLanguage: "en", targetLanguage: "zh", glossary: [])

/// Replies come in more shapes than the one asked for; what can be read is read, and only what is missing is asked again.
@Suite struct ReplyTests {
    @Test func repliesInOtherShapesAreRead() {
        #expect(LLMBatch.parse(#"{"translations": {"1": "甲", "2": "乙"}}"#, count: 2) == ["甲", "乙"])
        #expect(LLMBatch.parse(#"["甲", "乙"]"#, count: 2) == ["甲", "乙"])
        #expect(LLMBatch.parse(#"{"1": {"translation": "甲"}, "02": "乙"}"#, count: 2) == ["甲", "乙"])
        #expect(LLMBatch.parse("```json\n{\"1\": \"甲\"}\n```", count: 1) == ["甲"])
        // A list of another length says nothing about which text is which.
        #expect(LLMBatch.parse(#"["甲"]"#, count: 2) == [nil, nil])
    }

    @Test func whatAModelThoughtAloudIsNotTheAnswer() {
        let reply = "<think>Draft: {\"1\": \"wrong\"} — let me use ```json fences```.</think>\n{\"1\": \"对\"}"
        #expect(LLMBatch.parse(reply, count: 1) == ["对"])
        #expect(LLMBatch.parse("reasoning with \"1\": \"draft\" …</think>{\"1\": \"对\"}", count: 1) == ["对"])
    }

    @Test func onlyTheTextsLeftOutAreAskedAgain() async throws {
        let service = try await LocalService.start { _, body in
            let texts = LocalService.parts(body).texts
            // Of three texts the second is skipped; asked for alone, it comes.
            var answer = texts.mapValues { "译：" + $0 }
            if texts.count == 3 { answer["2"] = nil }
            return LocalService.chat(LocalService.json(answer))
        }
        let items = ["one", "two", "three"].map { TranslationItem(text: $0, kind: .paragraph) }
        let texts = try await chatProvider(service).translate(items, context: context)
        #expect(texts == ["译：one", "译：two", "译：three"])
        #expect(service.requests.count == 2)
        #expect(LocalService.parts(service.requests[1]).texts == ["1": "two"], "the second request carries only the missing text")
    }

    @Test func aReplyCutOffIsToldFromAnUnreadableOne() async throws {
        let service = try await LocalService.start { _, _ in LocalService.chat(#"{"1": "被截"#, finish: "length") }
        do {
            _ = try await chatProvider(service).translate([TranslationItem(text: "one", kind: .paragraph)], context: context)
            Issue.record("a cut-off reply must not pass")
        } catch let error as ProviderError {
            #expect(error.kind == .truncated)
            #expect(!error.isRetryable, "the same request would be cut off again")
        }
    }
}

/// Parameters Folio adds on its own never stand between a model and a translation.
@Suite struct ParameterTests {
    @Test func aParameterTurnedDownIsLeftOutAndRemembered() async throws {
        let service = try await LocalService.start { _, body in
            if body["temperature"] != nil {
                return (400, ["error": ["message": "Unsupported value: 'temperature' does not support 0.2 with this model. Only the default (1) value is supported."]])
            }
            return LocalService.chat(#"{"1": "好"}"#)
        }
        let provider = chatProvider(service)
        let item = [TranslationItem(text: "fine", kind: .paragraph)]
        #expect(try await provider.translate(item, context: context) == ["好"])
        #expect(service.requests.count == 2, "sent again without the parameter")
        #expect(try await provider.translate(item, context: context) == ["好"])
        #expect(service.requests.count == 3, "and not sent with it a second time")
        #expect(service.requests[2]["temperature"] == nil)
    }

    @Test func aParameterTheUserChoseIsNotDropped() async throws {
        let service = try await LocalService.start { _, _ in (400, ["error": ["message": "Unsupported parameter: 'temperature'"]]) }
        let provider = chatProvider(service, optional: [])
        do {
            _ = try await provider.translate([TranslationItem(text: "fine", kind: .paragraph)], context: context)
            Issue.record("the refusal must show")
        } catch let error as ProviderError {
            #expect(error.kind == .http(400))
            #expect(service.requests.allSatisfy { $0["temperature"] != nil }, "never sent without what the user chose")
        }
    }

    @Test func aFailureThatIsNotAboutParametersKeepsItsOwnMessage() async throws {
        let service = try await LocalService.start { _, _ in (400, ["error": ["message": "This model's maximum context length is 4096 tokens."]]) }
        do {
            _ = try await chatProvider(service).translate([TranslationItem(text: "fine", kind: .paragraph)], context: context)
            Issue.record("must fail")
        } catch let error as ProviderError {
            #expect(error.detail.contains("maximum context length"))
        }
        // Nothing was learned about the parameter: the failure had another reason.
        #expect(ParameterMemory.shared.refused(for: service.base + "/chat/completions|test-model").isEmpty)
    }

    @Test func theNamedParameterGoesFirst() {
        #expect(ParameterMemory.rejected(in: "Error code: 400 - unknown field \"reasoning_effort\"", among: ["temperature", "reasoning_effort"]) == "reasoning_effort")
        #expect(ParameterMemory.rejected(in: "Error code: 400 - model overloaded", among: ["temperature"]) == nil)
    }

    @Test func geminiIsToldToThinkLittleOnlyWhereItCan() {
        #expect(GeminiProvider.thinkingConfig(model: "gemini-2.5-flash")?["thinkingBudget"] as? Int == 0)
        #expect(GeminiProvider.thinkingConfig(model: "gemini-3-flash-preview")?["thinkingLevel"] as? String == "low")
        #expect(GeminiProvider.thinkingConfig(model: "gemini-2.5-pro") == nil)
        #expect(GeminiProvider.thinkingConfig(model: "gemini-2.0-flash") == nil)
    }
}

@Suite struct TranslationCheckTests {
    @Test func aSentenceGivenBackAsItWentIsNoticed() {
        let source = "Domain generalization aims to train models that work on unseen domains."
        #expect(TranslationJob.isUntranslated(source, source: source, target: "zh"))
        #expect(TranslationJob.isUntranslated("", source: source, target: "zh"))
        #expect(TranslationJob.isUntranslated("Domain generalization aims at training models.", source: source, target: "zh"), "still not a character of Chinese")
        #expect(!TranslationJob.isUntranslated("域泛化旨在训练在未见域上有效的模型。", source: source, target: "zh"))
        // Names and short labels may well stay as they are.
        #expect(!TranslationJob.isUntranslated("ResNet-50", source: "ResNet-50", target: "zh"))
        #expect(!TranslationJob.isUntranslated("ImageNet Top-1", source: "ImageNet Top-1", target: "zh"))
        // Into a language in the same script, only the very same text counts.
        #expect(TranslationJob.isUntranslated(source, source: source, target: "fr"))
        #expect(!TranslationJob.isUntranslated("La généralisation de domaine vise à entraîner des modèles.", source: source, target: "fr"))
    }

    @Test func tiesAreSettledTheSameWayEveryTime() {
        var tally = Tally<String>()
        for key in ["b", "a", "c", "a", "b", "c"] { tally.add(key) }
        #expect(tally.most == "b", "counted alike: the one seen first")
        tally.add("c")
        #expect(tally.most == "c")
    }

    @Test func emptyTranslationsAreNotKept() {
        let folder = TemporaryDirectory()
        let document = folder.url.appending(path: "a.pdf")
        try? Data("x".utf8).write(to: document)
        let cache = TranslationCache(directory: folder.url, document: document, signature: "s", ignore: false)
        cache.store("", for: "source")
        #expect(cache.lookup("source") == nil)
        cache.store("译文", for: "source")
        #expect(cache.lookup("source") == "译文")
    }
}

/// The whole job against a service that behaves like the ones in the wild.
@Suite(.serialized) struct ServiceJobTests {
    static func paper(paragraphs: Int, repeated: Bool = false) -> Data {
        var page: [TestPDF.Element] = [.text("A Study Of Robust Segmentation", x: 150, y: 740, size: 18, bold: true)]
        let words = ["Segmentation models trained on one domain degrade on another and",
                     "the gap grows with the distance between the two domains so that a",
                     "model must learn features that do not depend on where images come",
                     "from which is what the method described in this section provides."]
        var top = 700.0
        for k in 0..<paragraphs {
            let lines = repeated ? words : words.map { "Part \(k + 1) says " + $0.dropFirst(22) }
            page += TestPDF.paragraph(lines, top: top)
            top -= 76
        }
        return TestPDF.make([page])
    }

    @Test func theSameTextIsSentOnceAndSetEverywhere() async throws {
        let folder = TemporaryDirectory()
        let support = folder.url.appending(path: "support")
        let input = folder.url.appending(path: "paper.pdf")
        try Self.paper(paragraphs: 4, repeated: true).write(to: input)
        let service = try await LocalService.start { _, body in
            let (system, texts) = LocalService.parts(body)
            if system.hasPrefix("You build glossaries") { return LocalService.chat(#"{"terms": []}"#) }
            return LocalService.chat(LocalService.json(texts.mapValues { $0.hasPrefix("Segmentation") ? "分割模型在一个域上训练后在另一个域上性能下降。" : "鲁棒分割研究" }))
        }
        let request = TranslationRequest(input: input, outputDirectory: folder.url.appending(path: "out"), serviceID: "openaicompatible",
                                         fieldValues: ["--openai-compatible-base-url": service.base, "--openai-compatible-model": "m"],
                                         options: TranslationOptions(outputs: .mono, ignoreCache: true))
        let events = await collect(TranslationJob(request: request, supportDirectory: support).start())
        guard case .finished(let mono?, _) = events.last else { Issue.record("did not finish: \(events)"); return }
        let sent = service.requests.map { LocalService.parts($0) }.filter { !$0.system.hasPrefix("You build glossaries") }.flatMap(\.texts.values)
        #expect(sent.filter { $0.hasPrefix("Segmentation models trained") }.count == 1, "four paragraphs with the same words: one text sent")
        let text = PDFDocument(url: mono)?.string ?? ""
        #expect(text.components(separatedBy: "分割模型在一个域上训练后").count - 1 == 4, "and its translation set in all four places: \(text)")
        #expect(!text.contains("Segmentation models trained"))
    }

    @Test func aTextGivenBackUntranslatedIsAskedAgain() async throws {
        let folder = TemporaryDirectory()
        let support = folder.url.appending(path: "support")
        let input = folder.url.appending(path: "paper.pdf")
        try Self.paper(paragraphs: 2).write(to: input)
        final class Count: @unchecked Sendable { let lock = NSLock(); var echoes = 0 }
        let count = Count()
        let service = try await LocalService.start { _, body in
            let (system, texts) = LocalService.parts(body)
            if system.hasPrefix("You build glossaries") { return LocalService.chat(#"{"terms": []}"#) }
            var answer: [String: String] = [:]
            for (key, text) in texts {
                // The first time "Part 2 …" comes, it goes back as it is.
                let echo = text.hasPrefix("Part 2") && count.lock.withLock { count.echoes += 1; return count.echoes == 1 }
                answer[key] = echo ? text : "这是第 \(text.dropFirst(5).prefix(1)) 段的译文。"
            }
            return LocalService.chat(LocalService.json(answer))
        }
        let request = TranslationRequest(input: input, outputDirectory: folder.url.appending(path: "out"), serviceID: "openaicompatible",
                                         fieldValues: ["--openai-compatible-base-url": service.base, "--openai-compatible-model": "m"],
                                         options: TranslationOptions(outputs: .mono, ignoreCache: true))
        let events = await collect(TranslationJob(request: request, supportDirectory: support).start())
        guard case .finished(let mono?, _) = events.last else { Issue.record("did not finish: \(events)"); return }
        let text = PDFDocument(url: mono)?.string ?? ""
        #expect(text.contains("这是第 2 段的译文"))
        #expect(!text.contains("Part 2 says"), "the echo did not make it into the paper")
    }

    @Test func laterBatchesKnowThePapersTerms() async throws {
        let folder = TemporaryDirectory()
        let support = folder.url.appending(path: "support")
        let input = folder.url.appending(path: "paper.pdf")
        try Self.paper(paragraphs: 8).write(to: input)
        let service = try await LocalService.start { _, body in
            let (system, texts) = LocalService.parts(body)
            if system.hasPrefix("You build glossaries") {
                // The terms take a moment, as they do.
                Thread.sleep(forTimeInterval: 0.5)
                return LocalService.chat(#"{"terms": [{"source": "domain", "target": "域"}]}"#)
            }
            return LocalService.chat(LocalService.json(texts.mapValues { _ in "分割模型的译文。" }))
        }
        let request = TranslationRequest(input: input, outputDirectory: folder.url.appending(path: "out"), serviceID: "openaicompatible",
                                         fieldValues: ["--openai-compatible-base-url": service.base, "--openai-compatible-model": "m"],
                                         options: TranslationOptions(outputs: .mono, ignoreCache: true))
        let events = await collect(TranslationJob(request: request, supportDirectory: support).start())
        guard case .finished = events.last else { Issue.record("did not finish: \(events)"); return }
        let batches = service.requests.map { LocalService.parts($0).system }.filter { !$0.hasPrefix("You build glossaries") }
        let informed = batches.filter { $0.contains("domain → 域") }.count
        #expect(batches.count >= 3, "the paper goes in several batches: \(batches.count)")
        #expect(informed >= batches.count - 2, "all but the first two wait for the terms: \(informed) of \(batches.count)")
    }

    @Test func aReplyCutOffIsTriedInHalves() async throws {
        let folder = TemporaryDirectory()
        let support = folder.url.appending(path: "support")
        let input = folder.url.appending(path: "paper.pdf")
        try Self.paper(paragraphs: 2).write(to: input)
        let service = try await LocalService.start { _, body in
            let (system, texts) = LocalService.parts(body)
            if system.hasPrefix("You build glossaries") { return LocalService.chat(#"{"terms": []}"#) }
            // This model has room for one text a reply.
            if texts.count > 1 { return LocalService.chat(#"{"1": "被截"#, finish: "length") }
            return LocalService.chat(LocalService.json(texts.mapValues { _ in "完整的译文。" }))
        }
        let request = TranslationRequest(input: input, outputDirectory: folder.url.appending(path: "out"), serviceID: "openaicompatible",
                                         fieldValues: ["--openai-compatible-base-url": service.base, "--openai-compatible-model": "m"],
                                         options: TranslationOptions(outputs: .mono, ignoreCache: true))
        let events = await collect(TranslationJob(request: request, supportDirectory: support).start())
        guard case .finished(let mono?, _) = events.last else { Issue.record("did not finish: \(events)"); return }
        #expect((PDFDocument(url: mono)?.string ?? "").contains("完整的译文"))
        #expect(!events.contains { if case .problem = $0 { true } else { false } }, "no waiting and retrying of what cannot fit")
    }
}

/// Replies are read as they are written: no time limit on a long one, and the progress is what has arrived.
@Suite struct StreamingTests {
    final class Seen: @unchecked Sendable { let lock = NSLock(); var counts: [Int] = [] }

    /// Runs `body` and gives what it reported of its replies' progress.
    static func progress<T>(_ body: () async throws -> T) async rethrows -> (T, [Int]) {
        let seen = Seen()
        let result = try await StreamProgress.$sink.withValue({ n in seen.lock.withLock { seen.counts.append(n) } }) { try await body() }
        return (result, seen.counts)
    }

    @Test func aReplyIsReadAsItIsWritten() async throws {
        // In the middle of a text: a character Unicode calls a line end, which is not the end of an event.
        let service = try await LocalService.start { _, body in
            #expect(body["stream"] as? Bool == true)
            return LocalService.chatStream([#"{"1": "流式"#, "回复\u{2028}第二行", #"", "2": "另"#, #"一段"}"#])
        }
        let items = ["one", "two"].map { TranslationItem(text: $0, kind: .paragraph) }
        let (texts, counts) = try await Self.progress { try await chatProvider(service).translate(items, context: context) }
        #expect(texts == ["流式回复\u{2028}第二行", "另一段"])
        #expect(counts.count >= 4 && counts == counts.sorted() && counts.last! > counts.first!, "the reply grew piece by piece: \(counts)")
    }

    @Test func aStreamCutOffSaysSo() async throws {
        let service = try await LocalService.start { _, _ in LocalService.chatStream([#"{"1": "被截"#], finish: "length") }
        do {
            _ = try await chatProvider(service).translate([TranslationItem(text: "one", kind: .paragraph)], context: context)
            Issue.record("a cut-off reply must not pass")
        } catch let error as ProviderError {
            #expect(error.kind == .truncated)
        }
    }

    @Test func anErrorInTheMiddleOfAStreamIsAnError() async throws {
        let service = try await LocalService.start { _, _ in
            (200, LocalService.Events(lines: [#"data: {"choices": [{"delta": {"content": "{\"1\": \"半"}}]}"#, #"data: {"error": {"message": "The engine is currently overloaded"}}"#]))
        }
        do {
            _ = try await chatProvider(service).translate([TranslationItem(text: "one", kind: .paragraph)], context: context)
            Issue.record("half a reply must not pass")
        } catch let error as ProviderError {
            #expect(error.kind == .http(429) && error.isRetryable, "overloaded: worth another try")
        }
    }

    @Test func claudeStreamsItsReplyToo() async throws {
        let service = try await LocalService.start { path, body in
            #expect(path == "/v1/messages" && body["stream"] as? Bool == true && body["temperature"] == nil)
            return (200, LocalService.Events(lines: [
                #"event: message_start"#, #"data: {"type": "message_start", "message": {"content": []}}"#,
                #"data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "hm"}}"#,
                #"data: {"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": "{\"1\": \"克劳"}}"#,
                #"data: {"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": "德\"}"}}"#,
                #"data: {"type": "message_delta", "delta": {"stop_reason": "end_turn"}}"#, #"data: {"type": "message_stop"}"#,
            ]))
        }
        let provider = AnthropicProvider(base: URL(string: "http://127.0.0.1:\(service.port)")!, apiKey: "k", model: "claude-test",
                                         limits: ProviderLimits(batchCharacters: 2600, batchItems: 30, concurrency: 8, usesContext: true))
        let (texts, counts) = try await Self.progress { try await provider.translate([TranslationItem(text: "one", kind: .paragraph)], context: context) }
        #expect(texts == ["克劳德"])
        #expect(counts.first == 0 && counts.last! > 0, "thinking is a sign of life, the text is progress: \(counts)")
    }

    @Test func progressFollowsWhatHasArrived() {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 0) }
        let clock = Clock()
        let limits = ProviderLimits(batchCharacters: 2600, batchItems: 30, concurrency: 8, usesContext: true, startupSeconds: 2, secondsPerCharacter: 0.01)
        let estimate = ProgressEstimate(done: 0, total: 1000, limits: limits, replyPerCharacter: 0.5, clock: { clock.now })
        let request = estimate.begin(characters: 1000)
        clock.now += 60
        estimate.received(request, characters: 50)
        // A minute in, a tenth of the reply is there: a tenth is what shows, whatever the clock would have guessed.
        #expect(abs(estimate.fraction() - 0.15) < 0.01, "\(estimate.fraction())")
        estimate.received(request, characters: 250)
        #expect(abs(estimate.fraction() - 0.5) < 0.01)
        // A reply longer than expected does not count as done before it is.
        estimate.received(request, characters: 900)
        #expect(estimate.fraction() <= 0.97)
        estimate.finish(request)
        #expect(estimate.fraction() == 1)
    }
}

/// What a translation will take is said before it starts.
@Suite struct EstimateTests {
    @Test func pricesGoByTheModelsName() {
        #expect(TranslationPricing.price(model: "gpt-5-mini")?.input == 0.25)
        #expect(TranslationPricing.price(model: "openai/gpt-5.4-mini-2026-03-01")?.output == 4.50, "a gateway's prefix and a dated name are the same model")
        #expect(TranslationPricing.price(model: "gpt-5.4")?.input == 2.50, "the longest name that fits, not gpt-5")
        #expect(TranslationPricing.price(model: "claude-haiku-5-5")?.output == 0.50)
        #expect(TranslationPricing.price(model: "some-local-model") == nil)
    }

    @Test func aPaperIsEstimatedBeforeItIsTranslated() throws {
        let folder = TemporaryDirectory()
        let input = folder.url.appending(path: "paper.pdf")
        try ServiceJobTests.paper(paragraphs: 6).write(to: input)
        func estimate(_ service: String, _ fields: [String: String] = [:]) -> TranslationEstimate? {
            TranslationEstimator.estimate(TranslationRequest(input: input, outputDirectory: folder.url, serviceID: service, fieldValues: fields,
                                                             options: TranslationOptions(ignoreCache: true)))
        }
        let paid = try #require(estimate("openai", ["--openai-model": "gpt-5-mini"]))
        #expect(paid.characters > 1000 && paid.characters == paid.totalCharacters)
        // About a quarter of a token a character, and the instructions that go with each batch (most of a short paper's input).
        #expect(paid.inputTokens > paid.characters / 4 && paid.inputTokens < paid.characters * 2)
        #expect(paid.outputTokens > paid.characters / 4)
        let cost = try #require(paid.cost)
        #expect(cost > 0 && cost < 0.05, "a page with a small model costs a fraction of a cent: \(cost)")
        #expect(TranslationEstimator.text(for: paid)?.contains("$") == true)
        // A model without a known price: its tokens, no cost.
        let unknown = try #require(estimate("openaicompatible", ["--openai-compatible-model": "my-model", "--openai-compatible-base-url": "http://x"]))
        #expect(unknown.cost == nil && unknown.inputTokens == paid.inputTokens)
        // Machine translation charges by the character; free services have nothing to estimate.
        #expect(estimate("deepl")?.byCharacter == true)
        #expect(estimate("google") == nil)
        #expect(estimate("claudecode") == nil)
    }
}
