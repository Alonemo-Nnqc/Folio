import AppKit
import SwiftUI

/// Sidebar | item list | inspector, built from the semantic split items so AppKit supplies the
/// sidebar material, the inspector style, collapsing and the toolbar tracking separators (UI-01).
final class LibrarySplitViewController: SmoothSplitViewController {
    let sidebar: SidebarViewController
    let itemList: ItemListViewController
    let inspector: NSHostingController<InspectorView>
    private let model: AppModel
    private var sidebarItem: NSSplitViewItem!
    private var inspectorItem: NSSplitViewItem!
    private var inspectorPane: PaneContainerController!
    private var observers: [ObservationLoop] = []

    init(model: AppModel) {
        self.model = model
        sidebar = SidebarViewController(model: model)
        itemList = ItemListViewController(model: model)
        inspector = NSHostingController(rootView: InspectorView(model: model))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override func viewDidLoad() {
        super.viewDidLoad()
        sidebarItem = NSSplitViewItem(sidebarWithViewController: PaneContainerController(child: sidebar, edge: .leading))
        sidebarItem.minimumThickness = 210
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true
        sidebarItem.preferredThicknessFraction = 0.2

        let content = NSSplitViewItem(viewController: itemList)
        content.minimumThickness = 420

        inspectorPane = PaneContainerController(child: inspector, edge: .trailing)
        inspectorPane.backdrop.baseColor = .windowBackgroundColor
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorPane)
        inspectorItem.minimumThickness = 270
        inspectorItem.maximumThickness = 520
        inspectorItem.canCollapse = true
        inspectorItem.canCollapseFromWindowResize = true

        addSplitViewItem(sidebarItem)
        addSplitViewItem(content)
        addSplitViewItem(inspectorItem)
        // Widths and collapsed states are remembered (SIDE-11, INSP-01); UI tests start fresh.
        if !UserDefaults.standard.bool(forKey: "FolioUITesting") {
            splitView.autosaveName = "FolioLibrarySplit2"
        }
        observers.append(ObservationLoop { [weak self] in
            guard let self else { return }
            let amount = self.model.settings.backgroundTranslucency
            self.inspectorPane.backdrop.amount = amount
            self.itemList.setTranslucency(amount)
        })
    }

    var isInspectorCollapsed: Bool { inspectorItem?.isCollapsed ?? true }

    func showInspector() {
        guard let inspectorItem, inspectorItem.isCollapsed else { return }
        setCollapsed(inspectorItem, false)
    }
}
