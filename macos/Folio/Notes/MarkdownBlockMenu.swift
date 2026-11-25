import AppKit
import SwiftUI

/// What the menu "/" opens shows: the tools that fit what was typed after it, or the papers to cite.
@Observable
final class MarkdownMenuState {
    enum Entry: Identifiable {
        case command(MarkdownCommand)
        case reference(MarkdownReference)
        var id: String {
            switch self {
            case .command(let command): command.id
            case .reference(let reference): "ref:" + reference.id
            }
        }
    }

    var entries: [Entry] = []
    var selected = 0
    /// Citing: a page of its own, found by typing.
    var isCiting = false
    /// Nothing typed yet: the tools are in their sections.
    var showsSections = true
    @ObservationIgnored var pick: (Int) -> Void = { _ in }
}

/// The menu itself: one quiet column, the tool's symbol, its name and the Markdown it stands for.
struct MarkdownMenuView: View {
    static let width: CGFloat = 264
    static let citingWidth: CGFloat = 400
    static let rowHeight: CGFloat = 30
    static let referenceHeight: CGFloat = 42
    static let headerHeight: CGFloat = 24
    static let maxHeight: CGFloat = 336

    let state: MarkdownMenuState

    static func height(of state: MarkdownMenuState) -> CGFloat {
        var height: CGFloat = 12
        if state.isCiting {
            height += headerHeight + CGFloat(max(state.entries.count, 1)) * referenceHeight
        } else {
            height += CGFloat(state.entries.count) * rowHeight
            if state.showsSections { height += CGFloat(MarkdownCommand.Section.allCases.count) * headerHeight }
        }
        return min(height, maxHeight)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if state.isCiting {
                        header(state.entries.isEmpty ? String(localized: "没有找到文献") : String(localized: "输入标题、作者或年份"))
                    }
                    ForEach(Array(state.entries.enumerated()), id: \.element.id) { index, entry in
                        if state.showsSections, !state.isCiting, case .command(let command) = entry, startsSection(index, command) {
                            header(command.section.title)
                        }
                        row(entry, selected: index == state.selected)
                            .id(entry.id)
                            .contentShape(Rectangle())
                            .onTapGesture { state.pick(index) }
                            .onContinuousHover { phase in if case .active = phase, state.selected != index { state.selected = index } }
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.never)
            .onChange(of: state.selected) { _, index in
                if state.entries.indices.contains(index) { proxy.scrollTo(state.entries[index].id) }
            }
        }
        .frame(width: state.isCiting ? Self.citingWidth : Self.width)
        .modifier(MenuBackground())
    }

    private func startsSection(_ index: Int, _ command: MarkdownCommand) -> Bool {
        guard index > 0, case .command(let previous) = state.entries[index - 1] else { return true }
        return previous.section != command.section
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.leading, 8)
            .frame(height: Self.headerHeight, alignment: .bottomLeading)
            .padding(.bottom, 0)
    }

    @ViewBuilder private func row(_ entry: MarkdownMenuState.Entry, selected: Bool) -> some View {
        HStack(spacing: 9) {
            switch entry {
            case .command(let command):
                Group {
                    if command.isLettered {
                        Text(verbatim: command.symbol).font(.system(size: 12, weight: .semibold))
                    } else {
                        Image(systemName: command.symbol).font(.system(size: 13))
                    }
                }
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .frame(width: 22)
                Text(command.title).font(.system(size: 13))
                Spacer(minLength: 8)
                Text(command.hint)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.tertiary))
            case .reference(let reference):
                VStack(alignment: .leading, spacing: 1) {
                    Text(reference.title).font(.system(size: 12.5)).lineLimit(1)
                    Text(reference.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: state.isCiting ? Self.referenceHeight : Self.rowHeight)
        .frame(maxWidth: .infinity)
        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Color.accentColor : .clear))
    }
}

private struct MenuBackground: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        if !UserDefaults.standard.bool(forKey: "FolioPreviewNoGlass"), #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.separator.opacity(0.7), lineWidth: 0.5))
                .clipShape(shape)
        }
    }
}

/// The menu's window: it never takes the keyboard from the text, which goes on being typed and filters it.
final class MarkdownMenuPopover: NSPanel {
    let state = MarkdownMenuState()
    private static let margin: CGFloat = 16

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        animationBehavior = .utilityWindow
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        let host = NSHostingView(rootView: MarkdownMenuView(state: state))
        host.sizingOptions = []
        contentView = host
    }

    override var canBecomeKey: Bool { false }

    /// Under the line at `rect` (screen coordinates), or over it when there is no room.
    func show(at rect: NSRect, of parent: NSWindow) {
        let size = NSSize(width: state.isCiting ? MarkdownMenuView.citingWidth : MarkdownMenuView.width, height: MarkdownMenuView.height(of: state))
        let screen = (parent.screen ?? NSScreen.main)?.visibleFrame ?? parent.frame
        var origin = NSPoint(x: rect.minX - 8, y: rect.minY - size.height - 4)
        if origin.y < screen.minY + 4 { origin.y = min(rect.maxY + 4, screen.maxY - size.height - 4) }
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
        setFrame(NSRect(origin: origin, size: size), display: true)
        if super.parent !== parent { parent.addChildWindow(self, ordered: .above) }
        invalidateShadow()
    }

    func dismiss() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}
