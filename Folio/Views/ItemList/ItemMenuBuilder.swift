import AppKit
import FolioCore

enum ItemMenuCommand: Hashable {
    case open, quickLook, revealInFinder
    case openInReader, openWithPreview, openWithApp(URL), openWithOtherApp
    case translate, cancelTranslation
    case editNote, exportNote
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
    /// Other apps that can open the target file ("打开方式 ▸"), name and bundle URL.
    var openWithApps: [(name: String, url: URL)] = []
    /// Items whose translation is queued or running (TRANS-04).
    var translatingItemIds: Set<String> = []
}

/// Builds the item-list context menu as data (LIST-11/12, FILE-04, META-07/08, TRASH-02/04).
enum ItemMenuBuilder {
    static func entries(for context: ItemMenuContext, snapshot: LibrarySnapshot,
                        groups: [(group: LibraryGroup, depth: Int)]) -> [ItemMenuEntry] {
        if context.scope == .trash {
            return [.action(title: String(localized: "恢复"), symbol: "arrow.uturn.backward", command: .restore),
                    .action(title: String(localized: "彻底删除"), symbol: "trash.slash", command: .purge)]
        }
        if let fileId = context.fileId, let file = snapshot.files[fileId] {
            let isDefault = snapshot.items[file.itemId]?.defaultFileId == fileId
            var entries: [ItemMenuEntry] = [
                .action(title: String(localized: "打开"), symbol: "arrow.up.forward.app", command: .open),
                openWithEntry(isPDF: file.isPDF, apps: context.openWithApps),
                .action(title: String(localized: "快速查看"), symbol: "eye", command: .quickLook),
                .separator,
                .action(title: String(localized: "设为默认打开文件"), symbol: "star", command: .setDefaultFile(fileId),
                        enabled: !isDefault, checked: isDefault),
            ]
            if file.isPDF && file.translationOf == nil {
                entries.append(translateEntry(translating: context.translatingItemIds.contains(file.itemId)))
            }
            entries += [
                .action(title: String(localized: "在 Finder 中显示"), symbol: "folder", command: .revealInFinder),
                .separator,
                .action(title: String(localized: "删除"), symbol: "trash", command: .trashFile),
            ]
            return entries
        }

        let items = context.itemIds.compactMap { snapshot.items[$0] }
        guard !items.isEmpty else { return [] }
        let single = items.count == 1 ? items.first : nil
        let allRegular = items.allSatisfy { $0.kind == .regular }

        var entries: [ItemMenuEntry] = [
            .action(title: String(localized: "打开"), symbol: "arrow.up.forward.app", command: .open),
        ]
        if let single, let file = defaultFile(of: single, snapshot) {
            entries.append(openWithEntry(isPDF: file.isPDF, apps: context.openWithApps))
        }
        entries += [
            .action(title: String(localized: "快速查看"), symbol: "eye", command: .quickLook),
            .separator,
            .submenu(title: String(localized: "添加到"), symbol: "folder.badge.plus",
                     entries: groupEntries(items: items, scope: context.scope, snapshot: snapshot, groups: groups)),
            .submenu(title: String(localized: "标签"), symbol: "tag", entries: tagEntries(items: items, snapshot: snapshot)),
        ]
        if allRegular {
            entries.append(.submenu(title: String(localized: "阅读状态"), symbol: "book", entries: ReadStatus.allCases.map { status in
                .action(title: status.displayName, symbol: nil, command: .setReadStatus(status),
                        checked: items.allSatisfy { $0.readStatus == status })
            }))
            entries.append(.submenu(title: String(localized: "评分"), symbol: "star", entries: (0...5).map { value in
                .action(title: value == 0 ? String(localized: "无评分") : String(repeating: "★", count: value), symbol: nil,
                        command: .setRating(value), checked: items.allSatisfy { $0.rating == value })
            }))
            entries.append(.submenu(title: String(localized: "复制引用"), symbol: "quote.opening", entries: CitationStyleOption.allCases.map {
                .action(title: $0.title, symbol: nil, command: .copyCitation($0))
            }))
        }
        entries.append(.separator)
        if let single {
            entries.append(.action(title: String(localized: "编辑笔记"), symbol: "note.text", command: .editNote))
            if snapshot.notedItems.contains(single.id) {
                entries.append(.action(title: String(localized: "导出笔记…"), symbol: "square.and.arrow.up", command: .exportNote))
            }
            if let file = defaultFile(of: single, snapshot), file.isPDF {
                entries.append(translateEntry(translating: context.translatingItemIds.contains(single.id)))
            }
            entries.append(.separator)
            if single.kind == .regular {
                entries.append(.action(title: String(localized: "添加文件…"), symbol: "paperclip", command: .addFiles))
                entries.append(.action(title: String(localized: "重新检索元数据"), symbol: "arrow.clockwise", command: .retrieve))
            } else {
                entries.append(.action(title: String(localized: "重新检索元数据"), symbol: "arrow.clockwise", command: .retrieve,
                                       enabled: single.metadataState != .pending && isPDF(single, snapshot)))
                entries.append(.action(title: String(localized: "手动匹配…"), symbol: "magnifyingglass", command: .manualMatch))
            }
        }
        entries.append(.action(title: String(localized: "在 Finder 中显示"), symbol: "folder", command: .revealInFinder))
        entries.append(.separator)
        if context.scope.groupId != nil {
            entries.append(.action(title: String(localized: "从当前分组移除"), symbol: "minus.circle", command: .removeFromGroup))
        }
        entries.append(.action(title: String(localized: "删除"), symbol: "trash", command: .trash))
        return entries
    }

