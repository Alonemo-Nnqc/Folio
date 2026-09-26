import FolioCore
import SwiftUI

/// Pick existing tags or create a new one by typing (TAG-02).
struct TagPickerPopover: View {
    let model: AppModel
    let itemIds: [String]
    @State private var query = ""

    private var filtered: [Tag] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return model.snapshot.tags.filter { q.isEmpty || $0.name.lowercased().contains(q) }
    }

    private var canCreate: Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return !q.isEmpty && !model.snapshot.tags.contains { $0.name.compare(q, options: .caseInsensitive) == .orderedSame }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("搜索或新建标签", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if canCreate { create() } }
                .accessibilityIdentifier("tagPickerField")
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered) { tag in
                        row(tag)
                    }
                    if canCreate {
                        Button(action: create) {
                            Label("新建标签「\(query.trimmingCharacters(in: .whitespaces))」", systemImage: "plus.circle")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                    }
                    if filtered.isEmpty && !canCreate {
                        Text("还没有标签")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    }
                }
            }
            .frame(maxHeight: 240)
        }
        .padding(12)
        .frame(width: 260)
    }

    private func row(_ tag: Tag) -> some View {
        let applied = itemIds.allSatisfy { model.snapshot.itemTags[$0]?.contains(tag.id) ?? false }
        return Button {
            model.setTag(tag.id, on: itemIds, enabled: !applied)
        } label: {
            HStack {
                Image(systemName: applied ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(applied ? Color.accentColor : .secondary)
                Circle().fill(Color(hex: tag.colorHex)).frame(width: 9, height: 9)
                Text(tag.name).lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
        .contextMenu {
            Button("编辑标签…") { model.activeSheet = .tagEditor(tagId: tag.id, applyTo: []) }
            Button("删除标签", role: .destructive) { model.confirmDeleteTag(tag.id) }
        }
    }

    private func create() {
        model.activeSheet = .tagEditor(tagId: nil, applyTo: itemIds, initialName: query.trimmingCharacters(in: .whitespaces))
    }
}
