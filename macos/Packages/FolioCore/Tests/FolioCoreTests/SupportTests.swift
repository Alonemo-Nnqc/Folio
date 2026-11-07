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

    @Test func translationNotes() {
        #expect(FileNamer.translationSuffix(kind: .dual, translatedBy: "Google") == " (bilingual · Google)")
        #expect(FileNamer.translationSuffix(kind: .mono, translatedBy: "SiliconFlow · Qwen/Qwen3-8B") == " (translation · SiliconFlow · Qwen-Qwen3-8B)")
        #expect(FileNamer.translationSuffix(kind: .mono, translatedBy: nil) == " (translation)")
        let folio = "Zhang_2026_Paper（简体中文译文 · DeepSeek · deepseek-chat）"
        #expect(FileNamer.translationSuffix(inName: folio) == "（简体中文译文 · DeepSeek · deepseek-chat）")
        #expect(FileNamer.translatedBy(inName: folio) == "DeepSeek · deepseek-chat")
        #expect(FileNamer.translatedBy(inName: "Paper (Bilingual · Google)") == "Google")
        #expect(FileNamer.translatedBy(inName: "Zhang_2026_UNet (v2)") == nil)
    }
}

@Suite struct FileLabelTests {
    private func file(_ name: String, kind: TranslationKind? = nil, of source: String? = nil, by: String? = nil) -> FileRecord {
        var file = FileRecord(id: name, itemId: "i", relativePath: "Files/\(name)", originalName: name, size: 0, sha256: name, modifiedAt: Date())
        file.translationKind = kind
        file.translationOf = source
        file.translatedBy = by
        return file
    }

    @Test func originalTranslationsAndOtherFiles() {
        let paper = file("Zhang_2026_Paper.pdf")
        let supplement = file("Supplement.pdf")
        let mono = file("Zhang_2026_Paper（译文）.pdf", kind: .mono, of: paper.id, by: "DeepSeek · deepseek-chat")
        let unnamed = file("Zhang_2026_Paper（双语对照）.pdf", kind: .dual)
        let files = [paper, supplement, mono, unnamed]
        #expect(files.map { FileLabel.title(of: $0, among: files, defaultFileId: paper.id) }
                == ["Original", "Supplement.pdf", "Translation · DeepSeek · deepseek-chat", "Bilingual"])
        // A paper's only PDF is its original, default or not; other kinds of file keep their names.
        let notes = file("Notes.txt")
        #expect(FileLabel.title(of: paper, among: [paper, notes], defaultFileId: notes.id) == "Original")
        #expect(FileLabel.title(of: notes, among: [paper, notes], defaultFileId: notes.id) == "Notes.txt")
    }
}