    private static func groupEntries(items: [Item], scope: ViewScope, snapshot: LibrarySnapshot,
                                     groups: [(group: LibraryGroup, depth: Int)]) -> [ItemMenuEntry] {
        let candidates = groups.filter { $0.group.id != scope.groupId }
        guard !candidates.isEmpty else {
            return [.action(title: String(localized: "没有其他分组"), symbol: nil, command: .addToGroup(""), enabled: false)]
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
        entries.append(.action(title: String(localized: "新建标签…"), symbol: "plus", command: .newTag))
        return entries
    }

    private static func isPDF(_ item: Item, _ snapshot: LibrarySnapshot) -> Bool {
        snapshot.files(of: item.id).first?.isPDF ?? false
    }

    private static func defaultFile(of item: Item, _ snapshot: LibrarySnapshot) -> FileRecord? {
        item.defaultFileId.flatMap { snapshot.files[$0] } ?? snapshot.files(of: item.id).first
    }

    /// "打开方式 ▸": Folio's reader and Preview for PDFs, then the other apps that open the file (OPEN-04).
    private static func openWithEntry(isPDF: Bool, apps: [(name: String, url: URL)]) -> ItemMenuEntry {
        var children: [ItemMenuEntry] = []
        if isPDF {
            children.append(.action(title: String(localized: "在 Folio 中阅读"), symbol: "book.pages", command: .openInReader))
            children.append(.action(title: String(localized: "预览"), symbol: nil, command: .openWithPreview))
        }
        let others = apps.filter { !(isPDF && $0.url.lastPathComponent == "Preview.app") }
        if !others.isEmpty {
            if !children.isEmpty { children.append(.separator) }
            children += others.map { .action(title: $0.name, symbol: nil, command: .openWithApp($0.url)) }
        }
        children.append(.separator)
        children.append(.action(title: String(localized: "其他应用…"), symbol: nil, command: .openWithOtherApp))
        return .submenu(title: String(localized: "打开方式"), symbol: "arrow.up.right.square", entries: children)
    }

    private static func translateEntry(translating: Bool) -> ItemMenuEntry {
        translating
            ? .action(title: String(localized: "取消翻译"), symbol: "xmark.circle", command: .cancelTranslation)
            : .action(title: String(localized: "翻译全文…"), symbol: "character.book.closed", command: .translate)
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
                if case .openWithApp(let url) = command {
                    let icon = NSWorkspace.shared.icon(forFile: url.path)
                    icon.size = NSSize(width: 16, height: 16)
                    item.image = icon
                }
                if case .addToGroup(let id) = command, let hex = snapshot.groupsById[id]?.colorHex {
                    item.image = .coloredSymbol("folder", NSColor(hex: hex))
                }
                if case .toggleTag(let id) = command, let tag = snapshot.tagsById[id] {
                    item.image = .colorDot(NSColor(hex: tag.colorHex))
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
