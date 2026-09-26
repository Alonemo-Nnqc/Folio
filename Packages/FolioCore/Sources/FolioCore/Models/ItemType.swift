/// The bibliographic kind of an item. Raw values are persisted, so never rename a case.
public enum ItemType: String, Codable, Sendable, CaseIterable {
    case journalArticle, conferencePaper, preprint, book, bookChapter, thesis, report, webpage, dataset, other

    public var displayName: String {
        switch self {
        case .journalArticle: "期刊文章"
        case .conferencePaper: "会议论文"
        case .preprint: "预印本"
        case .book: "图书"
        case .bookChapter: "图书章节"
        case .thesis: "学位论文"
        case .report: "报告"
        case .webpage: "网页"
        case .dataset: "数据集"
        case .other: "其他"
        }
    }
}
