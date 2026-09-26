import FolioCore
import SwiftUI

/// Create or edit a tag: name + colour (TAG-03/04). New tags are applied to `applyTo` items.
struct TagEditorSheet: View {
    let model: AppModel
    let tagId: String?
    let applyTo: [String]
    var initialName = ""
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var colorHex = TagPalette.presets[6].hex
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tagId == nil ? "新建标签" : "编辑标签")
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
                HStack(spacing: 8) {
                    ForEach(TagPalette.presets, id: \.hex) { preset in
                        Button {
                            colorHex = preset.hex
                        } label: {
                            Circle()
                                .fill(Color(hex: preset.hex))
                                .frame(width: 20, height: 20)
                                .overlay {
                                    if preset.hex == colorHex {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .help(preset.name)
                        .accessibilityLabel(preset.name)
                    }
                    ColorPicker("自定义颜色", selection: customColor, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 28)
                        .help("自定义颜色")
                }
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
                Button(tagId == nil ? "创建" : "保存", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
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

    private var customColor: Binding<Color> {
        Binding(get: { Color(hex: colorHex) }, set: { colorHex = NSColor($0).hexString })
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
