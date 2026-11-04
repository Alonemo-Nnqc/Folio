import CoreGraphics
import Foundation
import Testing
@testable import FolioTranslate

/// What goes to the service, and what comes back, holds together.
@Suite struct BatchTests {
    @Test func paragraphsGoInReadingOrder() {
        // Sorted keys would read "1, 10, 11, 12, 2, …": the model would see the paper out of order.
        let items = (1...12).map { TranslationItem(text: "paragraph \($0)", kind: .paragraph) }
        let message = LLMBatch.userMessage(items)
        let positions = (1...12).map { message.range(of: "\"paragraph \($0)\"")!.lowerBound }
        #expect(positions == positions.sorted())
        #expect(message.hasPrefix("{\"1\": \"paragraph 1\", \"2\": "))
        #expect(LLMBatch.parse(message, count: 12) == items.map(\.text))
    }

    @Test func textsWithQuotesAndBreaksStayValidJSON() throws {
        let message = LLMBatch.userMessage([TranslationItem(text: "a \"quoted\" word\\ and / slash", kind: .paragraph)])
        let object = try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: String]
        #expect(object?["1"] == "a \"quoted\" word\\ and / slash")
    }

    @Test func aLostFormulaIsNoticed() {
        let source = "Given {v1}, the encoder makes {v2} where {v3}."
        #expect(TranslationJob.placeholdersIntact("给定 {v1}，编码器生成 {v2}，其中 {v3}。", source: source))
        #expect(TranslationJob.placeholderErrors("给定 {v1}，编码器生成 {v2}。", source: source) == 1)
        #expect(TranslationJob.placeholderErrors("给定 {v1}{v1}，编码器生成 {v2}，其中 {v3}。", source: source) == 1)
        // The break marker may move or go.
        #expect(TranslationJob.placeholdersIntact("{v0}给定 {v1}，{v2}，{v3}", source: source))
    }

    @Test func refusalsAreToldFromOtherErrors() {
        #expect(ProviderError.isContentRefusal(#"{"error":{"code":"data_inspection_failed","message":"Input data may contain inappropriate content."}}"#))
        #expect(ProviderError.isContentRefusal("Content Exists Risk"))
        #expect(ProviderError.isContentRefusal("\"finish_reason\": \"content_filter\""))
        #expect(ProviderError.isContentRefusal("输入内容包含敏感词"))
        #expect(!ProviderError.isContentRefusal("Incorrect API key provided"))
        #expect(!ProviderError.isContentRefusal("model not found"))
        #expect(ProviderError.isDecline("I'm sorry, but I can't help with that."))
        #expect(!ProviderError.isDecline("{\"1\": \"抱歉\"}"))
        #expect(AgentFailure.classify("API Error: 400 Output blocked by content filtering policy", agent: .claude).kind == .refused)
        #expect(!ProviderError(kind: .refused, detail: "").isRetryable)
    }

    @Test func refusalsAreCountedUpToTheLimit() {
        let count = RefusalCount(limit: 2)
        #expect(count.add())
        #expect(count.add())
        #expect(!count.add())
        #expect(count.count == 3)
    }

    @Test func aStoppedJobStopsItsCommandAtOnce() async throws {
        let started = Date()
        let task = Task { try await LocalProcess.run(["/bin/sleep", "30"], input: "", timeout: 60) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        _ = try? await task.value
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func aPaperAlreadyInTheTargetLanguageSaysSo() {
        let message = EngineError.alreadyInTarget("简体中文").errorDescription ?? ""
        #expect(message.contains("简体中文"))
        #expect(!message.contains("扫描"))
    }
}

/// A paragraph cut by a column or page break goes as one text and is set again in its two places.
@Suite struct ContinuationTests {
    private func segment(_ text: String, page: Int, block: Int, formulas: Int = 0) -> TextSegment {
        TextSegment(page: page, block: block, kind: .paragraph, source: text,
                    formulas: Array(repeating: FormulaSpan(rect: .zero, baseline: 0), count: formulas))
    }

    @Test func aHyphenatedWordComesTogetherAtTheBreak() {
        let c = Continuations.make([segment("we compute the in-", page: 1, block: 0), segment("formation of {v1} here", page: 2, block: 0, formulas: 1)])
        #expect(c.joined.source == "we compute the {v0}information of {v1} here")
        let compound = Continuations.make([segment("the state-of-the-", page: 1, block: 0), segment("art methods", page: 2, block: 0)])
        #expect(compound.joined.source == "the {v0}state-of-the-art methods")
        let plain = Continuations.make([segment("we use {v1} and", page: 1, block: 0, formulas: 1), segment("{v1} for {v2}", page: 1, block: 3, formulas: 2)])
        #expect(plain.joined.source == "we use {v1} and {v0} {v2} for {v3}")
    }

    @Test func theTranslationIsCutWhereTheTranslatorKeptTheBreak() throws {
        let c = Continuations.make([segment("we use {v1} and the same", page: 1, block: 0, formulas: 1),
                                    segment("model for {v1} again", page: 1, block: 3, formulas: 1)])
        let pieces = try #require(Continuations.split("我们使用 {v1} 以及相同的{v0}模型来处理 {v2}", c))
        #expect(pieces == ["我们使用 {v1} 以及相同的", "模型来处理 {v1}"])
    }

    @Test func withoutTheMarkerTheCutKeepsFormulasWithTheirPart() throws {
        let c = Continuations.make([segment("first part with {v1} in it", page: 1, block: 0, formulas: 1),
                                    segment("second part with {v1} in it", page: 2, block: 0, formulas: 1)])
        let pieces = try #require(Continuations.split("第一部分包含 {v1}，第二部分包含 {v2}。", c))
        #expect(pieces[0].contains("{v1}") && !pieces[0].contains("{v2}"))
        #expect(pieces[1].contains("{v1}") && !pieces[1].contains("{v2}"))
        // A formula of the second part moved before one of the first: no cut keeps both with their part.
        #expect(Continuations.split("第二部分 {v2} 在前，第一部分 {v1} 在后", c) == nil)
    }

    @Test func aMarkerFarFromWhereThePartsEndIsNotTrusted() throws {
        let c = Continuations.make([segment(String(repeating: "word ", count: 40), page: 1, block: 0),
                                    segment(String(repeating: "word ", count: 40), page: 2, block: 0)])
        let text = "甲{v0}" + String(repeating: "乙", count: 80) + "，" + String(repeating: "丙", count: 80)
        let pieces = try #require(Continuations.split(text, c))
        #expect(abs(pieces[0].count - pieces[1].count) < 20)
    }

    @Test func sentencesThatEndAreLeftAlone() {
        #expect(Continuations.endsSentence("This is the end."))
        #expect(Continuations.endsSentence("as shown (see [3]).”"))
        #expect(!Continuations.endsSentence("the model and"))
        #expect(!Continuations.endsSentence("computa-"))
    }
}

/// Glyphs of one formula stay with it, wherever their position puts them.
@Suite struct DrawingOrderTests {
    private func chars(_ text: String, x: Double, baseline: Double, size: Double = 8, glyph: Int, math: Bool = false) -> [PageChar] {
        text.enumerated().map { k, c in
            var char = PageChar(text: String(c), rect: CGRect(x: x + Double(k) * 4, y: baseline - size * 0.2, width: 4, height: size * 1.2),
                                isSpace: c == " ", isNewline: false, size: size, baseline: baseline, font: .unknown, color: .black,
                                run: glyph + k, isRotated: false)
            char.glyphs = [glyph + k]
            char.isMath = math
            return char
        }
    }

    @Test func aNumeratorNearerTheLineAboveGoesBackToItsFormula() {
        // "where F ∈ R^{H/2 …} and so on": H is drawn between R and 2, but sits nearer the line above.
        let above = LayoutAnalyzer.makeLine(chars("an input image X of the encoder", x: 0, baseline: 205, glyph: 0))!
        let line = LayoutAnalyzer.makeLine(chars("where F R", x: 0, baseline: 192, glyph: 100, math: true)
            + chars("2i+1 W C and more words follow", x: 40, baseline: 193, glyph: 110, math: true))!
        let numerator = LayoutAnalyzer.makeLine(chars("H", x: 38, baseline: 199.9, size: 5, glyph: 109, math: true))!
        let result = LayoutAnalyzer.reuniteByDrawingOrder([above, line, numerator])
        #expect(result.count == 2)
        #expect(result.contains { $0.text.contains("H") && $0.text.contains("where") })
        #expect(!result.contains { $0.text.contains("H") && $0.text.contains("encoder") })
    }

    @Test func linesDrawnOneAfterAnotherStayApart() {
        let first = LayoutAnalyzer.makeLine(chars("first line of text", x: 0, baseline: 200, glyph: 0))!
        let second = LayoutAnalyzer.makeLine(chars("x2", x: 10, baseline: 190, glyph: 20, math: true))!
        let third = LayoutAnalyzer.makeLine(chars("third line of text", x: 0, baseline: 180, glyph: 40))!
        #expect(LayoutAnalyzer.reuniteByDrawingOrder([first, second, third]).count == 3)
    }

    @Test func aListRowWithAWideGapIsOneLine() {
        let above = LayoutAnalyzer.makeLine(chars("A in R mxr,      uniformly initialized,", x: 100, baseline: 598, glyph: 0))!
        let left = LayoutAnalyzer.makeLine(chars("B in R,", x: 100, baseline: 587, glyph: 100))!
        let right = LayoutAnalyzer.makeLine(chars("uniformly initialized,", x: 164, baseline: 587, glyph: 200))!
        let below = LayoutAnalyzer.makeLine(chars("W in R cxc,      uniformly initialized,", x: 100, baseline: 576, glyph: 300))!
        let result = LayoutAnalyzer.joinAcrossInnerGaps([above, left, right, below], inTable: { _ in false })
        #expect(result.count == 3)
        #expect(result.contains { $0.text.hasPrefix("B in R,") && $0.text.hasSuffix("initialized,") })
    }
}

@Suite struct DuplicateTranslationTests {
    @Test func theSameMinuteTwiceGetsSeconds() {
        let provider = TranslationNaming.Provider(name: "agy", model: "m")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let first = TranslationNaming.baseName(original: "P", kind: .mono, language: "简体中文", provider: provider, existing: [], date: date)
        let second = TranslationNaming.baseName(original: "P", kind: .mono, language: "简体中文", provider: provider, existing: [first], date: date)
        let third = TranslationNaming.baseName(original: "P", kind: .mono, language: "简体中文", provider: provider, existing: [first, second], date: date)
        #expect(Set([first, second, third]).count == 3)
    }

    @Test func optionsSavedBeforeTheChoiceKeepBoth() throws {
        let options = try JSONDecoder().decode(TranslationOptions.self, from: Data(#"{"langIn":"en","langOut":"zh"}"#.utf8))
        #expect(options.duplicates == .keepBoth)
        var replace = TranslationOptions()
        replace.duplicates = .replace
        let back = try JSONDecoder().decode(TranslationOptions.self, from: JSONEncoder().encode(replace))
        #expect(back.duplicates == .replace)
    }
}
