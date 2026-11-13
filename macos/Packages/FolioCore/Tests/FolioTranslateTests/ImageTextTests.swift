import CoreGraphics
import Testing
@testable import FolioTranslate

/// TRANS-40: which words read from a picture are translated.
@Suite struct ImageTextTests {
    @Test(arguments: [("Performance Drop", true), ("Encoder", true), ("GT", false), ("CNN", false), ("0.85", false), ("x", false), ("Fig 3a", true)])
    func wordsWorthTranslating(_ text: String, _ expected: Bool) {
        #expect(ImageText.isWords(text) == expected)
    }

    @Test func recognitionLanguagesReadLatinToo() {
        #expect(ImageText.recognitionLanguages(for: "zh").contains("en-US"))
        #expect(ImageText.recognitionLanguages(for: "en") == ["en-US"])
    }
}

/// TRANS-40: reading figure labels well, and setting their translations back.
@Suite struct ImageTextReadingTests {
    @Test(arguments: [("Specialist model trained", true), ("for artery segmentation", true), ("ResNet50 on 3D data", true),
                      ("0 ery! gmen相伊7", false), ("Пу Embedding", false), ("l1ne c0d3", false)])
    func misreadingsAreLeftOut(_ text: String, _ expected: Bool) {
        #expect(ImageText.isReadable(text) == expected)
    }

    @Test func markersAreNotLetters() {
        for c in "→✓✗•*>" { #expect(ImageText.isMarker(c)) }
        for c in "a(+%°-" { #expect(!ImageText.isMarker(c)) }
    }

    @Test func sizesOfOneKindBecomeOne() {
        let sizes = ImageText.harmonized([6.1, 6.4, nil, 6.6, 8.6, 8.9, 3.0])
        #expect(sizes[0] == sizes[1] && sizes[1] == sizes[3])
        #expect(sizes[4] == sizes[5] && sizes[4] != sizes[0])
        #expect(sizes[2] == nil && sizes[6] == 3.0)
    }

    @Test func centredAndLowerCaseLinesAreOneLabel() {
        func line(_ text: String, _ y: Double, group: Int, _ alignment: ImageText.Alignment) -> ImageText.Line {
            var l = ImageText.Line(page: 1, rect: CGRect(x: 10, y: y, width: 60, height: 6), text: text, color: RGBColor(r: 0, g: 0, b: 0), patch: nil, patchRect: .null)
            l.group = group
            l.alignment = alignment
            return l
        }
        let units = ImageTextUnits.units([
            line("Specialist model trained", 100, group: 1, .left), line("for artery segmentation", 92, group: 1, .left),
            line("Domain/Task transfer", 60, group: 2, .left), line("Continuous segmentation", 52, group: 2, .left),
            line("Prompt Class", 30, group: 3, .center), line("Flag Embedding", 22, group: 3, .center),
        ])
        #expect(units.map(\.text) == ["Specialist model trained for artery segmentation", "Domain/Task transfer", "Continuous segmentation",
                                      "Prompt Class Flag Embedding"])
    }

    @Test func translationsShareOutAtWordBreaks() {
        let pieces = ImageTextUnits.split("为动脉分割训练的专用模型", weights: [1, 1], cjk: true, language: "zh")
        #expect(pieces.joined() == "为动脉分割训练的专用模型")
        #expect(!pieces[0].hasSuffix("训") && pieces.count == 2)
        #expect(ImageTextUnits.split("trained on the HRF set", weights: [1, 1], cjk: false) == ["trained on", "the HRF set"])
    }
}
