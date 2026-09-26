import AppKit
import FolioCore

enum ItemMenuCommand: Hashable {
    case open, quickLook, revealInFinder
    case addToGroup(String)
    case toggleTag(String), newTag
    case setReadStatus(ReadStatus), setRating(Int)
    case copyCitation(CitationStyleOption)
    case addFiles, retrieve, manualMatch
    case removeFromGroup, trash
    case restore, purge
    case setDefaultFile(String), trashFile
}

indirect enum ItemMenuEntry: Equatable {
    case action(title: String, symbol: String?, command: ItemMenuCommand, enabled: Bool = true, checked: Bool = false, indent: Int = 0)
    case submenu(title: String, symbol: String?, entries: [ItemMenuEntry])
    case separator

    var title: String? {
        switch self {
        case .action(let title, _, _, _, _, _), .submenu(let title, _, _): title
        case .separator: nil
        }
    }
}

/// What was right-clicked: the rows the menu acts on.
struct ItemMenuContext {
    var scope: ViewScope
    var itemIds: [String]
    /// A single child-file row, when that is what was clicked.
    var fileId: String?
}

/// Builds the item-list context menu as data (LIST-11/12, FILE-04, META-07/08, TRASH-02/04).
enum ItemMenuBuilder {
    static func entries(for context: ItemMenuContext, snapshot: LibrarySnapshot,
                        groups: [(group: LibraryGroup, depth: Int)]) -> [ItemMenuEntry] {
        if context.scope == .trash {
            return [.action(title: "恢复", symbol: "arrow.uturn.backward", command: .restore),
                    .action(title: "彻底删除", symbol: "trash.slash", command: .purge)]
        }
        if let fileId = context.fileId, let file = snapshot.files[fileId] {
            let isDefault = snapshot.items[file.itemId]?.defaultFileId == fileId
            return [
                .action(title: "打开", symbol: "arrow.up.forward.app", command: .open),
                .action(title: "快速查看", symbol: "eye", command: .quickLook),
                .separator,
                .action(title: "设为默认打开文件", symbol: "star", command: .setDefaultFile(fileId),
                        enabled: !isDefault, checked: isDefault),
                .action(title: "在 Finder 中显示", symbol: "folder", command: .revealInFinder),
                .separator,
                .action(title: "删除", symbol: "trash", command: .trashFile),
            ]
        }

        let items = context.itemIds.compactMap { snapshot.items[$0] }
        guard !items.isEmpty else { return [] }
        let single = items.count == 1 ? items.first : nil
        let allRegular = items.allSatisfy { $0.kind == .regular }

        var entries: [ItemMenuEntry] = [
            .action(title: "打开", symbol: "arrow.up.forward.app", command: .open),
            .action(title: "快速查看", symbol: "eye", command: .quickLook),
            .separator,
            .submenu(title: "添加到", symbol: "folder.badge.plus",
                     entries: groupEntries(items: items, scope: context.scope, snapshot: snapshot, groups: groups)),
            .submenu(title: "标签", symbol: "tag", entries: tagEntries(items: items, snapshot: snapshot)),
        ]
        if allRegular {
            entries.append(.submenu(title: "阅读状态", symbol: "book", entries: ReadStatus.allCases.map { status in
                .action(title: status.displayName, symbol: nil, command: .setReadStatus(status),
                        checked: items.allSatisfy { $0.readStatus == status })
            }))
            entries.append(.submenu(title: "评分", symbol: "star", entries: (0...5).map { value in
                .action(title: value == 0 ? "无评分" : String(repeating: "★", count: value), symbol: nil,
                        command: .setRating(value), checked: items.allSatisfy { $0.rating == value })
            }))
            entries.append(.submenu(title: "复制引用", symbol: "quote.opening", entries: CitationStyleOption.allCases.map {
                .action(title: $0.title, symbol: nil, command: .copyCitation($0))
            }))
        }
        entries.append(.separator)
        if let single {
            if single.kind == .regular {
                entries.append(.action(title: "添加文件…", symbol: "paperclip", command: .addFiles))
                entries.append(.action(title: "重新检索元数据", symbol: "arrow.clockwise", command: .retrieve))
            } else {
                entries.append(.action(title: "重新检索元数据", symbol: "arrow.clockwise", command: .retrieve,
                                       enabled: single.metadataState != .pending && isPDF(single, snapshot)))
                entries.append(.action(title: "手动匹配…", symbol: "magnifyingglass", command: .manualMatch))
            }
        }
        entries.append(.action(title: "在 Finder 中显示", symbol: "folder", command: .revealInFinder))
        entries.append(.separator)
        if context.scope.groupId != nil {
            entries.append(.action(title: "从当前分组移除", symbol: "minus.circle", command: .removeFromGroup))
        }
        entries.append(.action(title: "删除", symbol: "trash", command: .trash))
        return entries
    }

    private static func groupEntries(items: [Item], scope: ViewScope, snapshot: LibrarySnapshot,
                                     groups: [(group: LibraryGroup, depth: Int)]) -> [ItemMenuEntry] {
        let candidates = groups.filter { $0.group.id != scope.groupId }
        guard !candidates.isEmpty else {
            return [.action(title: "没有其他分组", symbol: nil, command: .addToGroup(""), enabled: false)]
        }
        return candidates.map { entry in
            let members = snapshot.groupItems[entry.group.id] ?? []
            return .action(title: entry.group.name, symbol: "folder", command: .addToGroup(entry.group.id),
                           checked: items.allSatisfy { members.contains($0.id) }, indent: entry.depth)
        }
    }

    private static func tagEntries(items: [Item], snapshot: LibrarySnapshot) -> [ItemMenuEntry] {
        var entries: [ItemMenuEntry] = snapshot.tags.map { tag in
            .action(title: tag.name, symbol: nil, command: .toggleTag(tag.id),
                    checked: items.allSatisfy { snapshot.itemTags[$0.id]?.contains(tag.id) ?? false })
        }
        if !entries.isEmpty { entries.append(.separator) }
        entries.append(.action(title: "新建标签…", symbol: "plus", command: .newTag))
        return entries
    }

    private static func isPDF(_ item: Item, _ snapshot: LibrarySnapshot) -> Bool {
        snapshot.files(of: item.id).first?.isPDF ?? false
    }

    // MARK: NSMenu conversion

    static func populate(_ menu: NSMenu, with entries: [ItemMenuEntry], snapshot: LibrarySnapshot,
                         perform: @escaping (ItemMenuCommand) -> Void) {
        for entry in entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case let .action(title, symbol, command, enabled, checked, indent):
                let item = NSMenuItem.closure(title) { perform(command) }
                if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
                if case .toggleTag(let id) = command, let tag = snapshot.tagsById[id] {
                    item.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
                        .withSymbolConfiguration(.init(paletteColors: [NSColor(hex: tag.colorHex)]))
                }
                item.isEnabled = enabled
                item.state = checked ? .on : .off
                item.indentationLevel = indent
                menu.addItem(item)
            case let .submenu(title, symbol, children):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
                let submenu = NSMenu(title: title)
                submenu.autoenablesItems = false
                populate(submenu, with: children, snapshot: snapshot, perform: perform)
                item.submenu = submenu
                menu.addItem(item)
            }
        }
    }
}
