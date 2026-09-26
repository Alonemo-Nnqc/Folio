import Foundation
import Testing
@testable import FolioCore

@Suite struct AuthorFormatterTests {
    @Test func formatsByAuthorCount() {
        let zhang = Author(family: "Zhang", given: "Tengya")
        let gao = Author(family: "Gao", given: "Feng")
        let qi = Author(family: "Qi", given: "Lin")
        #expect(AuthorFormatter.listDisplay([]) == "")
        #expect(AuthorFormatter.listDisplay([zhang]) == "Zhang, Tengya")
        #expect(AuthorFormatter.listDisplay([zhang, gao]) == "Zhang, Tengya & Gao, Feng")
        #expect(AuthorFormatter.listDisplay([zhang, gao, qi]) == "Zhang, Tengya et al.")
    }

    @Test func organisationUsesFamilyOnly() {
        #expect(AuthorFormatter.full(Author(family: "OpenAI")) == "OpenAI")
    }
}

@Suite struct TitleNormalizerTests {
    @Test func normalizesCasePunctuationAndDiacritics() {
        #expect(TitleNormalizer.normalize("  UNet++: A Nested U-Net   Architecture ") == "unet a nested u net architecture")
        #expect(TitleNormalizer.normalize("Café Über") == "cafe uber")
    }

    @Test func similarTitlesScoreHigh() {
        let a = "UNet++: A Nested U-Net Architecture for Medical Image Segmentation"
        let b = "UNet++: a nested U-net architecture for medical image segmentation."
        #expect(TitleNormalizer.similarity(a, b) >= 0.95)
    }

    @Test func differentTitlesScoreLow() {
        let a = "UNet++: A Nested U-Net Architecture for Medical Image Segmentation"
        let b = "Attention Is All You Need"
        #expect(TitleNormalizer.similarity(a, b) < 0.6)
    }
}

@Suite struct DuplicateMatcherTests {
    @Test func sameDOIMatches() {
        var a = Metadata(title: "A")
        a.doi = "10.1/ABC"
        var b = Metadata(title: "Totally different")
        b.doi = "10.1/abc"
        #expect(DuplicateMatcher.isSameWork(a, b))
    }

    @Test func differentDOIsNeverMatch() {
        var a = Metadata(title: "Same Title")
        a.doi = "10.1/a"
        var b = Metadata(title: "Same Title")
        b.doi = "10.1/b"
        #expect(!DuplicateMatcher.isSameWork(a, b))
    }

    @Test func titleYearAndFirstAuthorMatchWithoutDOI() {
        var a = Metadata(title: "Deep Learning")
        a.year = 2015
        a.authors = [Author(family: "LeCun", given: "Yann")]
        var b = Metadata(title: "deep learning.")
        b.year = 2015
        b.authors = [Author(family: "lecun", given: "Y.")]
        #expect(DuplicateMatcher.isSameWork(a, b))
        b.year = 2016
        #expect(!DuplicateMatcher.isSameWork(a, b))
    }

    @Test func arxivIdMatches() {
        var a = Metadata(title: "X")
        a.arxivId = "1807.10165"
        var b = Metadata(title: "Y")
        b.arxivId = "1807.10165"
        #expect(DuplicateMatcher.isSameWork(a, b))
    }
}

@Suite struct CitationKeyGeneratorTests {
    @Test func usesFirstAuthorFamilyAndYear() {
        var m = Metadata(title: "Spectral Dynamic Attention")
        m.authors = [Author(family: "Zhang", given: "Tengya")]
        m.year = 2026
        #expect(CitationKeyGenerator.baseKey(for: m) == "zhang2026")
    }

    @Test func stripsDiacriticsAndSymbols() {
        var m = Metadata(title: "X")
        m.authors = [Author(family: "Müller-Lüdenscheidt", given: "A")]
        m.year = 1999
        #expect(CitationKeyGenerator.baseKey(for: m) == "mullerludenscheidt1999")
    }

    @Test func fallsBackToTitleWord() {
        var m = Metadata(title: "The Attention mechanism")
        m.year = 2017
        #expect(CitationKeyGenerator.baseKey(for: m) == "attention2017")
    }

    @Test func appendsLetterSuffixOnCollision() {
        #expect(CitationKeyGenerator.uniqueKey(base: "zhang2026", existing: []) == "zhang2026")
        #expect(CitationKeyGenerator.uniqueKey(base: "zhang2026", existing: ["zhang2026"]) == "zhang2026a")
        #expect(CitationKeyGenerator.uniqueKey(base: "zhang2026", existing: ["zhang2026", "zhang2026a"]) == "zhang2026b")
    }
}

@Suite struct FileNamerTests {
    @Test func buildsAuthorYearTitle() {
        var m = Metadata(title: "Spectral Dynamic Attention Network")
        m.authors = [Author(family: "Zhang", given: "Tengya")]
        m.year = 2026
        #expect(FileNamer.baseName(for: m) == "Zhang_2026_Spectral Dynamic Attention Network")
    }

    @Test func sanitizesIllegalCharacters() {
        var m = Metadata(title: "UNet++: A/B Test? \"Yes\" <no>")
        m.year = 2018
        #expect(FileNamer.baseName(for: m) == "2018_UNet++ - A-B Test Yes no")
    }

    @Test func truncatesLongTitlesAtWordBoundary() {
        let words = Array(repeating: "segmentation", count: 12).joined(separator: " ")
        var m = Metadata(title: words)
        m.authors = [Author(family: "Li")]
        let name = FileNamer.baseName(for: m)
        let titlePart = name.dropFirst("Li_".count)
        #expect(titlePart.count <= 80)
        #expect(titlePart.hasSuffix("segmentation"))
    }

    @Test func emptyTitleFallsBack() {
        #expect(FileNamer.baseName(for: Metadata(title: "  ")) == "Untitled")
    }
}

@Suite struct FileHasherTests {
    @Test func hashesFileContents() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "folio-hash-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try FileHasher.sha256(of: url) == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }
}
