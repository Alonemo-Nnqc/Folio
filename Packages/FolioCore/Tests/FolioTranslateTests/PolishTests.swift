import CoreText
import Foundation
import PDFKit
import Testing
@testable import FolioTranslate

@Suite struct PolishTests {
    @Test func standardHeadingsAndCells() {
        #expect(StandardHeadings.translate("Abstract", to: "zh") == "摘要")
        #expect(StandardHeadings.translate("1. Introduction", to: "zh") == "1. 引言")
        #expect(StandardHeadings.translate("4.2 Implementation Details", to: "zh") == "4.2 实现细节")
        #expect(StandardHeadings.translate("V. CONCLUSION", to: "zh") == "V. 结论")
        #expect(StandardHeadings.translate("Our Method in Detail", to: "zh") == nil)
        #expect(StandardHeadings.translate("Abstract", to: "ja") == nil)
        #expect(StandardCells.translate("Mean", to: "zh") == "平均")
        #expect(HeadingNumbers.restoreSpace(source: "4.1. Experimental Setup", translation: "4.1.实验设置") == "4.1. 实验设置")
        #expect(HeadingNumbers.restoreSpace(source: "Results", translation: "结果") == "结果")
    }

    @Test func cellsWorthTranslating() {
        #expect(LayoutAnalyzer.isCellText("Baseline model"))
        #expect(LayoutAnalyzer.isCellText("Ours"))
        #expect(!LayoutAnalyzer.isCellText("AS"))
        #expect(!LayoutAnalyzer.isCellText("EVA02-L [18]"))
        #expect(!LayoutAnalyzer.isCellText("ResNet DINOv2"))
        #expect(!LayoutAnalyzer.isCellText("FAMix 40.50 38.69 36.05"))
    }

    @Test func agentModelOptions() async {
        #expect(AgentModels.value("model", in: "model_provider = \"custom\"\nmodel = \"gpt-6.1-sol\"\n[profiles]\nmodel = \"x\"") == "gpt-6.1-sol")
        #expect(AgentModels.value("model", in: "[a]\nmodel = \"x\"") == nil)
        #expect(await AgentModels.models(for: .claude, executable: nil) == ["haiku", "sonnet", "opus"])
        #expect(ModelListFetcher.supports(serviceID: "claudecode", modelOption: "--claude-code-model"))
        #expect(ModelListFetcher.supports(serviceID: "codex", modelOption: "--codex-model"))
        #expect(!ModelListFetcher.supports(serviceID: "google", modelOption: "--x"))
        let models = try? await ModelListFetcher.fetch(serviceID: "claudecode", fieldValues: [:], secrets: [:])
        #expect(models == ["haiku", "sonnet", "opus"])
        #expect(ModelListFetcher.rememberedModels(serviceID: "claudecode", fieldValues: [:]) == ["haiku", "sonnet", "opus"])
    }

    @Test func chineseLinesJustifyBySpacingCharacters() {
        let font = CTFontCreateWithName("STSongti-SC-Regular" as CFString, 10, nil)
        let text = NSAttributedString(string: "域泛化旨在训练模型 CLIP 表现良好", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let plain = CTLineCreateWithAttributedString(text)
        let natural = CTLineGetTypographicBounds(plain, nil, nil, nil)
        let line = Typesetter.justifiedByKerning(text, range: CFRange(location: 0, length: text.length), extra: 12, fontSize: 10)!
        #expect(abs(CTLineGetTypographicBounds(line, nil, nil, nil) - natural - 12) < 0.6)
        #expect(Typesetter.justifiedByKerning(text, range: CFRange(location: 0, length: text.length), extra: 400, fontSize: 10) == nil,
                "too much to spread: leave the line as it is")
    }

    @Test func citationListsCanBreak() {
        let typesetter = Typesetter(language: "zh")
        let attributed = typesetter.attributedString("网络[7,21,25,26]", fontSize: 10, bold: false, serif: true, italic: false,
                                                     color: .black, formulas: [], scale: 1)
        #expect(attributed.string.contains("7,\u{200B}21,\u{200B}25"))
    }

    @Test func paragraphsOfAPageShareTheirSpacing() {
        func plan(fill: Double, fontSize: Double = 10) -> Typesetter.Plan {
            Typesetter.Plan(lines: [], scale: 1, fontSize: fontSize, firstBaseline: 700, minPitch: 11.4, maxPitch: 18.5, fillPitch: fill, fits: true)
        }
        let block = LayoutBlock(kind: .paragraph, lines: [], translate: true)
        // With lines: Typesetter.Plan.lines is empty here, so give each two lines.
        var plans = [plan(fill: 12), plan(fill: 16), plan(fill: 18.5)]
        let line: (CTLine, Double) = (CTLineCreateWithAttributedString(NSAttributedString(string: "x")), 0)
        for i in plans.indices { plans[i].lines = [line, line] }
        let pitches = TranslationRenderer.harmonizedPitches(plans.map { ($0, block) })
        // Median ratio 1.6: each stays within ±12% of 16.
        #expect(abs(pitches[0] - 14.08) < 0.01)
        #expect(abs(pitches[1] - 16) < 0.01)
        #expect(abs(pitches[2] - 17.92) < 0.01)
    }
}

@Suite struct LenientReplyTests {
    @Test func repliesWithUnescapedQuotesStillParse() {
        let reply = "```json\n{\n  \"1\": \"即使有\"decoder warm-up\"也不行。\",\n  \"2\": \"第二段\"\n}\n```"
        #expect(LLMBatch.parse(reply, count: 2) == ["即使有\"decoder warm-up\"也不行。", "第二段"])
    }
}

@Suite struct PunctuationTests {
    @Test func chineseTextGetsChinesePunctuation() {
        let typesetter = Typesetter(language: "zh")
        func text(_ s: String) -> String {
            typesetter.attributedString(s, fontSize: 10, bold: false, serif: true, italic: false, color: .black, formulas: [], scale: 1)
                .string.replacingOccurrences(of: "\u{200B}", with: "")
        }
        #expect(text("训练线性探针 (LP),(2) 微调") == "训练线性探针 (LP)，(2) 微调")
        #expect(text("因此,他们提出") == "因此，他们提出")
        #expect(text("见[7, 21]和 a, b") == "见[7, 21]和 a, b")
    }
}