extension FileLabelTests {
    @Test func translationsAlikeAreToldApartByTime() {
        let paper = FileRecord(id: "p", itemId: "i", relativePath: "Files/p.pdf", originalName: "p.pdf", size: 0, sha256: "p", modifiedAt: Date())
        func translation(_ id: String, minutes: Double) -> FileRecord {
            var file = FileRecord(id: id, itemId: "i", relativePath: "Files/\(id).pdf", originalName: "\(id).pdf", size: 0, sha256: id,
                                  modifiedAt: Date(), dateAdded: Date(timeIntervalSince1970: 1_800_000_000 + minutes * 60))
            file.translationKind = .dual
            file.translationOf = paper.id
            file.translatedBy = "Antigravity CLI · gemini-3.8-flash-low"
            return file
        }
        let first = translation("a", minutes: 0), second = translation("b", minutes: 90)
        let files = [paper, first, second]
        let labels = [first, second].map { FileLabel.title(of: $0, among: files, defaultFileId: paper.id) }
        #expect(labels[0] != labels[1])
        #expect(labels.allSatisfy { $0.hasPrefix("Bilingual · Antigravity CLI · gemini-3.8-flash-low · ") })
        // Alone, no time.
        #expect(FileLabel.title(of: first, among: [paper, first], defaultFileId: paper.id) == "Bilingual · Antigravity CLI · gemini-3.8-flash-low")
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

extension FileLabelTests {
    private func tabFile(_ id: String, kind: TranslationKind? = nil, by: String? = nil, of source: String? = nil) -> FileRecord {
        var file = FileRecord(id: id, itemId: "i", relativePath: "Files/\(id).pdf", originalName: "\(id).pdf", size: 0, sha256: id, modifiedAt: Date())
        file.translationKind = kind
        file.translatedBy = by
        file.translationOf = source
        return file
    }

    private func paper(_ title: String, kind: ItemKind = .regular, defaultFile: String = "p") -> Item {
        var item = Item(id: "i", kind: kind, title: title)
        item.defaultFileId = defaultFile
        return item
    }

    @Test func shortTitlesStopAtTheSubtitle() {
        #expect(FileLabel.shortTitle("SnakeSAM: A topology-preserving foundation model") == "SnakeSAM")
        #expect(FileLabel.shortTitle("视网膜分割：一种新方法") == "视网膜分割")
        #expect(FileLabel.shortTitle(" Attention Is All You Need ") == "Attention Is All You Need")
        // Not a subtitle: a time or a ratio, nothing after the colon, or a name too long or too short to stand for the paper.
        #expect(FileLabel.shortTitle("Sleeping at 10:30 in Teens") == "Sleeping at 10:30 in Teens")
        #expect(FileLabel.shortTitle("Trailing:") == "Trailing:")
        #expect(FileLabel.shortTitle("X: a study") == "X: a study")
        let long = String(repeating: "a", count: 41) + ": rest"
        #expect(FileLabel.shortTitle(long) == long)
    }

    @Test func tabsTellPapersAndTranslationsApart() {
        let item = paper("SnakeSAM: A topology-preserving model")
        let original = tabFile("p")
        let mono = tabFile("m", kind: .mono, by: "Google", of: "p")
        let dual = tabFile("d", kind: .dual, by: "Google", of: "p")
        let files = [original, mono, dual]
        #expect(FileLabel.tabTitle(of: original, item: item, among: files) == "SnakeSAM")
        // The kind comes first, so a narrow tab still shows it.
        #expect(FileLabel.tabTitle(of: mono, item: item, among: files) == "Translation · SnakeSAM")
        #expect(FileLabel.tabTitle(of: dual, item: item, among: files) == "Bilingual · SnakeSAM")
        // Several of a kind: the service tells them apart.
        let other = tabFile("o", kind: .mono, by: "DeepSeek", of: "p")
        #expect(FileLabel.tabTitle(of: mono, item: item, among: files + [other]) == "Translation · Google · SnakeSAM")
        #expect(FileLabel.tabTitle(of: other, item: item, among: files + [other]) == "Translation · DeepSeek · SnakeSAM")
        // Within one service, the model; the same service and model, the time, and nothing that is the same for all.
        let low = tabFile("l", kind: .dual, by: "Agent · low", of: "p"), high = tabFile("h", kind: .dual, by: "Agent · high", of: "p")
        #expect(FileLabel.tabTitle(of: low, item: item, among: [original, low, high]) == "Bilingual · low · SnakeSAM")
        var later = tabFile("t", kind: .dual, by: "Agent · low", of: "p")
        later.dateAdded = low.dateAdded.addingTimeInterval(3 * 3600)
        let timed = FileLabel.tabTitle(of: later, item: item, among: [original, low, later])
        #expect(timed.hasPrefix("Bilingual · ") && timed.hasSuffix(" · SnakeSAM") && !timed.contains("Agent") && !timed.contains("low"))
        #expect(timed != FileLabel.tabTitle(of: low, item: item, among: [original, low, later]))
        // Another file of the paper keeps its own name.
        let supplement = tabFile("Supplement")
        #expect(FileLabel.tabTitle(of: supplement, item: item, among: files + [supplement]) == "Supplement")
    }

    @Test func tabsOfLooseFilesUseTheirNames() {
        let item = paper("scan.pdf", kind: .standalone, defaultFile: "scan")
        let scan = tabFile("scan")
        let translated = tabFile("scan（译文）", kind: .mono, of: "scan")
        #expect(FileLabel.tabTitle(of: scan, item: item, among: [scan, translated]) == "scan")
        #expect(FileLabel.tabTitle(of: translated, item: item, among: [scan, translated]) == "Translation · scan")
        #expect(FileLabel.tabTitle(of: scan, item: nil, among: []) == "scan")
    }

    @Test func tabToolTipsCarryWhatTheTabLeavesOut() {
        var item = paper("SnakeSAM: A topology-preserving model")
        item.authors = [Author(family: "Li", given: "Jingwen")]
        item.year = 2026
        let original = tabFile("p"), mono = tabFile("m", kind: .mono, by: "Google", of: "p")
        #expect(FileLabel.tabToolTip(of: mono, item: item, among: [original, mono])
                == "SnakeSAM: A topology-preserving model\nLi 2026 · Translation · Google")
    }
}
