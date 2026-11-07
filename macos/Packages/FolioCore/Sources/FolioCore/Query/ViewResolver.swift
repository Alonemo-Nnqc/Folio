import Foundation

public struct ViewQuery: Sendable, Hashable {
    public var scope: ViewScope
    public var searchText: String
    /// Search the whole library instead of only the current view (SEARCH-03).
    public var searchWholeLibrary: Bool
    /// Items matched by the PDF full-text index, unioned with metadata matches (SEARCH-04).
    public var fulltextItemIds: Set<String>?
    /// Parent groups also show their subgroups' items (SIDE-10).
    public var includeSubgroupItems: Bool
    public var sort: SortState

    public init(scope: ViewScope, searchText: String = "", searchWholeLibrary: Bool = false,
                fulltextItemIds: Set<String>? = nil, includeSubgroupItems: Bool = true, sort: SortState = .manual) {
        self.scope = scope
        self.searchText = searchText
        self.searchWholeLibrary = searchWholeLibrary
        self.fulltextItemIds = fulltextItemIds
        self.includeSubgroupItems = includeSubgroupItems
        self.sort = sort
    }

    public var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// Computes the ordered top-level rows of a view from a snapshot. Pure and fast.
public enum ViewResolver {
    /// Ids of all items that belong to `scope`, unordered.
    public static func members(of scope: ViewScope, in s: LibrarySnapshot, includeSubgroupItems: Bool) -> [String] {
        switch scope {
        case .all:
            return s.items.values.filter { !$0.isTrashed }.map(\.id)
        case .unfiled:
            return s.items.values.filter { !$0.isTrashed && (s.itemGroups[$0.id]?.isEmpty ?? true) }.map(\.id)
        case .trash:
            return s.items.values.filter(\.isTrashed).map(\.id)
        case .group(let id):
            let groups = includeSubgroupItems ? s.groupAndChildren(id) : [id]
            var ids = Set<String>()
            for g in groups { ids.formUnion(s.groupItems[g] ?? []) }
            return ids.filter { s.items[$0].map { !$0.isTrashed } ?? false }
        case .tag(let id):
            return (s.tagItems[id] ?? []).filter { s.items[$0].map { !$0.isTrashed } ?? false }
        }
    }

    public static func rows(_ q: ViewQuery, in s: LibrarySnapshot) -> [String] {
        let effectiveScope: ViewScope = q.isSearching && q.searchWholeLibrary && q.scope != .trash ? .all : q.scope
        var ids = members(of: effectiveScope, in: s, includeSubgroupItems: q.includeSubgroupItems)
        if q.isSearching {
            let tokens = SearchMatcher.tokens(q.searchText)
            let fulltext = q.fulltextItemIds ?? []
            ids = ids.filter { fulltext.contains($0) || SearchMatcher.matches(tokens: tokens, haystack: s.searchText[$0] ?? "") }
        }
        let items = ids.compactMap { s.items[$0] }
        let sorted: [Item]
        if let column = q.sort.column {
            sorted = items.sorted { SortComparators.precedes($0, $1, column: column, ascending: q.sort.ascending, snapshot: s) }
        } else if effectiveScope == .trash {
            sorted = items.sorted { ($0.trashedAt ?? .distantPast, $0.id) > ($1.trashedAt ?? .distantPast, $1.id) }
        } else {
            let positions = s.orders[effectiveScope.key] ?? [:]
            func position(_ item: Item) -> Double { positions[item.id] ?? -item.dateAdded.timeIntervalSince1970 }
            sorted = items.sorted {
                let (pa, pb) = (position($0), position($1))
                if pa != pb { return pa < pb }
                if $0.dateAdded != $1.dateAdded { return $0.dateAdded > $1.dateAdded }
                return $0.id < $1.id
            }
        }
        return sorted.map(\.id)
    }
}

/// Item counts shown next to each sidebar entry (SIDE-04).
public enum SidebarCounts {
    public static func compute(_ s: LibrarySnapshot, includeSubgroupItems: Bool) -> [ViewScope: Int] {
        var counts: [ViewScope: Int] = [:]
        for scope in [ViewScope.all, .unfiled, .trash] {
            counts[scope] = ViewResolver.members(of: scope, in: s, includeSubgroupItems: includeSubgroupItems).count
        }
        for id in s.groupsById.keys {
            counts[.group(id)] = ViewResolver.members(of: .group(id), in: s, includeSubgroupItems: includeSubgroupItems).count
        }
        for tag in s.tags {
            counts[.tag(tag.id)] = ViewResolver.members(of: .tag(tag.id), in: s, includeSubgroupItems: includeSubgroupItems).count
        }
        return counts
    }
}
