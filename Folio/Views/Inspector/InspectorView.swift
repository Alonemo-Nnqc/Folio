import FolioCore
import SwiftUI

/// Right column: metadata or annotations of the selected item (INSP-01…05).
struct InspectorView: View {
    let model: AppModel
    @State private var tab = Tab.metadata

    enum Tab: String, CaseIterable {
        case metadata = "元数据"
        case annotations = "标注"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("检查器", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: model.previewInspectorTab) { _, value in if value == "annotations" { tab = .annotations } }
    }

    @ViewBuilder
    private var content: some View {
        if let item = model.inspectedItem {
            switch tab {
            case .metadata:
                if item.kind == .standalone {
                    StandaloneFileInspector(model: model, item: item)
                } else {
                    MetadataInspector(model: model, item: item)
                        .id(item.id)
                }
            case .annotations:
                AnnotationsInspector(model: model, item: item)
                    .id(item.id)
            }
        } else if model.selectionCount > 1 {
            ContentUnavailableView("已选择 \(model.selectionCount) 项", systemImage: "square.stack.3d.up",
                                   description: Text("右键可批量添加到分组、添加标签或删除"))
        } else {
            ContentUnavailableView("未选择条目", systemImage: "doc.text.magnifyingglass",
                                   description: Text("在列表中选择一篇文献以查看详情"))
        }
    }
}

/// A labelled text field that keeps a local draft and saves on Return or focus loss.
struct EditableField: View {
    let label: String
    let value: String?
    var placeholder = "—"
    var monospaced = false
    var link: URL?
    let onCommit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .fontDesign(monospaced ? .monospaced : .default)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            if let link {
                Button {
                    NSWorkspace.shared.open(link)
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.borderless)
                .help("在浏览器中打开")
            }
        }
        .font(.callout)
        .onAppear { draft = value ?? "" }
        .onChange(of: value) { _, newValue in if !focused { draft = newValue ?? "" } }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != (value ?? "") { onCommit(trimmed) }
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
