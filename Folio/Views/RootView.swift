import SwiftUI

struct RootView: View {
    var body: some View {
        NavigationSplitView {
            List {
                Label("所有文献", systemImage: "books.vertical")
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 380)
        } detail: {
            ContentUnavailableView("拖入 PDF 或点击 + 添加文献", systemImage: "doc.badge.plus")
        }
    }
}
