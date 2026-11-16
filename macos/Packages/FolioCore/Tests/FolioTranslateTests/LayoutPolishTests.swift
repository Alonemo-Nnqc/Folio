import CoreGraphics
import Foundation
import Testing
@testable import FolioTranslate

/// Layouts that came apart or went askew in papers of the library, each as small as it can be made.
@Suite struct LayoutPolishTests {
    /// Characters of a line set in small capitals: the first letter of each word (and figures) large, the rest small.
    private func smallCapitals(_ text: String, x: Double = 50, baseline: Double, large: Double = 8, small: Double = 6.5) -> [PageChar] {
        var chars: [PageChar] = []
        var at = x
        var startsWord = true
        for c in text {
            let size = c == " " || startsWord || c.isNumber ? large : small
            chars.append(PageChar(text: String(c), rect: CGRect(x: at, y: baseline - size * 0.2, width: size * 0.6, height: size * 1.2),
                                  isSpace: c == " ", isNewline: false, size: size, baseline: baseline, font: .unknown, color: .black,
                                  run: chars.count, isRotated: false))
            at += size * 0.6
            startsWord = c == " "
        }
        return chars
    }

    @Test func linesOfATitleInSmallCapitalsAreOneSize() throws {
        // One capital in ten here, many figures and abbreviations there: the same type all the same.
        let few = try #require(LayoutAnalyzer.makeLine(smallCapitals("ABLATION STUDY ON THE NETWORK STRUCTURE AND THE ESSEN-", baseline: 715)))
        let many = try #require(LayoutAnalyzer.makeLine(smallCapitals("TIAL COMPONENTS OF HRM ON TEST100 AND TEST1200 DATASETS.", baseline: 706)))
        #expect(few.size == 8 && many.size == 8, "\(few.size) and \(many.size)")
        // Text with small letters in two sizes is not small capitals (a line with a formula's scripts in it).
        var mixed = smallCapitals("Where The Value Of The Loss Is Small", baseline: 690)
        for k in mixed.indices where mixed[k].size < 8 { mixed[k].text = mixed[k].text.lowercased() }
        #expect(LayoutAnalyzer.smallCapitalsSize(mixed.filter { !$0.isSpace }) == nil)
    }

    private func line(_ text: String, x: Double, baseline: Double, size: Double = 10, width: Double? = nil) -> LayoutLine {
        let advance = (width ?? Double(text.count) * size * 0.5) / Double(text.count)
        let chars = text.enumerated().map { k, c in
            PageChar(text: String(c), rect: CGRect(x: x + Double(k) * advance, y: baseline - size * 0.2, width: advance, height: size * 1.2),
                     isSpace: c == " ", isNewline: false, size: size, baseline: baseline, font: .unknown, color: .black, run: k, isRotated: false)
        }
        return LayoutAnalyzer.makeLine(chars)!
    }

    @Test func aListItemWhoseLinesHappenToShareAMiddleIsNotCentred() {
        // The second line starts 10 pt in, after the bullet, and ends 10 pt short: its middle is the first line's.
        let item = LayoutBlock(kind: .paragraph, lines: [line("• GOALS uses 100 training, 100 validation and 100 test", x: 59, baseline: 225, width: 241),
                                                         line("images following the original setting in the challenge.", x: 69, baseline: 213, width: 221)], translate: true)
        #expect(!item.isCentered)
        // The same two lines without a bullet: a title's lines, centred.
        let title = LayoutBlock(kind: .caption, lines: [line("Ablation study on the network structure and the essen", x: 59, baseline: 225, width: 241),
                                                        line("tial components of the model on both test sets", x: 69, baseline: 213, width: 221)], translate: true)
        #expect(title.isCentered)
    }

    @Test func theShortLastLineOfACentredTitleBelongsToIt() {
        let above = line("FLOPS ARE COMPUTED ON AN IMAGE SIZE OF 512, AND THE", x: 61, baseline: 697.8, size: 8, width: 227)
        let last = line("BOLD DONATES THE BEST", x: 128, baseline: 688.8, size: 8, width: 90)
        #expect(LayoutAnalyzer.continuesText(last, in: [above, last]))
        // A label of the table under the title, set apart from it and off its middle, does not.
        let label = line("Model", x: 70, baseline: 670, size: 8, width: 24)
        #expect(!LayoutAnalyzer.continuesText(label, in: [above, last, label]))
    }

    @Test func aFormulaInFullWidthLettersIsNotTranslatedIntoItsOwnLanguage() {
        #expect(SegmentBuilder.isInScript(of: "zh", "ｆ（ｘ，ｙ）＝ｅｘｐ（－ｘ２）"))
        #expect(!SegmentBuilder.isInScript(of: "zh", "f(x, y) = exp(-x2) over the image"))
        #expect(!SegmentBuilder.isInScript(of: "zh", "12.5 (3)"), "no letters at all: nothing says it is Chinese")
    }

    @Test func oursIsShortEnoughForItsCell() {
        #expect(StandardCells.translate("Ours", to: "zh") == "本文")
    }
}
