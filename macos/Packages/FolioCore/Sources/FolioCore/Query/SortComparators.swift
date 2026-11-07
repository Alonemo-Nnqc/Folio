import Foundation

/// Column sorting for the item list. Empty values always sort last, whatever the direction.
enum SortComparators {
    enum Key {
        case text(String?)
        case number(Double?)

        var isEmpty: Bool {
            switch self {
            case .text(let s): (s?.trimmingCharacters(in: .whitespaces) ?? "").isEmpty
            case .number(let n): n == nil
            }
        }
    }

    static func key(_ column: SortColumn, item: Item, snapshot: LibrarySnapshot) -> Key {
        switch column {
        case .title: .text(item.title)
        case .authors: .text(AuthorFormatter.listDisplay(item.authors))
        case .year: .number(item.year.map(Double.init))
        case .source: .text(item.source)
        case .type: .text(item.kind == .standalone ? nil : item.type.displayName)
        case .dateAdded: .number(item.dateAdded.timeIntervalSince1970)
        case .dateModified: .number(item.dateModified.timeIntervalSince1970)
        case .doi: .text(item.doi)
        case .publisher: .text(item.publisher)
        case .volume: .text(item.volume)
        case .issue: .text(item.issue)
        case .pages: .text(item.pages)
        case .readStatus: .number(item.kind == .standalone ? nil : Double(item.readStatus.rawValue))
        case .rating: .number(item.rating > 0 ? Double(item.rating) : nil)
        case .fileCount: .number(Double(snapshot.filesByItem[item.id]?.count ?? 0))
        case .citationKey: .text(item.citationKey)
        case .tags: .text(snapshot.tags(of: item.id).first?.name)
        }
    }

    /// Returns true when `a` should come before `b`.
    static func precedes(_ a: Item, _ b: Item, column: SortColumn, ascending: Bool, snapshot: LibrarySnapshot) -> Bool {
        let ka = key(column, item: a, snapshot: snapshot)
        let kb = key(column, item: b, snapshot: snapshot)
        if ka.isEmpty != kb.isEmpty { return kb.isEmpty }
        if !ka.isEmpty {
            let result = compare(ka, kb)
            if result != .orderedSame { return ascending ? result == .orderedAscending : result == .orderedDescending }
        }
        let tie = a.title.localizedStandardCompare(b.title)
        return tie == .orderedSame ? a.id < b.id : tie == .orderedAscending
    }

    private static func compare(_ a: Key, _ b: Key) -> ComparisonResult {
        switch (a, b) {
        case let (.text(x?), .text(y?)):
            return x.localizedStandardCompare(y)
        case let (.number(x?), .number(y?)):
            return x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
        default:
            return .orderedSame
        }
    }
}
