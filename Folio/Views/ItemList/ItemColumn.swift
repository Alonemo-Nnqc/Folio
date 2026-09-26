import AppKit
import FolioCore

/// Columns of the item list (LIST-02). Raw values are persisted by NSTableView autosave.
enum ItemColumn: String, CaseIterable {
    case title, source, authors, year, tags, dateAdded, type, dateModified, doi, publisher
    case volume, issue, pages, readStatus, rating, fileCount, citationKey

    var header: String {
        switch self {
        case .title: "标题"
        case .source: "来源"
        case .authors: "作者"
        case .year: "年份"
        case .tags: "标签"
        case .dateAdded: "添加日期"
        case .type: "类型"
        case .dateModified: "修改日期"
        case .doi: "DOI"
        case .publisher: "出版社"
        case .volume: "卷"
        case .issue: "期"
        case .pages: "页码"
        case .readStatus: "阅读状态"
        case .rating: "评分"
        case .fileCount: "文件数"
        case .citationKey: "引用键"
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .title: 380
        case .source, .authors: 170
        case .tags: 170
        case .year, .volume, .issue, .fileCount: 56
        case .readStatus: 64
        case .rating: 78
        case .dateAdded, .dateModified: 96
        case .doi, .citationKey, .publisher: 140
        case .type, .pages: 80
        }
    }

    var visibleByDefault: Bool {
        [.title, .source, .authors, .year, .tags, .dateAdded].contains(self)
    }

    var sortColumn: SortColumn {
        switch self {
        case .title: .title
        case .source: .source
        case .authors: .authors
        case .year: .year
        case .tags: .tags
        case .dateAdded: .dateAdded
        case .type: .type
        case .dateModified: .dateModified
        case .doi: .doi
        case .publisher: .publisher
        case .volume: .volume
        case .issue: .issue
        case .pages: .pages
        case .readStatus: .readStatus
        case .rating: .rating
        case .fileCount: .fileCount
        case .citationKey: .citationKey
        }
    }

    var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter
    }()

    /// Plain-text value for text columns; "—" when empty (LIST-05).
    func text(for item: Item, snapshot: LibrarySnapshot) -> String {
        let value: String? = switch self {
        case .title: item.title
        case .source: item.source
        case .authors: AuthorFormatter.listDisplay(item.authors)
        case .year: item.year.map(String.init)
        case .dateAdded: Self.dateFormatter.string(from: item.dateAdded)
        case .dateModified: Self.dateFormatter.string(from: item.dateModified)
        case .type: item.kind == .standalone ? nil : item.type.displayName
        case .doi: item.doi
        case .publisher: item.publisher
        case .volume: item.volume
        case .issue: item.issue
        case .pages: item.pages
        case .fileCount: String(snapshot.filesByItem[item.id]?.count ?? 0)
        case .citationKey: item.citationKey
        case .readStatus, .rating, .tags: nil
        }
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return "—" }
        return value
    }
}
