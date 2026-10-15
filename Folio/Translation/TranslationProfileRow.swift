import AppKit
import FolioTranslate
import SwiftUI

/// "配置" under the translation service (TRANS-03), like the Location menu of macOS's Network settings: a popup
/// of the service's saved configurations — each its own Base URL, key and model — then "编辑配置…", which opens
/// `TranslationProfilesEditor`. Shown in 设置 ▸ 翻译 and in the "翻译全文" sheet.
struct TranslationProfileRow: View {
    let model: AppModel
    let service: TranslationService
    /// `-FolioPreviewProfileEditor YES` opens the editor for screenshots.
    @State private var editing = UserDefaults.standard.bool(forKey: "FolioPreviewProfileEditor")

    private static let editTag = "\u{1}edit"

    var body: some View {
        let settings = model.settings
        let profiles = settings.translationProfiles.filter { $0.serviceID == service.id }
        let selected = settings.selectedTranslationProfiles[service.id].flatMap { id in profiles.first { $0.id == id } }
        Picker("配置", selection: Binding(get: { selected?.id ?? "" }, set: choose)) {
            if selected == nil { Text("未保存的设置").tag("") }
            ForEach(profiles) { Text($0.name).tag($0.id) }
            Divider()
            Text(profiles.isEmpty ? String(localized: "存为配置…") : String(localized: "编辑配置…")).tag(Self.editTag)
        }
        .help("保存多个服务商的 Base URL、API Key 和模型，在这里一键切换")
        .sheet(isPresented: $editing) {
            TranslationProfilesEditor(model: model, service: service)
        }
    }

    private func choose(_ id: String) {
        if id == Self.editTag {
            editing = true
            return
        }
        let profiles = TranslationProfileActions(model: model, service: service)
        guard let profile = profiles.all.first(where: { $0.id == id }), profile.id != profiles.selectedID else { return }
        profiles.keepUnsavedValues()
        profiles.use(profile)
        model.toasts.show(String(localized: "已切换到「\(profile.name)」"), systemImage: "arrow.left.arrow.right")
    }
}

/// What the row and the editor do with a service's configurations.
struct TranslationProfileActions {
    let model: AppModel
    let service: TranslationService

    var settings: AppSettings { model.settings }
    var secrets: SecretStore { model.translations.secrets }
    var all: [TranslationProfile] { settings.translationProfiles.filter { $0.serviceID == service.id } }
    var selectedID: String? { settings.selectedTranslationProfiles[service.id] }

    /// Values not saved as a configuration are kept as one (named after their server) before they would be lost;
    /// returns it.
    @discardableResult
    func keepUnsavedValues() -> TranslationProfile? {
        guard selectedID == nil else { return nil }
        let fields = settings.translationFields[service.id] ?? [:]
        let hasKeys = !((try? secrets.secrets(for: service)) ?? [:]).isEmpty
        guard hasKeys || fields.values.contains(where: { !$0.isEmpty }) else { return nil }
        let name = TranslationProfiles.suggestedName(service: service, fields: fields, existing: settings.translationProfiles)
        guard let profile = try? TranslationProfiles.capture(name: name, service: service, fields: fields, secrets: secrets) else { return nil }
        settings.translationProfiles.append(profile)
        settings.selectedTranslationProfiles[service.id] = profile.id
        return profile
    }

    /// Puts the profile's values and keys in place and marks it as the one in use.
    func use(_ profile: TranslationProfile) {
        do {
            let fields = try TranslationProfiles.apply(profile, service: service, secrets: secrets)
            settings.selectedTranslationProfiles[service.id] = profile.id
            settings.translationFields[service.id] = fields
        } catch {
            model.toasts.show(String(localized: "无法读取「\(profile.name)」的 API Key：\(error.localizedDescription)"), systemImage: "exclamationmark.triangle")
        }
    }

    func add(copying source: TranslationProfile? = nil) -> TranslationProfile {
        var profile = TranslationProfile(name: uniqueName(source.map { String(localized: "\($0.name) 副本") } ?? String(localized: "新配置")), serviceID: service.id,
                                         fields: source?.fields ?? [:])
        if let source {
            for field in service.secretFields {
                if let value = try? secrets.get(serviceID: source.secretOwner, option: field.option) {
                    try? secrets.set(value, serviceID: profile.secretOwner, option: field.option)
                }
            }
        }
        profile.name = profile.name.trimmingCharacters(in: .whitespaces)
        settings.translationProfiles.append(profile)
        return profile
    }

