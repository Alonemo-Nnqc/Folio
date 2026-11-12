import FolioCore
import Foundation

/// What is being dragged over the sidebar.
enum SidebarDragSource: Equatable {
    /// `height`: the levels the group and its subgroups span (1 = no subgroups).
    case group(id: String, height: Int)
    case items(ids: [String], from: ViewScope)
    case files([URL])
}

/// Where the pointer is, in sidebar terms.
enum SidebarDropTarget: Equatable {
    case builtin(ViewScope)
    /// On a user group; `ancestors` run from the top level down to its parent (empty at the top level).
    case group(id: String, ancestors: [String])
    case tag(String)
    /// Between top-level user groups; `index` counts user groups only.
    case topLevelGap(index: Int)
    /// Between the subgroups of `parentId`, whose own ancestors are `ancestors`.
    case childGap(parentId: String, ancestors: [String], index: Int)
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

/// Pure drop rules for the sidebar (SIDE-12, SIDE-17, DND-02/03).
enum SidebarDragRules {
    /// Whether a group spanning `height` levels fits under `parentId` (whose ancestors are `ancestors`): never inside
    /// itself or its own subgroups, and no deeper than `LibraryGroup.maximumDepth` levels with its subgroups.
    static func fits(_ id: String, height: Int, under parentId: String, ancestors: [String]) -> Bool {
        parentId != id && !ancestors.contains(id) && ancestors.count + 1 + height <= LibraryGroup.maximumDepth
    }

    static func decide(_ source: SidebarDragSource, _ target: SidebarDropTarget) -> SidebarDropDecision {
        switch (source, target) {
        // Groups: nest onto a group, reorder among siblings, move to another level (four levels at most).
        case let (.group(id, height), .group(targetId, ancestors)):
            guard fits(id, height: height, under: targetId, ancestors: ancestors) else { return .reject }
            return .nestGroup(id: id, parentId: targetId)
        case let (.group(id, _), .topLevelGap(index)):
            return .moveGroup(id: id, parentId: nil, index: index)
        case let (.group(id, height), .childGap(parentId, ancestors, index)):
            guard fits(id, height: height, under: parentId, ancestors: ancestors) else { return .reject }
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
