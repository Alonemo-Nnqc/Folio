import FolioCore
import SwiftUI

/// Create or edit a tag: name + colour (TAG-03/04). New tags are applied to `applyTo` items.
struct TagEditorSheet: View {
    let model: AppModel
    let tagId: String?
    let applyTo: [String]
    var initialName = ""
    @Environment(\.sheetDismiss) private var dismiss
    @State private var name = ""
    @State private var colorHex = TagPalette.presets[6].hex
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tagId == nil ? String(localized: "新建标签") : String(localized: "编辑标签"))
                .font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                TextField("标签名称", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                    .accessibilityIdentifier("tagNameField")
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("颜色")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ColorSwatchRow(hex: Binding(get: { colorHex }, set: { colorHex = $0 ?? colorHex }))
            }
            if !name.isEmpty {
                HStack {
                    Text("预览")
                        .foregroundStyle(.secondary)
                    TagChip(tag: Tag(name: name, colorHex: colorHex, position: 0))
                }
                .font(.callout)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(tagId == nil ? String(localized: "创建") : String(localized: "保存"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .glassProminentButtonStyle()
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            if let tagId, let tag = model.snapshot.tagsById[tagId] {
                name = tag.name
                colorHex = tag.colorHex
            } else {
                name = initialName
            }
        }
    }

    private func save() {
        do {
            if let tagId {
                try model.library.updateTag(tagId, name: name, colorHex: colorHex)
            } else {
                let tag = try model.library.createTag(name: name, colorHex: colorHex)
                if !applyTo.isEmpty { try model.library.setTag(tag.id, onItems: applyTo, enabled: true) }
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
