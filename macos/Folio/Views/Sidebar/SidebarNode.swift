import FolioCore
import Foundation

/// A row in the sidebar source list. Instances are cached by kind so NSOutlineView keeps expansion
/// and selection across reloads.
final class SidebarNode: NSObject {
    enum Kind: Hashable {
        /// Section headers (group rows): 文献库, 分组, 标签.
        case libraryHeader, groupsHeader, tagsHeader
        case builtin(ViewScope)
        case group(String)
        case tag(String)
    }

    let kind: Kind
    var children: [SidebarNode] = []

    init(kind: Kind) {
        self.kind = kind
    }

    var scope: ViewScope? {
        switch kind {
        case .builtin(let scope): scope
        case .group(let id): .group(id)
        case .tag(let id): .tag(id)
        case .libraryHeader, .groupsHeader, .tagsHeader: nil
        }
    }

    var groupId: String? {
        if case .group(let id) = kind { id } else { nil }
    }

    var isHeader: Bool {
        switch kind {
        case .libraryHeader, .groupsHeader, .tagsHeader: true
        default: false
        }
    }

    var canSelect: Bool { scope != nil }
}

/// Builds the sidebar tree from a snapshot, reusing node objects:
///
///     文献库    所有文献 · 未分组 · 回收站
///     分组      top-level groups ▸ subgroups
///     标签      tags
final class SidebarTree {
    private var cache: [SidebarNode.Kind: SidebarNode] = [:]
    private(set) var roots: [SidebarNode] = []

    static let builtins: [ViewScope] = [.all, .unfiled, .trash]

    /// Returns true when the structure (not just labels) changed.
    @discardableResult
    func rebuild(from snapshot: LibrarySnapshot) -> Bool {
        let old = signature
        let library = node(.libraryHeader)
        library.children = Self.builtins.map { node(.builtin($0)) }
        let groups = node(.groupsHeader)
        groups.children = snapshot.topLevelGroups.map { id in
            let group = node(.group(id))
            group.children = (snapshot.childGroups[id] ?? []).map { node(.group($0)) }
            return group
        }
        let tags = node(.tagsHeader)
        tags.children = snapshot.tags.map { node(.tag($0.id)) }
        roots = [library, groups, tags]
        return signature != old
    }

    func node(for kind: SidebarNode.Kind) -> SidebarNode? { cache[kind] }

    private func node(_ kind: SidebarNode.Kind) -> SidebarNode {
        if let cached = cache[kind] { return cached }
        let created = SidebarNode(kind: kind)
        cache[kind] = created
        return created
    }

    private var signature: [[SidebarNode.Kind]] {
        roots.flatMap { root in [[root.kind]] + root.children.map { [$0.kind] + $0.children.map(\.kind) } }
    }
}
