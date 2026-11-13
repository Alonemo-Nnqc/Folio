public enum SortColumn: String, Codable, Sendable, CaseIterable {
    case title, authors, year, source, type, dateAdded, dateModified, doi, publisher
    case volume, issue, pages, readStatus, rating, fileCount, citationKey, tags
    /// 期刊分区 and 影响因子 (META-30).
    case journalRank, impactFactor
}

/// `column == nil` means the view's custom (drag-and-drop) order.
public struct SortState: Codable, Sendable, Hashable {
    public var column: SortColumn?
    public var ascending: Bool

    public init(column: SortColumn? = nil, ascending: Bool = true) {
        self.column = column
        self.ascending = ascending
    }

    public static let manual = SortState()
}
