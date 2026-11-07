import FolioCore
import Testing

@testable import FolioCitation

struct BibTeXWriterTests {
    @Test func journalArticleMatchesExactly() {
        let expected = """
            @article{zhang2026,
              author = {Zhang, Tengya and Gao, Feng},
              title = {{UNet} Architecture for Biomedical Image Segmentation},
              journal = {Journal of Medical Imaging},
              year = {2026},
              volume = {12},
              number = {3},
              pages = {100--110},
              doi = {10.1000/j.jmi.2026.001}
            }
            """
        #expect(BibTeXWriter.entry(Fixtures.journalArticle) == expected)
    }

    @Test func conferencePaperMatchesExactly() {
        let expected = """
            @inproceedings{qi2025,
              author = {Qi, Lin},
              title = {Attention Is All You Need for Vision Transformers},
              booktitle = {Proceedings of the International Conference on Machine Learning},
              year = {2025},
              pages = {1--9}
            }
            """
        #expect(BibTeXWriter.entry(Fixtures.conferencePaper) == expected)
    }

    @Test func arxivPreprintMatchesExactly() {
        let expected = """
            @misc{dong2024,
              author = {Dong, Junyu},
              title = {Scaling Laws for Neural Language Models},
              year = {2024},
              eprint = {2401.12345},
              archivePrefix = {arXiv}
            }
            """
        #expect(BibTeXWriter.entry(Fixtures.arxivPreprint) == expected)
    }

    @Test func documentJoinsEntriesWithBlankLineAndTrailingNewline() {
        let doc = BibTeXWriter.document([Fixtures.journalArticle, Fixtures.conferencePaper])
        #expect(doc == BibTeXWriter.entry(Fixtures.journalArticle) + "\n\n" + BibTeXWriter.entry(Fixtures.conferencePaper) + "\n")
    }

    @Test func escapesSpecialCharacters() {
        var m = Metadata(title: "A & B % C $ D # E_F {G} ~H ^I \\J")
        m.type = .webpage
        let entry = CitationEntry(id: "5", citationKey: "esc2026", metadata: m)
        let bibtex = BibTeXWriter.entry(entry)
        let expectedTitle =
            "A \\& B \\% C \\$ D \\# E\\_F \\{G\\} \\textasciitilde{}H \\textasciicircum{}I \\textbackslash{}J"
        #expect(bibtex.contains("title = {\(expectedTitle)}"))
    }

    @Test func protectsCapitalisedAcronymsInTitlesWithBraces() {
        var m = Metadata(title: "UNet and CNN Models for GPU Inference")
        m.type = .report
        let entry = CitationEntry(id: "6", citationKey: "acronym2026", metadata: m)
        let bibtex = BibTeXWriter.entry(entry)
        #expect(bibtex.contains("{UNet}"))
        #expect(bibtex.contains("{CNN}"))
        #expect(bibtex.contains("{GPU}"))
        // Ordinary title-case words are left unprotected.
        #expect(!bibtex.contains("{Models}"))
        #expect(!bibtex.contains("{Inference}"))
    }
}
