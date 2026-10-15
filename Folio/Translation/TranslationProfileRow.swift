import AppKit
import FolioTranslate
import SwiftUI

/// "配置" under the translation service (TRANS-03): pick one of the service's saved configurations — each its own
/// Base URL, key and model — or create, duplicate, rename and delete them. Shown in 设置 ▸ 翻译 and in the
/// "翻译全文" sheet, so the provider can be switched right before translating.
struct TranslationProfileRow: View {
    let model: AppModel
    let service: TranslationService

    private var settings: AppSettings { model.settings }
    private var profiles: [TranslationProfile] { settings.translationProfiles.filter { $0.serviceID == service.id } }
    private var selected: TranslationProfile? {
        settings.selectedTranslationProfiles[service.id].flatMap { id in profiles.first { $0.id == id } }
    }

    var body: some View {
        LabeledContent("配置") {
            HStack(spacing: 6) {
                Picker("配置", selection: Binding(get: { selected?.id ?? "" }, set: choose)) {
                    if selected == nil { Text(profiles.isEmpty ? "未保存" : "当前设置（未保存）").tag("") }
                    ForEach(profiles) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
                Menu {
                    Button("新建配置…", systemImage: "plus") { create(copyingCurrent: false) }
                    Button(selected == nil ? "将当前设置存为配置…" : "复制为新配置…", systemImage: "plus.square.on.square") {
                        create(copyingCurrent: true)
                    }
                    if let selected {
                        Divider()
                        Button("重命名…", systemImage: "pencil") { rename(selected) }
                        Button("删除「\(selected.name)」…", systemImage: "trash", role: .destructive) { delete(selected) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("新建、复制、重命名或删除配置")
                .accessibilityLabel("管理配置")
            }
        }
        .help(profiles.isEmpty ? "把这组设置存为配置后，可以保存多个服务商并一键切换" : "")
    }

    private var secrets: SecretStore { model.translations.secrets }

    /// Values not saved as a configuration are kept as one before they would be replaced.
    private func keepUnsavedValues() {
        guard selected == nil else { return }
        let fields = settings.translationFields[service.id] ?? [:]
        let hasKeys = !((try? secrets.secrets(for: service)) ?? [:]).isEmpty
        guard hasKeys || fields.values.contains(where: { !$0.isEmpty }) else { return }
        let name = TranslationProfiles.suggestedName(service: service, fields: fields, existing: settings.translationProfiles)
        if let profile = try? TranslationProfiles.capture(name: name, service: service, fields: fields, secrets: secrets) {
            settings.translationProfiles.append(profile)
        }
    }

    private func choose(_ id: String) {
        guard let profile = profiles.first(where: { $0.id == id }), profile.id != selected?.id else { return }
        keepUnsavedValues()
        use(profile)
        model.toasts.show("已切换到「\(profile.name)」", systemImage: "arrow.left.arrow.right")
    }

    /// Puts the profile's values and keys in place and marks it as the one in use.
    private func use(_ profile: TranslationProfile) {
        do {
            let fields = try TranslationProfiles.apply(profile, service: service, secrets: secrets)
            settings.selectedTranslationProfiles[service.id] = profile.id
            settings.translationFields[service.id] = fields
        } catch {
            model.toasts.show("无法读取「\(profile.name)」的 API Key：\(error.localizedDescription)", systemImage: "exclamationmark.triangle")
        }
    }

    private func create(copyingCurrent: Bool) {
        let current = settings.translationFields[service.id] ?? [:]
        let suggestion = copyingCurrent
            ? TranslationProfiles.suggestedName(service: service, fields: current, existing: settings.translationProfiles)
            : "新配置"
        guard let name = Self.askName(title: copyingCurrent ? "存为新配置" : "新建配置", suggestion: suggestion) else { return }
        if copyingCurrent {
            guard let profile = try? TranslationProfiles.capture(name: name, service: service, fields: current, secrets: secrets) else { return }
            settings.translationProfiles.append(profile)
            settings.selectedTranslationProfiles[service.id] = profile.id
        } else {
            keepUnsavedValues()
            let profile = TranslationProfile(name: name, serviceID: service.id)
            settings.translationProfiles.append(profile)
            use(profile)
        }
    }

    private func rename(_ profile: TranslationProfile) {
        guard let name = Self.askName(title: "重命名配置", suggestion: profile.name),
              let index = settings.translationProfiles.firstIndex(where: { $0.id == profile.id }) else { return }
        settings.translationProfiles[index].name = name
    }

    private func delete(_ profile: TranslationProfile) {
        let alert = NSAlert()
        alert.messageText = "删除配置「\(profile.name)」？"
        alert.informativeText = "会删除它保存的 Base URL、模型和 API Key。当前填写的内容保留，可以再存为配置。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? TranslationProfiles.deleteSecrets(of: profile, service: service, secrets: secrets)
        settings.translationProfiles.removeAll { $0.id == profile.id }
        if settings.selectedTranslationProfiles[service.id] == profile.id { settings.selectedTranslationProfiles[service.id] = nil }
    }

    /// A name from the user; nil when cancelled or empty.
    static func askName(title: String, suggestion: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "例如服务商的名字：DeepSeek、Moonshot、公司内网"
        let field = NSTextField(string: suggestion)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
