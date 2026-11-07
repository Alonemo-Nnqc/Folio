import Foundation
import FolioCore

/// Flattens a Zotero collection tree to two levels (spec Task 2C, ZOT-02): first- and
/// second-level collections become groups; a third-level-or-deeper collection is not
/// exported, and its items are attributed to its nearest exported (depth <= 2) ancestor.
enum ZoteroCollectionFlattening {
    struct Result {
        var groups: [PreparedGroup]
        /// Every collection id (at any depth) mapped to the exported group key its items
        /// should be attributed to.
        var exportKeyByCollectionID: [Int64: String]
    }

    static func flatten(_ collections: [RawCollection]) -> Result {
        var byID: [Int64: RawCollection] = [:]
        for c in collections { byID[c.id] = c }

        func depth(of id: Int64) -> Int {
            var current = id
            var depth = 1
            var seen = Set<Int64>()
            while let parent = byID[current]?.parentID, seen.insert(current).inserted {
                depth += 1
                current = parent
            }
            return depth
        }

        func exportAncestor(of id: Int64) -> Int64 {
            var current = id
            var seen = Set<Int64>()
            while depth(of: current) > 2, let parent = byID[current]?.parentID, seen.insert(current).inserted {
                current = parent
            }
            return current
        }

        let exportable = collections.filter { depth(of: $0.id) <= 2 }

        // position = index within siblings, ordered by localized (Finder-style) name compare.
        var positionByID: [Int64: Double] = [:]
        let topLevel = exportable
            .filter { $0.parentID == nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for (index, c) in topLevel.enumerated() { positionByID[c.id] = Double(index) }

        let secondLevelByParent = Dictionary(grouping: exportable.filter { $0.parentID != nil }, by: { $0.parentID! })
        for (_, siblings) in secondLevelByParent {
            let ordered = siblings.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            for (index, c) in ordered.enumerated() { positionByID[c.id] = Double(index) }
        }

        let groups = exportable.map { c in
            PreparedGroup(
                key: c.key,
                name: c.name,
                parentKey: c.parentID.flatMap { byID[$0]?.key },
                position: positionByID[c.id] ?? 0
            )
        }

        var exportKeyByCollectionID: [Int64: String] = [:]
        for c in collections {
            let ancestorID = exportAncestor(of: c.id)
            if let key = byID[ancestorID]?.key { exportKeyByCollectionID[c.id] = key }
        }

        return Result(groups: groups, exportKeyByCollectionID: exportKeyByCollectionID)
    }
}
