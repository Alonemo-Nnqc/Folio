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