    func remove(_ profile: TranslationProfile) {
        try? TranslationProfiles.deleteSecrets(of: profile, service: service, secrets: secrets)
        settings.translationProfiles.removeAll { $0.id == profile.id }
        if selectedID == profile.id { settings.selectedTranslationProfiles[service.id] = nil }
    }

    func uniqueName(_ base: String) -> String {
        let taken = Set(all.map(\.name))
        guard taken.contains(base) else { return base }
        return (2...).lazy.map { "\(base) \($0)" }.first { !taken.contains($0) }!
    }
}

/// "编辑配置…", laid out like System Settings ▸ Wi-Fi ▸ Known Networks: a header, the configurations as rows of a
/// grouped form — a checkmark on the one in use, its server and model underneath, a ⋯ menu for the rest — and
/// "添加配置…" below. Editing happens in `ProfileDetailSheet`, like a network's details sheet.
struct TranslationProfilesEditor: View {
    let model: AppModel
    let service: TranslationService
    @Environment(\.dismiss) private var dismiss
    /// The configuration being edited in the details sheet (nil id: a new one).
    @State private var editing: ProfileDraft?
    @State private var confirmingDelete: TranslationProfile?

    private var actions: TranslationProfileActions { TranslationProfileActions(model: model, service: service) }

    var body: some View {
        let profiles = actions.all
        VStack(spacing: 0) {
            header
            Form {
                Section {
                    if profiles.isEmpty {
                        Text("还没有配置").foregroundStyle(.secondary)
                    }
                    ForEach(profiles) { row($0) }
                } footer: {
                    HStack {
                        Spacer()
                        Button("添加配置…") { editing = ProfileDraft(new: service, name: actions.uniqueName(String(localized: "新配置"))) }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        // Tall enough for the rows, like System Settings' sheets; long lists scroll.
        .frame(width: 520, height: min(190 + CGFloat(max(profiles.count, 1)) * 52, 560))
        .onAppear {
            // Values typed before configurations existed become the first one, so nothing is lost.
            actions.keepUnsavedValues()
            if UserDefaults.standard.bool(forKey: "FolioPreviewProfileDetail"), let first = actions.all.first {
                editing = ProfileDraft(profile: first, service: service, secrets: actions.secrets)
            }
        }
        .sheet(item: $editing) { draft in
            ProfileDetailSheet(model: model, service: service, draft: draft)
        }
        .confirmationDialog("删除配置「\(confirmingDelete?.name ?? "")」？", isPresented: Binding(
            get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } })) {
            Button("删除", role: .destructive) {
                if let profile = confirmingDelete { actions.remove(profile) }
            }
        } message: {
            Text("它保存的服务地址、模型和 API Key 都会删除")
        }
    }

    private var header: some View {
        ProfileSheetHeader(title: String(localized: "\(service.displayName)配置"), subtitle: String(localized: "每个配置保存一个服务商的地址、API Key 和模型"))
    }

    private func row(_ profile: TranslationProfile) -> some View {
        let inUse = profile.id == actions.selectedID
        return HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .opacity(inUse ? 1 : 0)
                .frame(width: 16)
                .accessibilityHidden(!inUse)
                .accessibilityLabel(String(localized: "正在使用"))
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                Text(summary(profile)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Menu {
                Button("设为当前使用") { actions.use(profile) }.disabled(inUse)
                Button("编辑…") { editing = ProfileDraft(profile: profile, service: service, secrets: actions.secrets) }
                Button("复制") { _ = actions.add(copying: profile) }
                Divider()
                Button("删除…", role: .destructive) { confirmingDelete = profile }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多操作")
            .accessibilityLabel(String(localized: "\(profile.name) 的更多操作"))
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editing = ProfileDraft(profile: profile, service: service, secrets: actions.secrets) }
    }

    /// "api.deepseek.com · deepseek-chat": where it sends text and with which model.
    private func summary(_ profile: TranslationProfile) -> String {
        let urlField = service.fields.first { $0.kind == .url }
        let host = urlField.flatMap { profile.fields[$0.option] }.flatMap { URL(string: $0)?.host() }
        let model = service.fields.first { $0.title == TranslationServiceCatalog.modelFieldTitle }.flatMap { profile.fields[$0.option] }
        let parts = [host, model].compactMap { $0 }
        return parts.isEmpty ? String(localized: "未填写") : parts.joined(separator: " · ")
    }
}

/// A configuration being edited: changes stay here until 存储.
struct ProfileDraft: Identifiable {
    let id = UUID()
    /// The configuration edited; nil while adding one.
    var profileID: String?
    var name: String
    var fields: [String: String]
    var secrets: [String: String]

    init(new service: TranslationService, name: String) {
        profileID = nil
        self.name = name
        fields = [:]
        secrets = [:]
    }

    init(profile: TranslationProfile, service: TranslationService, secrets store: SecretStore) {
        profileID = profile.id
        name = profile.name
        fields = profile.fields
        var secrets: [String: String] = [:]
        for field in service.secretFields {
            secrets[field.option] = (try? store.get(serviceID: profile.secretOwner, option: field.option)) ?? nil
        }
        self.secrets = secrets
    }
}

/// A configuration's details, like a Wi-Fi network's details sheet: name, connection, advanced options, and
/// 取消 / 存储 (or 添加). Saving the configuration in use puts it into effect at once.
private struct ProfileDetailSheet: View {
    let model: AppModel
    let service: TranslationService
    @State var draft: ProfileDraft
    @Environment(\.dismiss) private var dismiss
    @State private var showAdvanced = false

    private var actions: TranslationProfileActions { TranslationProfileActions(model: model, service: service) }
    private var isNew: Bool { draft.profileID == nil }

    var body: some View {
        VStack(spacing: 0) {
            ProfileSheetHeader(title: isNew ? String(localized: "新配置") : draft.name.isEmpty ? String(localized: "未命名配置") : draft.name, subtitle: service.displayName)
            Form {
                Section {
                    TextField("名称", text: $draft.name, prompt: Text("例如 DeepSeek、Moonshot"))
                }
                let connection = service.fields.filter { !$0.isAdvanced }
                if !connection.isEmpty {
                    Section("连接") {
                        ForEach(connection) { row(for: $0) }
                        ReasoningPicker(serviceID: service.id, fields: $draft.fields)
                    }
                }
                // Reasoning effort is chosen above, not typed among the advanced options.
                let advanced = service.fields.filter { $0.isAdvanced && !ReasoningEffort.managedOptions.contains($0.option) }
                if !advanced.isEmpty {
                    Section {
                        DisclosureGroup("高级", isExpanded: $showAdvanced) { ForEach(advanced) { row(for: $0) } }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? String(localized: "添加") : String(localized: "存储")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 480, height: 460)
        .navigationTitle(isNew ? String(localized: "新配置") : draft.name)
    }

    @ViewBuilder
    private func row(for field: TranslationServiceField) -> some View {
        let title = field.isRequired ? field.title : String(localized: "\(field.title)（选填）")
        let text = Binding(get: { draft.fields[field.option] ?? "" },
                           set: { draft.fields[field.option] = $0.isEmpty ? nil : $0 })
        switch field.kind {
        case .secret:
            SecureField(title, text: Binding(get: { draft.secrets[field.option] ?? "" }, set: { draft.secrets[field.option] = $0 }),
                        prompt: Text(field.placeholder ?? String(localized: "未填写")))
        case .toggle:
            Toggle(title, isOn: Binding(get: { text.wrappedValue == "true" }, set: { text.wrappedValue = $0 ? "true" : "" }))
        default:
            if ModelListFetcher.supports(serviceID: service.id, modelOption: field.option) {
                LabeledContent(title) {
                    HStack(spacing: 6) {
                        TextField(title, text: text, prompt: Text(field.placeholder ?? field.defaultValue ?? ""))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                        ModelListButton(model: model, serviceID: service.id,
                                        values: { (draft.fields, draft.secrets.filter { !$0.value.isEmpty }) }) { text.wrappedValue = $0 }
                    }
                }
            } else {
                TextField(title, text: text, prompt: Text(field.placeholder ?? field.defaultValue ?? ""))
            }
        }
    }

    private func save() {
        let settings = model.settings
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        var profile: TranslationProfile
        if let id = draft.profileID, let index = settings.translationProfiles.firstIndex(where: { $0.id == id }) {
            settings.translationProfiles[index].name = name
            settings.translationProfiles[index].fields = draft.fields
            profile = settings.translationProfiles[index]
        } else {
            profile = TranslationProfile(name: name, serviceID: service.id, fields: draft.fields)
            settings.translationProfiles.append(profile)
        }
        for field in service.secretFields {
            try? TranslationProfiles.recordSecret(draft.secrets[field.option] ?? "", option: field.option, in: profile,
                                                  secrets: actions.secrets)
        }
        // The configuration in use takes effect at once.
        if profile.id == actions.selectedID { actions.use(profile) }
        dismiss()
    }
}

/// Icon and title at the top of the configuration sheets, as at the top of a System Settings pane.
private struct ProfileSheetHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(1)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding([.horizontal, .top], 20)
        .padding(.bottom, 4)
    }
}
