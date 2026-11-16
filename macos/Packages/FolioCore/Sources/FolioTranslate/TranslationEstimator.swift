import CoreGraphics
import Foundation
import PDFKit

/// What a translation is expected to take, before it starts: how much text goes to the service, about how many tokens
/// that is with a large language model, and, where the model's public price is known, about what it costs.
///
/// An estimate, and said so wherever it shows: tokens are counted by rule of thumb (each tokenizer differs), what a
/// model thinks before answering is not in it, and prices change.
public struct TranslationEstimate: Sendable, Equatable {
    /// Characters still to translate (what earlier runs left in the cache, standard headings and repeats are not sent).
    public var characters = 0
    /// Characters of everything translatable on the pages.
    public var totalCharacters = 0
    public var inputTokens = 0
    public var outputTokens = 0
    /// In US dollars; nil when the model's price is not known.
    public var cost: Double?
    /// The service charges by the character (machine translation), not by the token.
    public var byCharacter = false

    public static func + (a: TranslationEstimate, b: TranslationEstimate) -> TranslationEstimate {
        TranslationEstimate(characters: a.characters + b.characters, totalCharacters: a.totalCharacters + b.totalCharacters,
                            inputTokens: a.inputTokens + b.inputTokens, outputTokens: a.outputTokens + b.outputTokens,
                            cost: a.cost.flatMap { x in b.cost.map { x + $0 } }, byCharacter: a.byCharacter || b.byCharacter)
    }
}

/// Public prices of the models most used for translating, in US dollars per million tokens (input, output), as their
/// makers listed them in November 2026. A model not listed here has no price shown, only its tokens.
public enum TranslationPricing {
    public static let asOf = "2026-11"

    /// By the start of the model's name (the longest match wins), provider prefixes of gateways aside.
    static let perMillion: [(prefix: String, input: Double, output: Double)] = [
        // OpenAI
        ("gpt-6-astra", 10, 50), ("gpt-6.1-sol", 2, 10), ("gpt-6.1-terra", 1, 5), ("gpt-6-luna", 0.10, 0.50), ("gpt-6-sol", 2, 10),
        ("gpt-5.6-sol", 4, 20), ("gpt-5.6-terra", 2, 12), ("gpt-5.6-luna", 0.20, 1.20), ("gpt-5.5-pro", 30, 180), ("gpt-5.5", 5, 30),
        ("gpt-5.4-pro", 30, 180), ("gpt-5.4-mini", 0.75, 4.50), ("gpt-5.4-nano", 0.20, 1.25), ("gpt-5.4", 2.50, 15),
        ("gpt-5.2-pro", 21, 168), ("gpt-5.2", 1.75, 14), ("gpt-5.1", 1.25, 10), ("gpt-5-mini", 0.25, 2), ("gpt-5-nano", 0.05, 0.40),
        ("gpt-5-pro", 15, 120), ("gpt-5", 1.25, 10), ("gpt-4.1-mini", 0.40, 1.60), ("gpt-4.1", 2, 8), ("gpt-4o-mini", 0.15, 0.60),
        ("gpt-4o", 2.50, 10), ("o3-pro", 20, 80), ("o3", 2, 8),
        // Anthropic
        ("claude-fable-5-2", 8, 40), ("claude-fable-5", 10, 50), ("claude-opus-5-5", 4, 20), ("claude-opus-5", 5, 25),
        ("claude-opus-4-8", 5, 25), ("claude-opus-4-7", 5, 25), ("claude-opus-4-6", 5, 25), ("claude-sonnet-5", 2, 10),
        ("claude-sonnet-4-6", 3, 15), ("claude-haiku-5-5", 0.10, 0.50), ("claude-haiku-4-5", 1, 5),
        // Gemini
        ("gemini-3.8-flash", 0.75, 3.75), ("gemini-3.6-flash", 0.75, 3.75), ("gemini-3.5-flash-lite", 0.30, 2.50),
        ("gemini-3.1-pro", 2, 12), ("gemini-3.1-flash-lite", 0.25, 1.50), ("gemini-3-flash", 0.50, 3),
        ("gemini-2.5-pro", 1.25, 10), ("gemini-2.5-flash-lite", 0.10, 0.40), ("gemini-2.5-flash", 0.30, 2.50),
        // DeepSeek (its peak-hour prices; off-peak is half)
        ("deepseek-flash", 0.30, 1.20), ("deepseek-v4-flash", 0.30, 1.20), ("deepseek-v4-pro", 1.32, 3.96),
    ]

    /// The price of `model`, per million tokens.
    public static func price(model: String) -> (input: Double, output: Double)? {
        let name = model.lowercased().split(separator: "/").last.map(String.init) ?? model.lowercased()
        return perMillion.filter { name.hasPrefix($0.prefix) }.max { $0.prefix.count < $1.prefix.count }.map { ($0.input, $0.output) }
    }
}

