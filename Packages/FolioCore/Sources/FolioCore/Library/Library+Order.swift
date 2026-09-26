import Foundation
import GRDB

extension Library {
    // MARK: Custom order and sorting (LIST-06, DND-04)

    /// Moves `itemIds` to `toIndex` within the order currently shown for `scope`, rewriting the view's
    /// custom order and switching it back to custom-order sorting.
    public func moveItems(_ itemIds: [String], inScope scope: ViewScope, displayedOrder: [String], toIndex: Int) throws {
        let moving = Set(itemIds)
        let clampedIndex = min(max(toIndex, 0), displayedOrder.count)
        let insertAt = displayedOrder[..<clampedIndex].filter { !moving.contains($0) }.count
        var order = displayedOrder.filter { !moving.contains($0) }
        order.insert(contentsOf: displayedOrder.filter { moving.contains($0) }, at: insertAt)
        try writer.write { db in
            try db.execute(sql: "DELETE FROM itemOrder WHERE scope = ?", arguments: [scope.key])
            for (position, id) in order.enumerated() {
                try ItemOrder(scope: scope.key, itemId: id, position: Double(position)).insert(db)
            }
            try ViewSortRecord(scope: scope.key, sortColumn: nil, ascending: true).save(db)
        }
    }

    public func setSort(_ sort: SortState, forScope scope: ViewScope) throws {
        try writer.write { db in
            try ViewSortRecord(scope: scope.key, sortColumn: sort.column, ascending: sort.ascending).save(db)
        }
    }
}
