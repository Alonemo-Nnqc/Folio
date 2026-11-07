import FolioCore
import SwiftUI

/// Details of a standalone file plus the retrieval fallbacks (INSP-04, META-07).
struct StandaloneFileInspector: View {
    let model: AppModel
    let item: Item

    var body: some View {
        let file = model.snapshot.files(of: item.id).first
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    if let file {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: model.fileURL(file).path))
                            .resizable()
                            .frame(width: 48, height: 48)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.headline)
                            .textSelection(.enabled)
                        Text(status)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if let file {
                    InspectorSection(title: String(localized: "文件")) {
                        LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                        LabeledContent("添加于", value: item.dateAdded.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("原文件名", value: file.originalName)
                    }
                    .font(.callout)
                }
                if file?.isPDF ?? false {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("重新检索元数据", systemImage: "arrow.clockwise") { model.importer.retrieve(itemId: item.id) }
                            .disabled(item.metadataState == .pending)
                        Button("手动匹配…", systemImage: "magnifyingglass") { model.activeSheet = .manualMatch(itemId: item.id) }
                    }
                    .glassButtonStyle()
                }
            }
            .padding(16)
        }
    }

    private var status: String {
        switch item.metadataState {
        case .pending: String(localized: "正在检索元数据…")
        case .failed: String(localized: "未检索到元数据，已保留为独立文件")
        case .networkFailed: String(localized: "网络不可用，恢复后会自动重试")
        default: String(localized: "独立文件")
        }
    }
}
