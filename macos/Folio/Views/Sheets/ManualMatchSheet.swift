import FolioCore
import SwiftUI

/// "手动匹配…": search by identifier or title and pick the right record (META-07).
struct ManualMatchSheet: View {
    let model: AppModel
    let itemId: String
    @Environment(\.sheetDismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Metadata] = []
    @State private var selection: Int?
    @State private var searching = false
    @State private var searched = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("手动匹配元数据")
                .font(.headline)
            HStack {
                TextField("输入 DOI、arXiv ID 或论文标题", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                    .accessibilityIdentifier("manualMatchField")
                Button("搜索", action: search)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
            }
            Group {
                if searching {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty {
                    ContentUnavailableView(searched ? String(localized: "没有找到结果") : String(localized: "输入后按回车搜索"), systemImage: "magnifyingglass")
                } else {
                    List(results.indices, id: \.self, selection: $selection) { index in
                        resultRow(results[index]).tag(index)
                    }
                    .listStyle(.inset)
                }
            }
            .frame(height: 280)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("使用所选结果", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .glassProminentButtonStyle()
                    .disabled(selection == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            if let item = model.snapshot.items[itemId] {
                query = item.kind == .regular ? item.title : (item.title as NSString).deletingPathExtension
            }
        }
    }

    private func resultRow(_ metadata: Metadata) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(metadata.title).lineLimit(2)
            Text([AuthorFormatter.listDisplay(metadata.authors), metadata.year.map(String.init), metadata.source]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        searching = true
        selection = nil
        let resolver = model.importer.resolver
        Task {
            results = await Task.detached { await resolver.search(text) }.value
            searching = false
            searched = true
            if !results.isEmpty { selection = 0 }
        }
    }

    private func apply() {
        guard let selection, results.indices.contains(selection), let item = model.snapshot.items[itemId] else { return }
        let metadata = results[selection]
        if item.kind == .standalone {
            model.importer.apply(metadata, toStandalone: itemId)
        } else {
            model.perform { try model.library.updateMetadata(itemId, metadata, autoRename: model.settings.autoRenameFiles) }
        }
        dismiss()
    }
}