public enum TranslationEstimator {
    /// About how many tokens `text` is: Latin text runs to four characters a token, Chinese, Japanese and Korean to
    /// well under two.
    static func tokens(_ text: String) -> Double {
        var total = 0.0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0..<0x80: total += 0.25
            case 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF: total += 0.7
            default: total += 0.5
            }
        }
        return total
    }

    /// What translating `request` is expected to take; nil when the service costs nothing to use (free services,
    /// models on this Mac, agents that run on a subscription) or the PDF cannot be read. Analyses the pages, so call
    /// it off the main thread.
    public static func estimate(_ request: TranslationRequest) -> TranslationEstimate? {
        guard let service = TranslationServiceCatalog.service(id: request.serviceID), service.category == .llm || service.category == .machine,
              service.backend != .command,
              let cg = CGPDFDocument(request.input as CFURL), let document = PDFDocument(url: request.input) else { return nil }
        let options = request.options
        var analyzer = LayoutAnalyzer(options: .init(translateTables: options.translateTables, translateReferences: options.translateReferences))
        let layouts = analyzer.analyze(document: document, cgDocument: cg, pages: options.pageNumbers(count: cg.numberOfPages))
        let segments = SegmentBuilder.segments(for: layouts, target: options.langOut)
        let cache = TranslationCache(directory: TranslationJob.supportDirectory.appending(path: "cache", directoryHint: .isDirectory),
                                     document: request.input, signature: TranslationJob.signature(of: request), ignore: options.ignoreCache)
        // What the job would send: nothing it has from before, nothing it sets from its own lists, and each text once.
        var seen: Set<String> = []
        let pending = segments.filter { segment in
            if segment.kind == .heading, StandardHeadings.translate(segment.source, to: options.langOut) != nil { return false }
            if segment.kind == .tableCell, StandardCells.translate(segment.source, to: options.langOut) != nil { return false }
            return cache.lookup(segment.source) == nil && seen.insert(segment.source).inserted
        }
        var estimate = TranslationEstimate(characters: pending.reduce(0) { $0 + $1.source.count },
                                           totalCharacters: segments.reduce(0) { $0 + $1.source.count })
        guard service.isLLM else {
            estimate.byCharacter = true
            return estimate
        }
        guard !pending.isEmpty else {
            estimate.cost = 0
            return estimate
        }
        let model = service.fields.first { $0.title == TranslationServiceCatalog.modelFieldTitle }
            .flatMap { request.fieldValues[$0.option].flatMap { $0.isEmpty ? nil : $0 } ?? $0.defaultValue } ?? ""
        let text = pending.reduce(0.0) { $0 + tokens($1.source) }
        // Each batch carries the instructions, the paper's title and abstract and its terms; the terms are asked for once.
        let batches = (Double(estimate.characters) / 2600).rounded(.up)
        let title = segments.first { $0.kind == .title }?.source ?? ""
        let abstract = String((TranslationJob.summary(of: segments) ?? "").prefix(1500))
        let perBatch = 420 + tokens(title) + tokens(abstract) + 150
        let excerpt = tokens(TranslationJob.termExcerpt(segments))
        let input = text + Double(pending.count) * 6 + batches * perBatch + excerpt + 120
        // A translation into Chinese, Japanese or Korean takes more tokens than its English source, though fewer characters.
        let output = text * (ImageText.isCJK(options.langOut) ? 1.3 : 1.1) + Double(pending.count) * 6 + 500
        estimate.inputTokens = Int(input)
        estimate.outputTokens = Int(output)
        if let price = TranslationPricing.price(model: model) {
            estimate.cost = (input * price.input + output * price.output) / 1_000_000
        }
        return estimate
    }

    /// The estimate in a line, for the sheet that starts a translation; nil when there is nothing to say (a scan
    /// whose text is not read yet).
    public static func text(for estimate: TranslationEstimate) -> String? {
        guard estimate.totalCharacters > 0 else { return nil }
        if estimate.characters == 0 {
            return String(localized: "译文已在缓存中，不需要再次请求翻译服务。", bundle: .module)
        }
        if estimate.byCharacter {
            return String(localized: "预计发送约 \(count(estimate.characters)) 个字符（按字符计费的服务）。", bundle: .module)
        }
        let input = count(estimate.inputTokens), output = count(estimate.outputTokens)
        guard let cost = estimate.cost else {
            return String(localized: "预计约 \(input) 输入 + \(output) 输出 tokens（估算，不含模型思考）。", bundle: .module)
        }
        let price = cost < 0.01 ? String(localized: "不到 $0.01", bundle: .module) : String(format: "$%.2f", cost)
        return String(localized: "预计约 \(input) 输入 + \(output) 输出 tokens，费用约 \(price)（按公开价格估算，不含模型思考）。", bundle: .module)
    }

    /// A count to two figures: "1,200", "4.2 万" or "42k".
    static func count(_ n: Int) -> String {
        guard n >= 10_000 else { return String((Double(n) / 100).rounded() * 100 >= 1000 ? Int((Double(n) / 100).rounded() * 100) : n) }
        let chinese = (Bundle.module.preferredLocalizations.first ?? "zh-Hans").hasPrefix("zh")
        if chinese { return String(format: "%.1f 万", Double(n) / 10_000).replacingOccurrences(of: ".0 ", with: " ") }
        return String(format: "%.0fk", Double(n) / 1000)
    }
}
