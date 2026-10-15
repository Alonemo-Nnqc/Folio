import AppKit
import SwiftUI

/// The middle column: search scope bar, the item outline, and overlays for the empty state, the
/// Finder drop target (DND-01) and toasts (UI-04).
final class ItemListViewController: NSViewController {
    let controller: ItemListController
    private let model: AppModel
    private var observers: [ObservationLoop] = []
    private let scroll = NSScrollView()
    private var scopeBar: NSView!
    private var scrollTopToView: NSLayoutConstraint!
    private var scrollTopToScopeBar: NSLayoutConstraint!

    init(model: AppModel) {
        self.model = model
        controller = ItemListController(model: model)
        super.init(nibName: nil, bundle: nil)
        model.itemListController = controller
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override func loadView() {
        let root = NSView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = controller.outline

        let bar = NSHostingView(rootView: SearchScopeBar(model: model))
        bar.sizingOptions = [.intrinsicContentSize]
        scopeBar = bar
        let overlay = PassthroughHostingView(rootView: ItemListOverlay(model: model))
        let toast = NSHostingView(rootView: ToastOverlay(center: model.toasts))
        toast.sizingOptions = [.intrinsicContentSize]

        for view in [scroll, bar, overlay, toast] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        scrollTopToView = scroll.topAnchor.constraint(equalTo: root.topAnchor)
        scrollTopToScopeBar = scroll.topAnchor.constraint(equalTo: bar.bottomAnchor)
        NSLayoutConstraint.activate([
            // The scope bar sits right under the toolbar (safe area), like Finder's search bar.
            bar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollTopToView,
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            overlay.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            toast.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            toast.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -40),
        ])
        bar.isHidden = true
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observers.append(ObservationLoop { [weak self] in
            guard let self else { return }
            _ = (self.model.rows, self.model.snapshot, self.model.selectedItemIDs, self.model.selectedFileIDs,
                 self.model.currentSort, self.model.previewExpandRequest, self.model.translations.jobs)
            self.controller.update()
        })
        observers.append(ObservationLoop { [weak self] in
            guard let self else { return }
            self.setScopeBarVisible(self.model.search.isActive)
        })
    }

    private func setScopeBarVisible(_ visible: Bool) {
        guard scopeBar.isHidden == visible else { return }
        scopeBar.isHidden = !visible
        scrollTopToView.isActive = !visible
        scrollTopToScopeBar.isActive = visible
    }

    func focusList() {
        view.window?.makeFirstResponder(controller.outline)
        if controller.outline.selectedRow < 0, controller.outline.numberOfRows > 0 {
            controller.outline.selectRowIndexes([0], byExtendingSelection: false)
        }
    }
}

/// A hosting view that never takes mouse events: overlays drawn over the list stay click-through.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Finder-style search scope bar: where to search and whether to include PDF full text (SEARCH-03/04).
struct SearchScopeBar: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("搜索：")
                    .foregroundStyle(.secondary)
                if model.sidebarSelection == .all {
                    // Searching "所有文献" already covers the whole library: nothing to choose.
                    Text("所有文献")
                } else {
                    Toggle("「\(model.title(for: model.sidebarSelection))」",
                           isOn: Binding(get: { !model.search.wholeLibrary }, set: { if $0 { model.search.wholeLibrary = false } }))
                        .accessibilityIdentifier("scopeCurrent")
                    Toggle("全部文献", isOn: Binding(get: { model.search.wholeLibrary }, set: { if $0 { model.search.wholeLibrary = true } }))
                        .accessibilityIdentifier("scopeAll")
                }
                Spacer(minLength: 12)
                Toggle("包含 PDF 全文", isOn: $model.search.includeFulltext)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("fulltextToggle")
            }
            .toggleStyle(.button)
            .buttonStyle(.accessoryBar)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
        }
        .background(.bar)
    }
}

/// Empty state and the drop target drawn over the list.
struct ItemListOverlay: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if model.rows.isEmpty { emptyState }
            if model.externalDropCount > 0 {
                DropOverlay(fileCount: model.externalDropCount)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.18), value: model.externalDropCount > 0)
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.search.isActive {
            ContentUnavailableView.search(text: model.search.text)
        } else if model.sidebarSelection == .trash {
            ContentUnavailableView("回收站是空的", systemImage: "trash",
                                   description: Text(model.settings.autoPurgeTrash ? String(localized: "删除的文献会在这里保留 30 天") : String(localized: "删除的文献会保留在这里")))
        } else {
            ContentUnavailableView("拖入 PDF 或点击 + 添加文献", systemImage: "doc.badge.plus",
                                   description: Text("Folio 会自动检索元数据并创建条目"))
        }
    }
}
