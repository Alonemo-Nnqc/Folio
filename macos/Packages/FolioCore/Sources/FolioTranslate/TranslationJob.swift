import CoreGraphics
import CryptoKit
import Foundation
import PDFKit

/// Translates one PDF with the native engine: layout analysis, a glossary of the paper's terms, batched
/// requests to the chosen service, and the translated PDFs set in the original layout.
public final class TranslationJob: @unchecked Sendable {
    public let request: TranslationRequest
    public let logURL: URL
    private let lock = NSLock()
    private let rateGate = RateGate()
    /// What goes wrong while the job works (shown at once), and when a request last came back.
    private let activity = JobActivity()
    private var task: Task<Void, Never>?
    private var cancelled = false

    /// Where translations are cached and logs written.
    public static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Folio/Translation", directoryHint: .isDirectory)
    }()
    /// This job's own: tests give each job a scratch folder (jobs of suites running side by side must not share one).
    private let supportDirectory: URL
    /// The glossary kept from paper to paper (the app's; a job with its own folder has its own, there).
    private let glossaryStore: GlossaryStore

    public init(request: TranslationRequest, logURL: URL? = nil, supportDirectory: URL? = nil) {
        self.request = request
        let directory = supportDirectory ?? Self.supportDirectory
        self.supportDirectory = directory
        glossaryStore = supportDirectory == nil ? .shared : GlossaryStore(url: directory.appending(path: "glossary.json"))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        self.logURL = logURL ?? directory.appending(path: "logs/translate-\(formatter.string(from: Date())).log")
    }

    public func start() -> AsyncStream<TranslationEvent> {
        AsyncStream { continuation in
            let work = Task.detached(priority: .userInitiated) { [self] in
                let log = TranslationLog(url: logURL)
                let event: TranslationEvent
                do {
                    event = try await run(emit: { continuation.yield($0) }, log: log)
                } catch is CancellationError {
                    event = .cancelled
                } catch let error as ProviderError where error.kind == .cancelled {
                    event = .cancelled
                } catch {
                    if isCancelled {
                        event = .cancelled
                    } else {
                        log.write("FAILED: \(error)")
                        let message = Self.message(for: error)
                        event = .failed(message: message, logURL: logURL)
                    }
                }
                log.write("end: \(event)")
                continuation.yield(event)
                continuation.finish()
            }
            lock.withLock { task = work }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    public func cancel() {
        lock.withLock {
            cancelled = true
            task?.cancel()
        }
        LocalProcess.Running.shared.terminateAll()
    }

    public var isCancelled: Bool { lock.withLock { cancelled } }

    static func message(for error: Error) -> String {
        if let configuration = error as? TranslationConfigurationError { return configuration.errorDescription ?? "\(error)" }
        if let engine = error as? EngineError { return engine.errorDescription ?? "\(error)" }
        let detail = (error as? ProviderError).map { $0.detail + ($0.host.map { " https://\($0)/" } ?? "") } ?? "\(error)"
        return TranslationErrorClassifier.classify(message: detail).message
    }

    // MARK: Run

    private func run(emit: @escaping @Sendable (TranslationEvent) -> Void, log: TranslationLog) async throws -> TranslationEvent {
        let options = request.options
        let reported = MonotonicProgress(emit: emit)
        activity.attach(emit)
        func progress(_ value: Double) { reported.report(value) }
        log.write("translate \(request.input.lastPathComponent) with \(request.serviceID) \(options.langIn)→\(options.langOut)")
        let provider = try ProviderFactory.make(serviceID: request.serviceID, fields: request.fieldValues, secrets: request.secrets,
                                                concurrency: options.concurrency)
        log.write("model: \(provider.modelName ?? "-"), \(provider.limits.concurrency) requests at a time"
                  + (options.concurrency.map { " (同时请求数 set to \($0))" } ?? ""))
        if let check = ModelCheck.check(serviceID: request.serviceID, fields: request.fieldValues) {
            // Said at once, not discovered from a translation that takes an hour.
            let service = TranslationServiceCatalog.service(id: request.serviceID)?.displayName ?? request.serviceID
            let message = check.replacement.map {
                String(localized: "设置中的模型“\(check.saved)”已不在\(service)的可用模型中，本次改用 \($0)。可在 设置 ▸ 翻译 中更换。", bundle: .module)
            } ?? String(localized: "设置中的模型“\(check.saved)”已不在\(service)的可用模型中，本次使用它的默认模型。可在 设置 ▸ 翻译 中更换。", bundle: .module)
            log.write("saved model \(check.saved) is not offered (offered: \(check.offered.joined(separator: ", "))), using \(check.replacement ?? "the default")")
            emit(.problem(message))
        }

        // 1. Layout.
        emit(.stage(String(localized: "分析版面", bundle: .module)))
        guard let cg = CGPDFDocument(request.input as CFURL), let document = PDFDocument(url: request.input) else {
            throw EngineError.unreadable
        }
        if cg.isEncrypted && !cg.isUnlocked { throw EngineError.encrypted }
        let started = Date()
        let selected = options.pageNumbers(count: cg.numberOfPages)
        var analyzer = LayoutAnalyzer(options: .init(translateTables: options.translateTables, translateReferences: options.translateReferences))
        let analysed = analyzer.analyze(document: document, cgDocument: cg, pages: selected)
        try Task.checkCancellation()
        let output = options.onlyIncludeTranslatedPages || options.pages == nil ? selected : Array(1...cg.numberOfPages)
        let byNumber = Dictionary(uniqueKeysWithValues: analysed.map { ($0.number, $0) })
        let layouts = output.compactMap { byNumber[$0] ?? PageLayout.untouched(cg, number: $0) }
        let segments = SegmentBuilder.segments(for: analysed, target: options.langOut)
        log.write(String(format: "layout: %d pages, %d segments in %.2f s", analysed.count, segments.count, Date().timeIntervalSince(started)))
        progress(0.04)
        if segments.isEmpty {
            // Text, but all of it already in the language asked for: not a scan.
            let language = TranslationOptions.commonLanguages.first { $0.code == options.langOut }?.name ?? options.langOut
            throw analysed.contains(where: { !SegmentBuilder.segments(for: $0).isEmpty }) ? EngineError.alreadyInTarget(language) : EngineError.noText
        }

        // 2. Context and glossary.
        var context = TranslationContext(sourceLanguage: options.langIn, targetLanguage: options.langOut,
                                         title: segments.first { $0.kind == .title }?.source, summary: Self.summary(of: segments), glossary: [])
        // The user's file first, then Folio's glossary: terms written by the user and terms found in earlier papers.
        let fromFile = Self.readGlossary(options.glossaryFile)
        let known = Set(fromFile.map { $0.source.lowercased() })
        context.glossary = fromFile + glossaryStore.entries(for: options.langOut).filter { !known.contains($0.source.lowercased()) }
        // Terms are extracted while the first batches (title, abstract, introduction: where the terms come from)
        // are already being translated; later batches get the glossary.
        let glossary = GlossaryBox(context.glossary)
        var termTask: Task<Void, Never>?
        if provider.limits.usesContext {
            let excerpt = Self.termExcerpt(segments)
            let base = context
            termTask = Task {
                do {
                    let terms = try await withTimeout(seconds: 150) { try await provider.extractTerms(from: excerpt, context: base) }
                    glossary.add(terms)
                    // Kept for the papers after this one (what the glossary already has stays as it is).
                    let learned = options.rememberTerms ? self.glossaryStore.learn(terms, language: options.langOut, paper: base.title) : 0
                    log.write("glossary: \(glossary.entries.count) terms, \(learned) new kept")
                } catch {
                    log.write("term extraction failed, continuing without: \(error)")
                }
                glossary.markComplete()
            }
        }
        progress(0.06)

        // 3. Translations: the cache first, then the service.
        let cache = TranslationCache(directory: supportDirectory.appending(path: "cache", directoryHint: .isDirectory),
                                     document: request.input, signature: signature(), ignore: options.ignoreCache)
        defer { cache.save() }
        let state = TranslationState(segments: segments)
        // Paragraphs cut by a column or page break go as one text; their parts are set apart again.
        let continuations = Continuations.find(segments, layouts: analysed)
        let joinedParts = Dictionary(continuations.map { ($0.joined.id, $0) }, uniquingKeysWith: { a, _ in a })
        let inContinuation = Set(continuations.flatMap(\.parts).map(\.id))
        log.write("continued paragraphs: \(continuations.count)")
        for continuation in continuations {
            if let hit = cache.lookup(continuation.joined.source), let pieces = Continuations.split(hit, continuation) {
                for (part, piece) in zip(continuation.parts, pieces) { state.store(piece, for: part) }
            }
        }
        for segment in segments {
            if segment.kind == .heading, let heading = StandardHeadings.translate(segment.source, to: options.langOut) {
                state.store(heading, for: segment)
            } else if segment.kind == .tableCell, let cell = StandardCells.translate(segment.source, to: options.langOut) {
                state.store(cell, for: segment)
            } else if let hit = cache.lookup(segment.source) {
                state.store(segment.kind == .heading ? HeadingNumbers.restoreSpace(source: segment.source, translation: hit) : hit, for: segment)
            }
        }
        log.write("cache: \(state.doneCount) of \(segments.count) segments")
        let renderer = TranslationRenderer(source: cg, language: options.langOut)
        let previews = PreviewWriter(renderer: renderer, layouts: layouts, segments: segments,
                                     directory: request.outputDirectory, emit: emit)

        // What is left to send: whole paragraphs, the continued ones as one text each. A text the paper has more than
        // once (a table's "Method", a label under each of several figures) is sent once, and its translation set for
        // all of them: less to translate, and never two translations of the same words.
        var units: [TextSegment] = []
        var sent = Set<String>()
        var firstWithSource: [String: String] = [:]
        var repeats: [String: [TextSegment]] = [:]
        for segment in segments where state.translation(for: segment) == nil {
            if inContinuation.contains(segment.id) {
                guard let c = continuations.first(where: { $0.parts.contains { $0.id == segment.id } }), !sent.contains(c.joined.id) else { continue }
                if c.parts.allSatisfy({ state.translation(for: $0) == nil }) {
                    sent.insert(c.joined.id)
                    units.append(c.joined)
                    continue
                }
            }
            if let first = firstWithSource[segment.source] {
                repeats[first, default: []].append(segment)
                continue
            }
            firstWithSource[segment.source] = segment.id
            units.append(segment)
        }
        let twins = repeats
        if !twins.isEmpty { log.write("repeated texts sent once: \(twins.values.reduce(0) { $0 + $1.count })") }
        let refusals = RefusalCount(limit: max(5, segments.count / 20))
        let batches = Self.batches(units, limits: provider.limits)
        let total = segments.count
        // Between finished batches the bar goes on moving, by what is running and how long that usually takes.
        let cachedCharacters = state.characters.done
        let estimate = ProgressEstimate(done: cachedCharacters, total: cachedCharacters + units.reduce(0) { $0 + $1.source.count },
                                        limits: provider.limits, replyPerCharacter: ImageText.isCJK(options.langOut) ? 0.5 : 1.1)
        let serviceName = TranslationServiceCatalog.service(id: request.serviceID)?.displayName ?? request.serviceID
        activity.touch()
        let target = ProgressTarget { 0.08 + 0.86 * estimate.fraction() }
        let ticker = Task.detached(priority: .utility) {
            // One curve from here to the end: what finishes in a jump still arrives over a moment or two.
            var shown = target.value()
            var lastCount = -1
            var lastWaiting = ""
            var slowReported = false
            while !Task.isCancelled {
                let goal = target.value()
                shown = min(goal, shown + max(0.001, (goal - shown) * 0.2))
                reported.report(shown)
                if shown <= 0.94 {
                    let count = max(state.doneCount, min(total - 1, Int(Double(total) * (shown - 0.08) / 0.86)))
                    let idle = self.activity.idleSeconds
                    if idle >= 90, !slowReported {
                        // Far slower than a batch should take (10 to 30 s): why, and what to do about it.
                        slowReported = true
                        let model = provider.modelName.map { "（\($0)）" } ?? ""
                        let message = String(localized: "\(serviceName)\(model)已经 \(Int(idle)) 秒没有返回任何一批译文，正常一批只要 10 到 30 秒。多半是模型在长时间思考；可以在 设置 ▸ 翻译 中换用更快的模型。", bundle: .module)
                        log.write("slow: nothing back for \(Int(idle)) s from \(provider.modelName ?? serviceName)")
                        emit(.problem(message))
                    }
                    if idle >= 60 {
                        // Nothing back for a minute: say what it waits for, rather than seem to hang.
                        let minutes = Int(idle / 60)
                        let waiting = String(localized: "正在等待\(serviceName)回复（已等 \(minutes) 分钟）", bundle: .module)
                        if waiting != lastWaiting { lastWaiting = waiting; emit(.stage(waiting)) }
                        lastCount = -1
                    } else if count != lastCount {
                        lastCount = count
                        lastWaiting = ""
                        emit(.stage(TranslationStageText.paragraphs(done: count, total: total)))
                    }
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { ticker.cancel() }
        let batchContext = context
        defer { termTask?.cancel() }
        // 3b. Words in pictures, when asked for: read while the text is being translated (not after it), then
        // translated as soon as the paper's terms are known, side by side with the text's batches.
        // (What the work uses is shared with the text's batches, which already use it from many tasks at once.)
        struct ImageInputs: @unchecked Sendable {
            let pages: [Int], layouts: [PageLayout], provider: TranslationProvider, context: TranslationContext, cache: TranslationCache
            let log: TranslationLog, estimate: ProgressEstimate, refusals: RefusalCount, glossary: GlossaryBox, terms: Task<Void, Never>?
        }
        let inputs = ImageInputs(pages: selected, layouts: analysed, provider: provider, context: batchContext, cache: cache, log: log,
                                 estimate: estimate, refusals: refusals, glossary: glossary, terms: termTask)
        let imageWork: Task<[Int: [(line: ImageText.Line, translation: String)]], Error>? = options.translateImageText ? Task { [self, inputs] in
            let lines = try await recognizeImageText(pages: inputs.pages, layouts: inputs.layouts, log: inputs.log)
            // The paper's terms, if they come within a few seconds: labels are not held up long for them.
            let deadline = Date().addingTimeInterval(8)
            while inputs.terms != nil, !inputs.glossary.isComplete, Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
            var imageContext = inputs.context
            imageContext.glossary = inputs.glossary.entries
            return try await translateImageText(lines: lines, layouts: inputs.layouts, provider: inputs.provider, context: imageContext,
                                                cache: inputs.cache, log: inputs.log, estimate: inputs.estimate, refusals: inputs.refusals)
        } : nil
        defer { imageWork?.cancel() }
        // The first batches (title, abstract, introduction: what is read first, and shown first) go at once. The others
        // wait a moment for the paper's terms, so that the whole paper translates a term the same way: without the
        // wait every batch of a short paper would be under way before the terms are known.
        let leading = termTask == nil ? batches.count : max(1, min(2, provider.limits.concurrency / 2))
        let termsDeadline = Date().addingTimeInterval(provider.limits.startupSeconds * 2 + 8)
        let targetLanguage = options.langOut
        try await withThrowingTaskGroup(of: Void.self) { group in
            var pending = batches[...]
            var started = 0
            func startNext() {
                guard let batch = pending.popFirst() else { return }
                let waitsForTerms = started >= leading
                started += 1
                group.addTask {
                    if waitsForTerms { await glossary.wait(until: termsDeadline) }
                    var context = batchContext
                    context.glossary = glossary.entries
                    let texts = try await self.translate(batch, provider: provider, context: context, log: log, estimate: estimate,
                                                         refusals: refusals)
                    /// Sets the translation of one segment. A text that came back empty or as it went (still in the
                    /// source language) is not kept for next time: another run, or another service, may do better.
                    func settle(_ segment: TextSegment, _ raw: String) {
                        let text = segment.kind == .heading ? HeadingNumbers.restoreSpace(source: segment.source, translation: raw) : raw
                        state.store(text.isEmpty ? segment.source : text, for: segment)
                        if !Self.isUntranslated(text, source: segment.source, target: targetLanguage) { cache.store(text, for: segment.source) }
                    }
                    for (segment, raw) in zip(batch, texts) {
                        guard let raw else {
                            // Refused by the service's content review: the original stays, and is not cached.
                            for part in (joinedParts[segment.id]?.parts ?? [segment]) + (twins[segment.id] ?? []) { state.store(part.source, for: part) }
                            continue
                        }
                        if let continuation = joinedParts[segment.id] {
                            if let pieces = Continuations.split(raw, continuation) {
                                for (part, piece) in zip(continuation.parts, pieces) { state.store(piece, for: part) }
                                if !Self.isUntranslated(raw, source: segment.source, target: targetLanguage) { cache.store(raw, for: segment.source) }
                            } else {
                                // The translator moved a formula across the break: the parts go on their own.
                                log.write("continued paragraph p\(segment.page) not splittable, translating its parts apart")
                                let apart = try await self.translate(continuation.parts, provider: provider, context: context, log: log,
                                                                     estimate: estimate, refusals: refusals)
                                for (part, text) in zip(continuation.parts, apart) {
                                    if let text { settle(part, text) } else { state.store(part.source, for: part) }
                                }
                            }
                            continue
                        }
                        settle(segment, raw)
                        for twin in twins[segment.id] ?? [] { settle(twin, raw) }
                    }
                }
            }
            for _ in 0..<max(1, provider.limits.concurrency) { startNext() }
            while try await group.next() != nil {
                cache.saveIfNeeded()
                previews.update(state.snapshot(), pagesDone: state.completedPages)
                startNext()
            }
        }
        try Task.checkCancellation()
        if refusals.count > 0 {
            emit(.notice(String(localized: "翻译服务拒绝翻译 \(refusals.count) 个段落（内容审核），这些段落保留了原文。", bundle: .module)))
        }

        if let imageWork {
            emit(.stage(String(localized: "翻译图片中的文字", bundle: .module)))
            renderer.imageText = try await imageWork.value
        }

        // 4. The translated PDFs. Setting the pages takes a moment too; about this long, going by their number.
        emit(.stage(TranslationStageText.layout))
        let renderSeconds = 0.5 + Double(layouts.count) * 0.08
        let renderStarted = Date()
        target.set { 0.94 + 0.05 * (1 - exp(-Date().timeIntervalSince(renderStarted) / renderSeconds)) }
        await previews.finish()
        let base = request.input.deletingPathExtension().lastPathComponent
        let wantMono = options.outputs != .dual, wantDual = options.outputs != .mono
        let result = renderer.render(layouts: layouts, segments: segments, translations: state.snapshot(), mono: wantMono, dual: wantDual,
                                     dualLayout: options.dualLayout, title: nil)
        try FileManager.default.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
        var monoURL: URL?, dualURL: URL?
        if let mono = result.mono {
            monoURL = request.outputDirectory.appending(path: "\(base).mono.pdf")
            try mono.write(to: monoURL!)
        }
        if let dual = result.dual {
            dualURL = request.outputDirectory.appending(path: "\(base).dual.pdf")
            try dual.write(to: dualURL!)
        }
        log.write(String(format: "done in %.1f s", Date().timeIntervalSince(started)))
        ticker.cancel()
        progress(1)
        return .finished(mono: monoURL, dual: dualURL)
    }

    /// Who translates: the cache is only shared between runs of the same service, model, thinking level and languages.
    private func signature() -> String {
        Self.signature(of: request)
    }

    static func signature(of request: TranslationRequest) -> String {
        let service = TranslationServiceCatalog.service(id: request.serviceID)
        let model = service?.fields.first { $0.title == TranslationServiceCatalog.modelFieldTitle }
            .flatMap { request.fieldValues[$0.option].flatMap { $0.isEmpty ? nil : $0 } ?? $0.defaultValue } ?? ""
        // Only a level other than the usual one shows, so what is already cached at the usual one stays usable.
        var thinking = ""
        if case let .choices(_, usual) = ReasoningEffort.support(serviceID: request.serviceID, fields: request.fieldValues),
           let level = ReasoningEffort.current(serviceID: request.serviceID, fields: request.fieldValues), level != usual {
            thinking = "|thinking=\(level)"
        }
        return "\(request.serviceID)|\(model)\(thinking)|\(request.options.langIn)|\(request.options.langOut)|v1"
    }

    // MARK: Batches

    /// Batches of about one size. A short text is cut into as many batches as the service runs at once (down to a third
    /// of its usual size), so that all of them run side by side: four batches where eight could run take twice as long.
    static func batches(_ segments: [TextSegment], limits: ProviderLimits) -> [[TextSegment]] {
        let total = segments.reduce(0) { $0 + $1.source.count }
        let even = Int((Double(total) / Double(max(limits.concurrency, 1))).rounded(.up))
        let size = min(limits.batchCharacters, max(limits.batchCharacters / 3, 400, even))
        var result: [[TextSegment]] = []
        var current: [TextSegment] = []
        var characters = 0
        for segment in segments {
            let length = segment.source.count
            if !current.isEmpty, characters + length > size || current.count >= limits.batchItems {
                result.append(current)
                current = []
                characters = 0
            }
            current.append(segment)
            characters += length
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// TRANS-40: the words in the pictures of `pages`, a few pages at a time, page by page in reading order.
    private func recognizeImageText(pages: [Int], layouts: [PageLayout], log: TranslationLog) async throws -> [ImageText.Line] {
        let languages = ImageText.recognitionLanguages(for: request.options.langIn)
        let found = try await withThrowingTaskGroup(of: [ImageText.Line].self) { group in
            var queue = pages[...]
            var all: [[ImageText.Line]] = []
            func next() {
                guard let number = queue.popFirst() else { return }
                // Each reads its own copy of the document (Core Graphics documents are not shared across threads).
                let url = request.input
                let layout = layouts.first { $0.number == number }
                group.addTask { CGPDFDocument(url as CFURL).map { ImageText.recognize(document: $0, number: number, languages: languages, layout: layout) } ?? [] }
            }
            for _ in 0..<4 { next() }
            while let lines = try await group.next() {
                try Task.checkCancellation()
                all.append(lines)
                next()
            }
            return all
        }
        let lines = found.sorted { ($0.first?.page ?? 0) < ($1.first?.page ?? 0) }.flatMap { $0 }
        log.write("image text: \(lines.count) lines")
        return lines
    }

    /// TRANS-40: the words read from the pictures, with their translations, by page.
    private func translateImageText(lines: [ImageText.Line], layouts: [PageLayout], provider: TranslationProvider, context: TranslationContext,
                                    cache: TranslationCache, log: TranslationLog, estimate: ProgressEstimate,
                                    refusals: RefusalCount) async throws -> [Int: [(line: ImageText.Line, translation: String)]] {
        guard !lines.isEmpty else { return [:] }
        // A label set over several lines is translated whole (word order differs between languages) and shared out
        // across its lines again.
        let units = ImageTextUnits.units(lines).filter { !ImageTextUnits.isName($0.text) }
        var context = context
        let pagesWithText = Set(lines.map(\.page))
        context.figureCaptions = Array(layouts.filter { pagesWithText.contains($0.number) }
            .flatMap { $0.blocks.filter { $0.kind == .caption }.map { String($0.text.prefix(400)) } }.prefix(12))
        // One segment per distinct text (a label repeated in a figure is translated once), in reading order.
        var translations: [String: String] = [:]
        var pending: [TextSegment] = []
        var seen: Set<String> = []
        for unit in units where seen.insert(unit.text).inserted {
            // A label a service kept as it was is asked again (another service may well translate it).
            if let hit = cache.lookup(unit.text), hit != unit.text { translations[unit.text] = hit } else {
                pending.append(TextSegment(page: 0, block: -1 - pending.count, kind: .figure, source: unit.text, formulas: []))
            }
        }
        // The batches side by side, as the text's.
        var limits = provider.limits
        limits.batchItems = max(limits.batchItems, 120)
        let batches = Self.batches(pending, limits: limits)
        struct Shared: @unchecked Sendable {
            let provider: TranslationProvider, context: TranslationContext, log: TranslationLog, estimate: ProgressEstimate, refusals: RefusalCount
        }
        let shared = Shared(provider: provider, context: context, log: log, estimate: estimate, refusals: refusals)
        let results = try await withThrowingTaskGroup(of: (Int, [String?]).self) { group in
            for (k, batch) in batches.enumerated() {
                group.addTask { [self, shared] in
                    (k, try await translate(batch, provider: shared.provider, context: shared.context, log: shared.log, estimate: shared.estimate,
                                            refusals: shared.refusals))
                }
            }
            var all: [Int: [String?]] = [:]
            for try await (k, texts) in group { all[k] = texts }
            return all
        }
        for (k, batch) in batches.enumerated() {
            for (segment, text) in zip(batch, results[k] ?? []) {
                guard let text, !text.isEmpty else { continue }
                translations[segment.source] = text
                if text != segment.source { cache.store(text, for: segment.source) }
            }
        }
        let cjk = ImageText.isCJK(request.options.langOut)
        var byPage: [Int: [(line: ImageText.Line, translation: String)]] = [:]
        for unit in units {
            guard let translation = translations[unit.text], translation != unit.text else { continue }
            let pieces = ImageTextUnits.split(translation, weights: unit.members.map { lines[$0].vertical ? lines[$0].rect.height : lines[$0].rect.width },
                                              cjk: cjk, language: request.options.langOut)
            for (member, piece) in zip(unit.members, pieces) {
                byPage[lines[member].page, default: []].append((lines[member], piece))
            }
        }
        return byPage
    }

    /// One batch, retried on passing failures (each failure shown at once); a batch that keeps failing is split in halves.
    /// The batch's translations, in order; nil for a paragraph the service refused (content review), which keeps its
    /// original. A translation that lost or duplicated a formula's placeholder is asked for once more.
    private func translate(_ batch: [TextSegment], provider: TranslationProvider, context: TranslationContext,
                           log: TranslationLog, estimate: ProgressEstimate, refusals: RefusalCount) async throws -> [String?] {
        let items = batch.map { TranslationItem(text: $0.source, kind: $0.kind) }
        var context = context
        if provider.limits.usesContext {
            let text = batch.map(\.source).joined(separator: "\n").lowercased()
            context.glossary = Array(context.glossary.filter { text.contains($0.source.lowercased()) }.prefix(80))
        }
        var lastError: Error?
        var refused = false, truncated = false
        let attemptCount = 5
        attempts: for attempt in 0..<attemptCount {
            try Task.checkCancellation()
            try await rateGate.wait()
            let characters = batch.reduce(0) { $0 + $1.source.count }
            let request = estimate.begin(characters: characters)
            do {
                let started = Date()
                // A reply read as it arrives says how far it has come, and that the service is alive.
                let activity = activity
                var texts = try await StreamProgress.$sink.withValue({ received in
                    estimate.received(request, characters: received)
                    activity.touch()
                }) {
                    try await provider.translate(items, context: context).map(Self.clean)
                }
                log.write(String(format: "batch of %d (%d chars) in %.1f s", batch.count, characters, Date().timeIntervalSince(started)))
                estimate.finish(request)
                activity.touch()
                // What a model may get wrong in a text: a formula's placeholder lost or doubled (each has to be there
                // exactly once), nothing given back, or the text given back as it went, untranslated. Such texts get a
                // second chance, and the better of the two answers is kept; failing that, the typesetter puts a missing
                // formula at the end, and a text still untranslated stays as the original.
                let target = context.targetLanguage
                let broken = batch.indices.filter { Self.defects(texts[$0], source: batch[$0].source, target: target) > 0 }
                if !broken.isEmpty, provider.limits.usesContext {
                    log.write("\(broken.count) of \(batch.count) came back incomplete (placeholders lost, empty or untranslated), asking again")
                    if let again = try? await provider.translate(broken.map { items[$0] }, context: context).map(Self.clean) {
                        for (k, i) in broken.enumerated() where k < again.count
                            && Self.defects(again[k], source: batch[i].source, target: target) < Self.defects(texts[i], source: batch[i].source, target: target) {
                            texts[i] = again[k]
                        }
                    }
                }
                return texts
            } catch let error as ProviderError {
                estimate.abandon(request)
                lastError = error
                log.write("attempt \(attempt + 1) failed: \(error.detail.prefix(500))")
                if error.kind == .refused {
                    refused = true
                    break attempts
                }
                // Cut off at the model's output limit: the same batch would be cut off again; smaller ones fit.
                if error.kind == .truncated {
                    guard batch.count > 1 else { throw EngineError.replyCutOff }
                    truncated = true
                    break attempts
                }
                guard error.isRetryable else { throw error }
                activity.touch()
                // Shown now, with what the service said: the job is not stuck, and the user may well fix the cause.
                // The last attempt: the job ends with the error, no waiting first.
                guard attempt + 1 < attemptCount else { break }
                let said = Self.message(for: error)
                activity.report(String(localized: "\(said)（正在第 \(attempt + 2) 次尝试）", bundle: .module), key: said)
                let wait = error.retryAfter ?? min(20, pow(2, Double(attempt)) * 1.5)
                if case .http(429) = error.kind {
                    // Rate limited: every batch of this job holds back, not just this one.
                    await rateGate.pause(for: wait)
                } else {
                    try await Task.sleep(for: .seconds(wait))
                }
                // An unreadable reply for a big batch: try smaller ones.
                if case .invalidResponse = error.kind, batch.count > 1, attempt >= 1 { break }
            }
        }
        // Halves until the paragraph that is the problem is found: a refusal or an unreadable reply. A failure of the
        // service itself (it is down, a process error) is the same for half the text, and is not tried again and again.
        let byContent: Bool = refused || truncated || {
            if case .invalidResponse = (lastError as? ProviderError)?.kind { return true }
            return false
        }()
        if batch.count > 1, byContent {
            let half = batch.count / 2
            let first = try await translate(Array(batch[..<half]), provider: provider, context: context, log: log, estimate: estimate, refusals: refusals)
            let second = try await translate(Array(batch[half...]), provider: provider, context: context, log: log, estimate: estimate, refusals: refusals)
            return first + second
        }
        if refused {
            log.write("refused by the service: p\(batch[0].page) \"\(batch[0].source.prefix(80))\"")
            guard refusals.add() else { throw EngineError.tooManyRefused(refusals.count) }
            return [nil]
        }
        throw lastError ?? ProviderError(kind: .invalidResponse, detail: "translation failed")
    }

    /// Every formula placeholder of the source once, none added. `{v0}` (a break) may move or go.
    static func placeholdersIntact(_ text: String, source: String) -> Bool {
        placeholderErrors(text, source: source) == 0
    }

    static func placeholderErrors(_ text: String, source: String) -> Int {
        var want: [Int: Int] = [:], got: [Int: Int] = [:]
        for n in Placeholders.numbers(in: source) where n != 0 { want[n, default: 0] += 1 }
        for n in Placeholders.numbers(in: text) where n != 0 { got[n, default: 0] += 1 }
        return Set(want.keys).union(got.keys).reduce(0) { $0 + abs((want[$1] ?? 0) - (got[$1] ?? 0)) }
    }

    /// How much is wrong with a translation: its placeholder errors, and far more when it is empty or untranslated.
    static func defects(_ text: String, source: String, target: String) -> Int {
        placeholderErrors(text, source: source) + (isUntranslated(text, source: source, target: target) ? 100 : 0)
    }

    /// Nothing came back for a text with words in it, or the text came back as it went: a sentence (four words or
    /// more) that is the source again, or, for a language written in another script than the source's (Chinese,
    /// Japanese, Korean), without a single character of that script. Names, numbers and short labels may well stay
    /// as they are, and do not count.
    static func isUntranslated(_ text: String, source: String, target: String) -> Bool {
        guard SegmentBuilder.hasWords(source) else { return false }
        let translation = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if translation.isEmpty { return true }
        let plain = Placeholders.replace(in: source) { _ in " " }
        let words = plain.split(whereSeparator: { !$0.isLetter }).filter { $0.count >= 2 }
        guard words.count >= 4, !SegmentBuilder.isInScript(of: target, plain, share: 0.3) else { return false }
        if translation == source.trimmingCharacters(in: .whitespacesAndNewlines) { return true }
        let language = target.lowercased()
        guard ["zh", "ja", "ko"].contains(where: { language.hasPrefix($0) }) else { return false }
        return !translation.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
                || (0xAC00...0xD7AF).contains(scalar.value)
        }
    }

    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Context

    /// The abstract: the first long paragraph on the first page.
    static func summary(of segments: [TextSegment]) -> String? {
        let firstPage = segments.filter { $0.page == segments.first?.page && $0.kind == .paragraph }
        let long = firstPage.first { $0.source.split(separator: " ").count >= 60 } ?? firstPage.first
        return long.map { Placeholders.replace(in: $0.source) { _ in "…" } }
    }

    /// What terms are learnt from: title, abstract, headings and captions.
    static func termExcerpt(_ segments: [TextSegment]) -> String {
        var parts: [String] = []
        if let title = segments.first(where: { $0.kind == .title }) { parts.append(title.source) }
        if let summary = summary(of: segments) { parts.append(summary) }
        parts += segments.filter { $0.kind == .heading }.map(\.source)
        parts += segments.filter { $0.kind == .caption }.map(\.source)
        parts += segments.filter { $0.kind == .paragraph }.prefix(6).map(\.source)
        var excerpt = ""
        for part in parts where excerpt.count + part.count < 6000 { excerpt += Placeholders.replace(in: part) { _ in "…" } + "\n" }
        return excerpt
    }

    /// A CSV glossary: `source,target` per line (more columns are ignored; a field with a comma in it is in quotes).
    static func readGlossary(_ url: URL?) -> [GlossaryEntry] {
        guard let url, var text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        // A byte order mark (files saved by Excel, or exported on Windows) is not part of the first term.
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let columns = csvFields(String(line))
            guard columns.count >= 2, !columns[0].isEmpty, !columns[1].isEmpty, columns[0].lowercased() != "source" else { return nil }
            return GlossaryEntry(source: columns[0], target: columns[1])
        }
    }

    /// The fields of a CSV line: split at commas outside quotes, `""` inside quotes being a quote.
    static func csvFields(_ line: String) -> [String] {
        var fields: [String] = [], field = "", quoted = false
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            let c = characters[index]
            if c == "\"" {
                if quoted, index + 1 < characters.count, characters[index + 1] == "\"" { field.append("\""); index += 1 } else { quoted.toggle() }
            } else if c == ",", !quoted {
                fields.append(field.trimmingCharacters(in: .whitespaces)); field = ""
            } else {
                field.append(c)
            }
            index += 1
        }
        fields.append(field.trimmingCharacters(in: .whitespaces))
        return fields
    }
}

enum EngineError: Error, LocalizedError {
    case unreadable, encrypted, noText
    /// Everything there is to translate is already in this language.
    case alreadyInTarget(String)
    /// The service refused this many paragraphs: more than a few, so something else is wrong.
    case tooManyRefused(Int)
    /// The model's reply ends at its output limit even for a single paragraph.
    case replyCutOff

    var errorDescription: String? {
        switch self {
        case .unreadable: String(localized: "无法读取这个 PDF 文件。", bundle: .module)
        case .encrypted: String(localized: "PDF 已加密或受密码保护，无法翻译。", bundle: .module)
        case .noText: String(localized: "这个 PDF 中没有可翻译的文字（可能是扫描件，需要先进行文字识别）。", bundle: .module)
        case .alreadyInTarget(let language):
            String(localized: "这篇论文已经是\(language)，不需要翻译成\(language)。可以在翻译设置里换一种译文语言。", bundle: .module)
        case .tooManyRefused(let count):
            String(localized: "翻译服务拒绝翻译 \(count) 个段落（内容审核）。请换一个翻译服务或模型再试。", bundle: .module)
        case .replyCutOff:
            String(localized: "模型的回复在输出上限处被截断，连一个段落也放不下。请换用输出上限更高的模型，或调低思考程度。", bundle: .module)
        }
    }
}

/// Paragraphs a service refused to translate, up to how many are put up with.
final class RefusalCount: @unchecked Sendable {
    private let lock = NSLock()
    private var refused = 0
    let limit: Int

    init(limit: Int) { self.limit = limit }

    var count: Int { lock.withLock { refused } }

    /// Counts one more; false once there are more than the limit.
    func add() -> Bool { lock.withLock { refused += 1; return refused <= limit } }
}

/// Holds every request of a job back after the service said it gets too many.
actor RateGate {
    private var until = Date.distantPast

    func pause(for seconds: Double) {
        until = max(until, Date().addingTimeInterval(seconds))
    }

    func wait() async throws {
        while Date() < until {
            try await Task.sleep(for: .seconds(until.timeIntervalSinceNow))
        }
    }
}

/// The glossary, growing when extracted terms arrive.
final class GlossaryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [GlossaryEntry]

    private var complete = false

    init(_ entries: [GlossaryEntry]) { stored = entries }

    var entries: [GlossaryEntry] { lock.withLock { stored } }

    /// The paper's terms are in (or could not be had).
    var isComplete: Bool { lock.withLock { complete } }

    func markComplete() { lock.withLock { complete = true } }

    /// Returns once the paper's terms are in, at `deadline` at the latest (or when the task is cancelled).
    func wait(until deadline: Date) async {
        while !isComplete, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Adds terms the user's glossary does not already have.
    func add(_ terms: [GlossaryEntry]) {
        lock.withLock {
            let known = Set(stored.map { $0.source.lowercased() })
            stored += terms.filter { !known.contains($0.source.lowercased()) }
        }
    }
}

/// Runs `body`, failing with a timeout when it takes longer than `seconds`.
func withTimeout<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw ProviderError(kind: .network, detail: "timed out after \(Int(seconds)) s")
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

// MARK: - Progress

/// Reports progress that only goes forward, in small enough steps not to flood whoever is listening.
final class MonotonicProgress: @unchecked Sendable {
    private let emit: @Sendable (TranslationEvent) -> Void
    private let lock = NSLock()
    private var last = 0.0

    init(emit: @escaping @Sendable (TranslationEvent) -> Void) { self.emit = emit }

    func report(_ value: Double) {
        let next: Double? = lock.withLock {
            let clamped = min(max(value, last), 1)
            guard clamped - last >= 0.0005 || (clamped >= 1 && last < 1) else { return nil }
            last = clamped
            return clamped
        }
        if let next { emit(.progress(next)) }
    }
}

/// What the progress bar is heading for, which changes from stage to stage.
final class ProgressTarget: @unchecked Sendable {
    private let lock = NSLock()
    private var current: @Sendable () -> Double

    init(_ value: @escaping @Sendable () -> Double) { current = value }

    func set(_ value: @escaping @Sendable () -> Double) { lock.withLock { current = value } }
    func value() -> Double { lock.withLock { current } () }
}

/// How far the translation has come, at any moment: what is done, plus how far the requests under way are.
///
/// A service that sends its reply as it writes it says how far each request is: the characters received, against how
/// long such a reply usually is (measured on this job's replies; at first, what is usual for the language). Before
/// the first of them arrives (the model reads, and thinks), and for services that only answer when they are done, a
/// request counts by the time it has taken against what requests of this job took so far; it never gets ahead of a
/// request that takes longer than expected, it slows down.
final class ProgressEstimate: @unchecked Sendable {
    private struct Running { var characters: Double; var started: Date; var received = 0.0 }
    private let lock = NSLock()
    private var running: [Int: Running] = [:]
    private var nextID = 0
    private var done: Double
    private let total: Double
    private let startup: Double
    private var secondsPerCharacter: Double
    private var measured = false
    /// Characters of reply for each character sent, as replies come in.
    private var replyPerCharacter: Double
    private var measuredReply = false
    /// Replies of this job arrive piece by piece.
    private var streams = false
    private var highest = 0.0
    private let clock: @Sendable () -> Date

    init(done: Int, total: Int, limits: ProviderLimits, replyPerCharacter: Double = 0.6, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.done = Double(done)
        self.total = Double(max(total, 1))
        startup = limits.startupSeconds
        secondsPerCharacter = limits.secondsPerCharacter
        self.replyPerCharacter = replyPerCharacter
        self.clock = clock
    }

    func begin(characters: Int) -> Int {
        lock.withLock {
            nextID += 1
            running[nextID] = Running(characters: Double(characters), started: clock())
            return nextID
        }
    }

    /// So much of the reply to request `id` has arrived (it may start over: a part asked for again).
    func received(_ id: Int, characters: Int) {
        guard characters > 0 else { return }
        lock.withLock {
            streams = true
            if let request = running[id] { running[id]?.received = max(request.received, Double(characters)) }
        }
    }

    func finish(_ id: Int) {
        lock.withLock {
            guard let request = running.removeValue(forKey: id) else { return }
            done += request.characters
            let rate = max(clock().timeIntervalSince(request.started) - startup, 0.05) / max(request.characters, 1)
            secondsPerCharacter = measured ? (secondsPerCharacter + rate) / 2 : rate
            measured = true
            if request.received > 0, request.characters > 0 {
                let reply = request.received / request.characters
                replyPerCharacter = measuredReply ? (replyPerCharacter + reply) / 2 : reply
                measuredReply = true
            }
        }
    }

    /// A request that failed: its part is not done after all (the bar stays where it is until the retry catches up).
    func abandon(_ id: Int) { _ = lock.withLock { running.removeValue(forKey: id) } }

    /// Share of the work done, 0…1; it never goes back.
    func fraction() -> Double {
        lock.withLock {
            let now = clock()
            var sum = done
            for request in running.values {
                let expected = startup + request.characters * secondsPerCharacter
                let byTime = Self.share(elapsed: now.timeIntervalSince(request.started) / expected)
                // While nothing of a streamed reply has come, time only says that the request is under way.
                var share = streams ? min(byTime, 0.15) : byTime
                if request.received > 0 {
                    share = max(share, min(request.received / max(request.characters * replyPerCharacter, 1), 0.97))
                }
                sum += request.characters * share
            }
            highest = max(highest, min(sum / total, 1))
            return highest
        }
    }

    /// How much of a request to count after `elapsed` times its expected time: steadily up to nine tenths, then ever
    /// more slowly, so a slow one keeps moving without being counted as done.
    static func share(elapsed x: Double) -> Double {
        x <= 1 ? 0.9 * max(x, 0) : 0.9 + 0.09 * (1 - 1 / (1 + (x - 1) / 1.5))
    }
}

// MARK: - State

/// Translations so far, shared by the concurrent batches.
final class TranslationState: @unchecked Sendable {
    private let lock = NSLock()
    private var translations: [String: String] = [:]
    private let segments: [TextSegment]
    private let totalCharacters: Int
    private var doneCharacters = 0
    private var remainingByPage: [Int: Int]

    init(segments: [TextSegment]) {
        self.segments = segments
        totalCharacters = max(1, segments.reduce(0) { $0 + $1.source.count })
        remainingByPage = Dictionary(grouping: segments, by: \.page).mapValues(\.count)
    }

    func store(_ text: String, for segment: TextSegment) {
        lock.withLock {
            guard translations[segment.id] == nil else { return }
            translations[segment.id] = text
            doneCharacters += segment.source.count
            remainingByPage[segment.page, default: 1] -= 1
        }
    }

    func translation(for segment: TextSegment) -> String? { lock.withLock { translations[segment.id] } }
    func snapshot() -> [String: String] { lock.withLock { translations } }
    var doneCount: Int { lock.withLock { translations.count } }
    var characters: (done: Int, total: Int) { lock.withLock { (doneCharacters, totalCharacters) } }
    var completedPages: Set<Int> { lock.withLock { Set(remainingByPage.filter { $0.value <= 0 }.keys) } }
}

/// Writes preview PDFs while the translation runs: when more pages are done, at most every few seconds, one at
/// a time in the background.
final class PreviewWriter: @unchecked Sendable {
    private let renderer: TranslationRenderer
    private let layouts: [PageLayout]
    private let segments: [TextSegment]
    private let directory: URL
    private let emit: @Sendable (TranslationEvent) -> Void
    private let lock = NSLock()
    private var shownPages = 0
    private var lastWrite = Date.distantPast
    private var running: Task<Void, Never>?
    private var counter = 0

    init(renderer: TranslationRenderer, layouts: [PageLayout], segments: [TextSegment], directory: URL,
         emit: @escaping @Sendable (TranslationEvent) -> Void) {
        self.renderer = renderer
        self.layouts = layouts
        self.segments = segments
        self.directory = directory
        self.emit = emit
    }

    func update(_ translations: [String: String], pagesDone: Set<Int>) {
        lock.lock()
        defer { lock.unlock() }
        guard pagesDone.count > shownPages, running == nil, Date().timeIntervalSince(lastWrite) > 3,
              pagesDone.count < Set(segments.map(\.page)).count else { return }
        shownPages = pagesDone.count
        lastWrite = Date()
        counter += 1
        let url = directory.appending(path: "preview-\(counter).pdf")
        let previous = counter > 2 ? directory.appending(path: "preview-\(counter - 2).pdf") : nil
        running = Task.detached(priority: .utility) { [self] in
            let output = renderer.render(layouts: layouts, segments: segments, translations: translations, mono: true, dual: false,
                                         dualLayout: .sideBySide, title: nil)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = output.mono, (try? data.write(to: url)) != nil, !Task.isCancelled { emit(.preview(url)) }
            if let previous { try? FileManager.default.removeItem(at: previous) }
            lock.withLock { running = nil }
        }
    }

    func finish() async {
        let task = lock.withLock { running }
        task?.cancel()
        await task?.value
    }
}

/// Earlier translations of the same text, per document and translator, kept on disk.
final class TranslationCache: @unchecked Sendable {
    private let url: URL
    private let ignore: Bool
    private var entries: [String: String] = [:]
    private var dirty = 0
    private let lock = NSLock()

    init(directory: URL, document: URL, signature: String, ignore: Bool) {
        self.ignore = ignore
        var hasher = SHA256()
        hasher.update(data: Data(signature.utf8))
        if let handle = try? FileHandle(forReadingFrom: document) {
            hasher.update(data: (try? handle.read(upToCount: 1 << 20)) ?? Data())
            try? handle.close()
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: document.path)[.size] as? Int) ?? 0
        hasher.update(data: Data(String(size).utf8))
        let key = hasher.finalize().prefix(12).map { String(format: "%02x", $0) }.joined()
        url = directory.appending(path: "\(key).json")
        if let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode([String: String].self, from: data) {
            entries = stored
        }
        Self.prune(directory)
    }

    private static func key(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    func lookup(_ source: String) -> String? {
        guard !ignore else { return nil }
        // An empty entry (kept by earlier versions when a service gave nothing back) is no translation.
        return lock.withLock { entries[Self.key(source)] }.flatMap { $0.isEmpty ? nil : $0 }
    }

    func store(_ text: String, for source: String) {
        guard !text.isEmpty else { return }
        lock.withLock {
            entries[Self.key(source)] = text
            dirty += 1
        }
    }

    func saveIfNeeded() { if lock.withLock({ dirty >= 20 }) { save() } }

    func save() {
        let data: Data? = lock.withLock {
            dirty = 0
            return try? JSONEncoder().encode(entries)
        }
        guard let data else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Caches unused for 60 days go.
    private static func prune(_ directory: URL) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        let limit = Date().addingTimeInterval(-60 * 24 * 3600)
        for file in files where (try? file.resourceValues(forKeys: Set(keys)).contentModificationDate).flatMap({ $0 }).map({ $0 < limit }) == true {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// The job's log: what was sent, how long it took, what failed (never keys).
final class TranslationLog: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    init(url: URL) {
        self.url = url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }

    func write(_ line: String) {
        lock.withLock {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data("\(formatter.string(from: Date())) \(line)\n".utf8))
        }
    }
}

extension PageLayout {
    /// A page kept as it is (outside the selected pages).
    static func untouched(_ document: CGPDFDocument, number: Int) -> PageLayout? {
        guard let page = document.page(at: number) else { return nil }
        let media = page.getBoxRect(.mediaBox)
        var crop = page.getBoxRect(.cropBox).intersection(media)
        if crop.isNull || crop.width < 1 { crop = media }
        return PageLayout(number: number, mediaBox: media, cropBox: crop, blocks: [], figures: [], tables: [], graphics: [], runs: [])
    }
}

/// What goes wrong while a job works, shown at once (the same message not more than every 20 seconds), and when a
/// request last came back (or failed): a minute without either, and the progress says what it waits for.
final class JobActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var emit: (@Sendable (TranslationEvent) -> Void)?
    private var shown: [String: Date] = [:]
    private var last = Date()

    func attach(_ emit: @escaping @Sendable (TranslationEvent) -> Void) { lock.withLock { self.emit = emit; last = Date() } }

    func touch() { lock.withLock { last = Date() } }

    var idleSeconds: Double { lock.withLock { Date().timeIntervalSince(last) } }

    /// Shows `message`, unless the same thing (`key`) was shown in the last 20 seconds.
    func report(_ message: String, key: String? = nil) {
        let key = key ?? message
        let send: (@Sendable (TranslationEvent) -> Void)? = lock.withLock {
            if let at = shown[key], Date().timeIntervalSince(at) < 20 { return nil }
            shown[key] = Date()
            return emit
        }
        send?(.problem(message))
    }
}
