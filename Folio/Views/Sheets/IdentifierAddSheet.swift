import FolioCore
import SwiftUI

/// "通过标识符添加…": DOI / arXiv ID / ISBN → a new item without files (META-09, DUP-04).
struct IdentifierAddSheet: View {
    let model: AppModel
    @Environment(\.sheetDismiss) private var dismiss
    @State private var identifier = ""
    @State private var working = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("通过标识符添加")
                .font(.headline)
            Text("输入 DOI、arXiv ID 或 ISBN，Folio 会检索元数据并创建条目，之后可再为它添加文件。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("例如 10.1038/nature14539 或 2604.27326", text: $identifier)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
                .disabled(working)
                .accessibilityIdentifier("identifierField")
            if let message {
                Text(message).font(.caption).foregroundStyle(.red)
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("添加", action: add)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(identifier.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func add() {
        let value = identifier.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        working = true
        message = nil
        let resolver = model.importer.resolver
        Task {
            let result = await Task.detached { await resolver.resolve(identifier: value) }.value
            working = false
            switch result {
            case .found(let metadata):
                do {
                    switch try model.library.createItem(metadata, inGroup: model.sidebarSelection.groupId) {
                    case .created(let id):
                        model.selectedItemIDs = [id]
                        model.toasts.show("已添加「\(metadata.title)」", systemImage: "checkmark.circle")
                    case .duplicate(let existing):
                        model.selectedItemIDs = [existing]
                        model.toasts.show("已有该条目", systemImage: "doc.on.doc")
                    }
                    dismiss()
                } catch {
                    message = error.localizedDescription
                }
            case .notFound:
                message = "没有找到与该标识符对应的文献"
            case .networkError:
                message = "网络不可用，请检查连接后重试"
            }
        }
    }
}
