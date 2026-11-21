/// The bibliographic kind of an item. Raw values are persisted, so never rename a case.
public enum ItemType: String, Codable, Sendable, CaseIterable {
    case journalArticle, conferencePaper, preprint, book, bookChapter, thesis, report, webpage, dataset, other

    public var displayName: String {
        switch self {
        case .journalArticle: String(localized: "期刊文章", bundle: .module)
        case .conferencePaper: String(localized: "会议论文", bundle: .module)
        case .preprint: String(localized: "预印本", bundle: .module)
        case .book: String(localized: "图书", bundle: .module)
        case .bookChapter: String(localized: "图书章节", bundle: .module)
        case .thesis: String(localized: "学位论文", bundle: .module)
        case .report: String(localized: "报告", bundle: .module)
        case .webpage: String(localized: "网页", bundle: .module)
        case .dataset: String(localized: "数据集", bundle: .module)
        case .other: String(localized: "其他", bundle: .module)
        }
    }
}

/// The bibliographic fields of an item that mean different things, or matter only, for some types (#19).
public enum ItemField: String, Sendable, CaseIterable {
    case source, volume, issue, pages, publisher, place, edition, editors, translators, series, genre, doi, arxivId, isbn, url

    /// What the field is called for an item of `type`: `source` is a journal, proceedings, the book a chapter is in, the
    /// university of a thesis…
    public func label(for type: ItemType) -> String {
        switch self {
        case .source:
            switch type {
            case .journalArticle: String(localized: "期刊", bundle: .module)
            case .conferencePaper: String(localized: "会议/论文集", bundle: .module)
            case .preprint, .dataset: String(localized: "平台", bundle: .module)
            case .bookChapter: String(localized: "所属图书", bundle: .module)
            case .thesis: String(localized: "授予单位", bundle: .module)
            case .report: String(localized: "机构", bundle: .module)
            case .webpage: String(localized: "网站", bundle: .module)
            case .book, .other: String(localized: "来源", bundle: .module)
            }
        case .volume: String(localized: "卷", bundle: .module)
        case .issue: type == .report ? String(localized: "编号", bundle: .module) : String(localized: "期", bundle: .module)
        case .pages: String(localized: "页码", bundle: .module)
        case .publisher: String(localized: "出版社", bundle: .module)
        case .place:
            switch type {
            case .thesis, .report: String(localized: "所在地", bundle: .module)
            case .conferencePaper: String(localized: "会议地点", bundle: .module)
            default: String(localized: "出版地", bundle: .module)
            }
        case .edition: String(localized: "版次", bundle: .module)
        case .editors: String(localized: "编者", bundle: .module)
        case .translators: String(localized: "译者", bundle: .module)
        case .series: String(localized: "丛书", bundle: .module)
        case .genre: type == .thesis ? String(localized: "学位类型", bundle: .module) : String(localized: "类型", bundle: .module)
        case .doi: "DOI"
        case .arxivId: "arXiv"
        case .isbn: "ISBN"
        case .url: "URL"
        }
    }

    /// The fields an item of `type` is usually described with, in the order the inspector shows them. Fields with a value
    /// are shown whatever the type (changing the type never hides what was entered).
    public static func fields(for type: ItemType) -> [ItemField] {
        switch type {
        case .journalArticle: [.source, .volume, .issue, .pages, .doi, .url]
        case .conferencePaper: [.source, .editors, .place, .publisher, .volume, .pages, .doi, .url]
        case .preprint: [.source, .arxivId, .doi, .url]
        case .book: [.publisher, .place, .edition, .editors, .translators, .series, .isbn, .doi, .url]
        case .bookChapter: [.source, .editors, .translators, .publisher, .place, .edition, .series, .pages, .isbn, .doi, .url]
        case .thesis: [.source, .place, .genre, .doi, .url]
        case .report: [.source, .place, .genre, .issue, .series, .doi, .url]
        case .webpage: [.source, .url]
        case .dataset: [.source, .publisher, .doi, .url]
        case .other: [.source, .volume, .issue, .pages, .publisher, .doi, .url]
        }
    }

    /// The fields the inspector shows for `metadata`: its type's, then any other that has a value.
    public static func shown(for metadata: Metadata) -> [ItemField] {
        let own = fields(for: metadata.type)
        return own + allCases.filter { !own.contains($0) && $0.hasValue(in: metadata) }
    }

    public func hasValue(in m: Metadata) -> Bool {
        switch self {
        case .editors: !m.editors.isEmpty
        case .translators: !m.translators.isEmpty
        default: !(text(in: m) ?? "").isEmpty
        }
    }

    /// The field's text (people as "Family, Given; …").
    public func text(in m: Metadata) -> String? {
        switch self {
        case .source: m.source
        case .volume: m.volume
        case .issue: m.issue
        case .pages: m.pages
        case .publisher: m.publisher
        case .place: m.place
        case .edition: m.edition
        case .editors: m.editors.isEmpty ? nil : AuthorFormatter.joined(m.editors)
        case .translators: m.translators.isEmpty ? nil : AuthorFormatter.joined(m.translators)
        case .series: m.series
        case .genre: m.genre
        case .doi: m.doi
        case .arxivId: m.arxivId
        case .isbn: m.isbn
        case .url: m.url
        }
    }

    /// Sets the field from text typed by hand; empty clears it.
    public func set(_ text: String, in m: inout Metadata) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let v: String? = value.isEmpty ? nil : value
        switch self {
        case .source: m.source = v
        case .volume: m.volume = v
        case .issue: m.issue = v
        case .pages: m.pages = v
        case .publisher: m.publisher = v
        case .place: m.place = v
        case .edition: m.edition = v
        case .editors: m.editors = AuthorFormatter.people(value)
        case .translators: m.translators = AuthorFormatter.people(value)
        case .series: m.series = v
        case .genre: m.genre = v
        case .doi: m.doi = v?.lowercased()
        case .arxivId: m.arxivId = v
        case .isbn: m.isbn = v
        case .url: m.url = v
        }
    }
}
