import FolioCore

@testable import FolioCitation

/// Shared fixture entries used across the BibTeX and citeproc-js tests.
enum Fixtures {
    /// Journal article with volume, issue, pages and a DOI.
    static let journalArticle: CitationEntry = {
        var m = Metadata(title: "UNet Architecture for Biomedical Image Segmentation")
        m.type = .journalArticle
        m.authors = [Author(family: "Zhang", given: "Tengya"), Author(family: "Gao", given: "Feng")]
        m.year = 2026
        m.date = "2026"
        m.source = "Journal of Medical Imaging"
        m.volume = "12"
        m.issue = "3"
        m.pages = "100-110"
        m.doi = "10.1000/j.jmi.2026.001"
        return CitationEntry(id: "1", citationKey: "zhang2026", metadata: m)
    }()

    /// Conference paper with no volume/issue/DOI.
    static let conferencePaper: CitationEntry = {
        var m = Metadata(title: "Attention Is All You Need for Vision Transformers")
        m.type = .conferencePaper
        m.authors = [Author(family: "Qi", given: "Lin")]
        m.year = 2025
        m.date = "2025"
        m.source = "Proceedings of the International Conference on Machine Learning"
        m.pages = "1-9"
        return CitationEntry(id: "2", citationKey: "qi2025", metadata: m)
    }()

    /// arXiv preprint identified only by its arXiv id.
    static let arxivPreprint: CitationEntry = {
        var m = Metadata(title: "Scaling Laws for Neural Language Models")
        m.type = .preprint
        m.authors = [Author(family: "Dong", given: "Junyu")]
        m.year = 2024
        m.date = "2024"
        m.source = "arXiv"
        m.arxivId = "2401.12345"
        return CitationEntry(id: "3", citationKey: "dong2024", metadata: m)
    }()

    /// Four authors (so GB/T 7714's et-al-min="4" kicks in) and no DOI/URL
    /// (so the GB/T medium-id macro renders plain "[J]", not "[J/OL]").
    static let fourAuthorJournalArticle: CitationEntry = {
        var m = Metadata(title: "A Survey of Multimodal Learning Methods")
        m.type = .journalArticle
        m.authors = [
            Author(family: "Zhang", given: "Tengya"),
            Author(family: "Gao", given: "Feng"),
            Author(family: "Qi", given: "Lin"),
            Author(family: "Dong", given: "Junyu"),
        ]
        m.year = 2026
        m.date = "2026"
        m.source = "Journal of Testing"
        return CitationEntry(id: "4", citationKey: "zhang2026a", metadata: m)
    }()
}
