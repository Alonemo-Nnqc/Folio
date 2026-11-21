import AppKit
import FolioCore
import SwiftUI

/// The inspector with several papers selected: what they are, the tags they share, and everything that can be done to
/// all of them at once — the same commands as the list's context menu (one source: `ItemMenuBuilder`), as rows.
struct MultiSelectionInspector: View {
    let model: AppModel

    private var itemIds: [String] {
        let selected = model.selectedItemIDs
        return model.rows.filter(selected.contains) + selected.subtracting(model.rows).sorted()
    }

    private var context: ItemMenuContext {
        var context = ItemMenuContext(scope: model.sidebarSelection, itemIds: itemIds, fileId: nil)
        context.translatingItemIds = model.translations.activeItemIds
        return context
    }

    var body: some View {
        let ids = itemIds
        let items = ids.compactMap { model.snapshot.items[$0] }
        let entries = ItemMenuBuilder.entries(for: context, snapshot: model.snapshot, groups: model.groupsForMenus)
            .filter { entry in
                // Opening many papers at once is not what this panel is for.
                if case let .action(_, _, command, _, _, _) = entry, command == .open || command == .quickLook { return false }
                return true
            }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(items)
                sharedTags(ids)
                VStack(spacing: 1) {
                    ForEach(Array(trimmed(entries).enumerated()), id: \.offset) { _, entry in
                        row(entry)
                    }
                }
            }
            .padding(16)
        }
        .accessibilityIdentifier("multiSelectionInspector")
    }

    private func header(_ items: [Item]) -> some View {
        let pdfs = items.filter { model.defaultFile(of: $0.id)?.isPDF == true }.count
        let translated = items.filter { item in model.snapshot.files(of: item.id).contains { $0.translationKind != nil } }.count
        return HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 30))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            VStack(alignment: .leading, spacing: 3) {
                Text("已选择 \(items.count) 篇文献")
                    .font(.headline)
                Text("\(pdfs) 篇有 PDF · \(translated) 篇已翻译")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button("全选") { model.selectedItemIDs = Set(model.rows) }
                    Button("取消选择") { model.selectedItemIDs = [] }
                    if model.multiSelectMode {
                        Button("完成") { model.multiSelectMode = false }
                    }
                }
                .buttonStyle(.link)
                .font(.callout)
                .padding(.top, 2)
            }
        }
    }

    /// Tags every selected paper has.
    @ViewBuilder
    private func sharedTags(_ ids: [String]) -> some View {
        let shared = model.snapshot.tags.filter { tag in ids.allSatisfy { model.snapshot.itemTags[$0]?.contains(tag.id) ?? false } }
        if !shared.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("共同标签")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                FlowLayout(spacing: 5) {
                    ForEach(shared) { tag in
                        TagChip(tag: tag) { perform(.toggleTag(tag.id)) }
                    }
                }
            }
        }
    }

    /// No separator first, last or twice in a row.
    private func trimmed(_ entries: [ItemMenuEntry]) -> [ItemMenuEntry] {
        var result: [ItemMenuEntry] = []
        for entry in entries {
            if case .separator = entry {
                if result.isEmpty { continue }
                if case .separator = result.last! { continue }
            }
            result.append(entry)
        }
        if case .separator? = result.last { result.removeLast() }
        return result
    }

    @ViewBuilder
    private func row(_ entry: ItemMenuEntry) -> some View {
        switch entry {
        case .separator:
            Divider().padding(.vertical, 5)
        case let .action(title, symbol, command, enabled, _, _):
            ActionRow(title: title, symbol: symbol, destructive: command == .trash || command == .purge, hasMenu: false) {
                perform(command)
            }
            .disabled(!enabled)
        case let .submenu(title, symbol, children):
            ActionRow(title: title, symbol: symbol, destructive: false, hasMenu: true) {
                popUp(children)
            }
        }
    }

    private func perform(_ command: ItemMenuCommand) {
        AppDelegate.shared.libraryWindowController?.perform(command, context: context)
    }

    /// A submenu row opens the context menu's own submenu (tag colours, group folders and all) under the pointer.
    private func popUp(_ children: [ItemMenuEntry]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let context = self.context
        ItemMenuBuilder.populate(menu, with: children, snapshot: model.snapshot) { command in
            AppDelegate.shared.libraryWindowController?.perform(command, context: context)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// One command of the panel: an icon, the title, and a chevron when it opens a menu.
private struct ActionRow: View {
    let title: String
    let symbol: String?
    let destructive: Bool
    let hasMenu: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Group {
                    if let symbol, symbol == TranslationIcon.fullTextSymbol, let image = TranslationIcon.menuImage(symbol) {
                        Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
                    } else if let symbol {
                        Image(systemName: symbol).font(.system(size: 14))
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 18, height: 18)
                .foregroundStyle(destructive ? Color(nsColor: .systemRed) : Color(nsColor: .secondaryLabelColor))
                Text(title)
                    .foregroundStyle(destructive ? Color(nsColor: .systemRed) : Color(nsColor: .labelColor))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if hasMenu {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(hovering && isEnabled ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
    }
}
