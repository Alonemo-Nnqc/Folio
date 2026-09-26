import SwiftUI

/// The middle column: the item outline, the empty state and the Finder drop overlay (DND-01).
/// Drops themselves are handled by the outline (ItemListController).
struct ItemListView: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ItemOutline(model: model)
            if model.rows.isEmpty {
                emptyState
                    .allowsHitTesting(false)
            }
            if model.externalDropCount > 0 {
                DropOverlay(fileCount: model.externalDropCount)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.18), value: model.externalDropCount > 0)
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.search.isActive {
            ContentUnavailableView.search(text: model.search.text)
        } else if model.sidebarSelection == .trash {
            ContentUnavailableView("回收站是空的", systemImage: "trash", description: Text("删除的文献会在这里保留 30 天"))
        } else {
            ContentUnavailableView("拖入 PDF 或点击 + 添加文献", systemImage: "doc.badge.plus",
                                   description: Text("Folio 会自动检索元数据并创建条目"))
        }
    }
}
