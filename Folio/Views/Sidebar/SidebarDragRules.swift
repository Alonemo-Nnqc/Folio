import FolioCore
import Foundation

/// What is being dragged over the sidebar.
enum SidebarDragSource: Equatable {
    case group(id: String, hasChildren: Bool)
    case items(ids: [String], from: ViewScope)
    case files([URL])
}

/// Where the pointer is, in sidebar terms.
enum SidebarDropTarget: Equatable {
    case builtin(ViewScope)
    case group(id: String, isTopLevel: Bool)
    case tag(String)
    /// Between top-level user groups; `index` counts user groups only.
    case topLevelGap(index: Int)
    /// Between the children of a top-level group.
    case childGap(parentId: String, index: Int)
    case elsewhere
}

enum SidebarDropDecision: Equatable {
    case reject
    case nestGroup(id: String, parentId: String)
    case moveGroup(id: String, parentId: String?, index: Int)
    case addItems(ids: [String], groupId: String)
    case trashItems([String])
    case tagItems(ids: [String], tagId: String)
    case importFiles([URL], groupId: String?)
}

/// Pure drop rules for the sidebar (SIDE-12, DND-02/03).
enum SidebarDragRules {
    static func decide(_ source: SidebarDragSource, _ target: SidebarDropTarget) -> SidebarDropDecision {
        switch (source, target) {
        // Groups: nest onto a top-level group, reorder among siblings, promote into the top level.
        case let (.group(id, hasChildren), .group(targetId, isTopLevel)):
            guard targetId != id, isTopLevel, !hasChildren else { return .reject }
            return .nestGroup(id: id, parentId: targetId)
        case let (.group(id, _), .topLevelGap(index)):
            return .moveGroup(id: id, parentId: nil, index: index)
        case let (.group(id, hasChildren), .childGap(parentId, index)):
            guard !hasChildren, parentId != id else { return .reject }
            return .moveGroup(id: id, parentId: parentId, index: index)
        case (.group, _):
            return .reject

        // Items from the list.
        case let (.items(ids, from), .group(groupId, _)):
            guard from != .group(groupId), from != .trash else { return .reject }
            return .addItems(ids: ids, groupId: groupId)
        case let (.items(ids, from), .builtin(.trash)):
            return from == .trash ? .reject : .trashItems(ids)
        case let (.items(ids, from), .tag(tagId)):
            return from == .trash ? .reject : .tagItems(ids: ids, tagId: tagId)
        case (.items, _):
            return .reject

        // Files from Finder.
        case let (.files(urls), .group(groupId, _)):
            return .importFiles(urls, groupId: groupId)
        case let (.files(urls), .builtin(scope)) where scope == .all || scope == .unfiled:
            return .importFiles(urls, groupId: nil)
        case (.files, _):
            return .reject
        }
    }
}
