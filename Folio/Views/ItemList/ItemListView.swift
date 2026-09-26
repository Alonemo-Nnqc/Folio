import SwiftUI
import UniformTypeIdentifiers

/// The middle column: the item outline, the empty state and the Finder drop overlay (DND-01).
struct ItemListView: View {
    let model: AppModel
    @State private var dropTargeted = false
    @State private var dropCount = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ItemOutline(model: model)
            if model.rows.isEmpty {
                emptyState
                    .allowsHitTesting(false)
            }
            if dropTargeted {
                DropOverlay(fileCount: dropCount)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.18), value: dropTargeted)
        .onDrop(of: [.fileURL], delegate: FinderDropDelegate(model: model, targeted: $dropTargeted, count: $dropCount))
        .onChange(of: model.previewDropCount) { _, count in
            dropCount = count
            dropTargeted = count > 0
        }
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

/// Accepts files dragged in from Finder; ignores drags that started inside Folio.
struct FinderDropDelegate: DropDelegate {
    let model: AppModel
    @Binding var targeted: Bool
    @Binding var count: Int

    func validateDrop(info: DropInfo) -> Bool {
        !info.hasItemsConforming(to: [UTType("com.nnqc.folio.item") ?? .data]) && info.hasItemsConforming(to: [.fileURL])
            && model.sidebarSelection != .trash
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else { return }
        count = info.itemProviders(for: [.fileURL]).count
        targeted = true
    }

    func dropExited(info: DropInfo) {
        targeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        let providers = info.itemProviders(for: [.fileURL])
        let groupId = model.sidebarSelection.groupId
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = try? await provider.loadFileURL() { urls.append(url) }
            }
            model.importer.importFiles(urls, toGroup: groupId)
        }
        return true
    }
}

extension NSItemProvider {
    func loadFileURL() async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: url) }
            }
        }
    }
}
