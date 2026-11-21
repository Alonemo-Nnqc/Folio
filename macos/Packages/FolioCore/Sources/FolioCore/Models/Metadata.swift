/// Bibliographic fields shared by the retrieval engine, citation formatting and importers.
public struct Metadata: Codable, Sendable, Hashable {
    public var type: ItemType = .journalArticle
    public var title: String
    public var authors: [Author] = []
    public var year: Int?
    /// "YYYY", "YYYY-MM" or "YYYY-MM-DD".
    public var date: String?
    /// Journal, conference, repository (e.g. "arXiv"), publisher for books, university for theses.
    public var source: String?
    public var volume: String?
    public var issue: String?
    public var pages: String?
    public var publisher: String?
    /// Lowercased, without a resolver prefix such as `https://doi.org/`.
    public var doi: String?
    /// "2604.27326" or "hep-th/9901001", without a version suffix.
    public var arxivId: String?
    public var isbn: String?
    public var url: String?
    public var abstract: String?
    /// Where it was published (books, chapters, reports, proceedings) or where the degree-awarding institution is
    /// (theses): CSL `publisher-place`.
    public var place: String?
    /// "2nd", "第3版" (books, chapters).
    public var edition: String?
    /// Editors of the book or proceedings (books, chapters, conference papers).
    public var editors: [Author] = []
    public var translators: [Author] = []
    /// The series a book or report belongs to: CSL `collection-title`.
    public var series: String?
    /// What kind of thesis or report it is ("博士学位论文", "Master's thesis", "Technical report"): CSL `genre`.
    public var genre: String?

    public init(title: String) {
        self.title = title
    }
}
