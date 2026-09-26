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

    public init(title: String) {
        self.title = title
    }
}
