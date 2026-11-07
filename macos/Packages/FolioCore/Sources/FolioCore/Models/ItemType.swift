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
