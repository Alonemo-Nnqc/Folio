import FolioCore
import Foundation

/// A row in the sidebar outline. Instances are cached by key so NSOutlineView keeps
/// expansion and selection across reloads.
final class SidebarNode: NSObject {
    enum Kind: Hashable {
        case builtin(ViewScope)
        case divider
        case group(String)
        case tagsHeader
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
        case .divider, .tagsHeader: nil
        }
    }

    var groupId: String? {
        if case .group(let id) = kind { id } else { nil }
    }

    var canSelect: Bool { scope != nil }
}

/// Builds the sidebar tree from a snapshot, reusing node objects.
final class SidebarTree {
    private var cache: [SidebarNode.Kind: SidebarNode] = [:]
    private(set) var roots: [SidebarNode] = []

    static let builtins: [ViewScope] = [.all, .unfiled, .trash]

    /// Returns true when the structure (not just labels) changed.
    @discardableResult
    func rebuild(from snapshot: LibrarySnapshot) -> Bool {
        let old = signature
        var roots = Self.builtins.map { node(.builtin($0)) }
        roots.append(node(.divider))
        for id in snapshot.topLevelGroups {
            let group = node(.group(id))
            group.children = (snapshot.childGroups[id] ?? []).map { node(.group($0)) }
            roots.append(group)
        }
        let header = node(.tagsHeader)
        header.children = snapshot.tags.map { node(.tag($0.id)) }
        roots.append(header)
        self.roots = roots
        return signature != old
    }

    func node(for kind: SidebarNode.Kind) -> SidebarNode? { cache[kind] }

    /// Index in `roots` of the first user group slot (right after the divider).
    var firstGroupIndex: Int { Self.builtins.count + 1 }

    /// Index in `roots` just past the last top-level group.
    var groupsEndIndex: Int {
        roots.firstIndex { if case .tagsHeader = $0.kind { true } else { false } } ?? roots.count
    }

    private func node(_ kind: SidebarNode.Kind) -> SidebarNode {
        if let cached = cache[kind] { return cached }
        let created = SidebarNode(kind: kind)
        cache[kind] = created
        return created
    }

    private var signature: [SidebarNode.Kind] {
        roots.flatMap { [$0.kind] + $0.children.map(\.kind) + [.divider] }
    }
}
