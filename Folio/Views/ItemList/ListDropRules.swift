import FolioCore

enum ListDropDecision: Equatable {
    /// Rows dragged within this list change the custom order (DND-04).
    case reorder
    /// Files from Finder or another app are imported (DND-01).
    case importFiles
    case reject
}

/// Pure drop rules for the item list.
enum ListDropRules {
    /// - Parameters:
    ///   - hasFolioItems: the drag carries Folio's private item type.
    ///   - fromThisList: the drag started in this list (rows or child-file rows).
    ///   - fileCount: file URLs on the pasteboard.
    static func decide(hasFolioItems: Bool, fromThisList: Bool, fileCount: Int, isSearching: Bool,
                       scope: ViewScope) -> ListDropDecision {
        if fromThisList {
            // Child-file rows only carry a file URL; re-importing them would just report a duplicate.
            return hasFolioItems && !isSearching && scope != .trash ? .reorder : .reject
        }
        if hasFolioItems { return .reject }
        return fileCount > 0 && scope != .trash ? .importFiles : .reject
    }
}
