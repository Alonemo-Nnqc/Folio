import SwiftUI

/// Placeholder until FolioZotero is merged.
struct ZoteroImportSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("从 Zotero 导入")
            Button("关闭") { dismiss() }
        }
        .padding(20)
    }
}
