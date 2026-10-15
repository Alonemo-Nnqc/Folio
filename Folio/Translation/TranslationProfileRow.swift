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
            Text(profiles.isEmpty ? "存为配置…" : "编辑配置…").tag(Self.editTag)
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
        model.toasts.show("已切换到「\(profile.name)」", systemImage: "arrow.left.arrow.right")
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
            model.toasts.show("无法读取「\(profile.name)」的 API Key：\(error.localizedDescription)", systemImage: "exclamationmark.triangle")
        }
    }

    func add(copying source: TranslationProfile? = nil) -> TranslationProfile {
        var profile = TranslationProfile(name: uniqueName(source.map { "\($0.name) 副本" } ?? "新配置"), serviceID: service.id,
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

    private func uniqueName(_ base: String) -> String {
        let taken = Set(all.map(\.name))
        guard taken.contains(base) else { return base }
        return (2...).lazy.map { "\(base) \($0)" }.first { !taken.contains($0) }!
    }
}

/// "编辑配置…": the service's configurations in a list with + and −, the selected one's name, address, key and model
/// beside it — the way macOS lists accounts. Changes are saved as they are typed; "完成" puts the configuration
/// in use back into effect.
struct TranslationProfilesEditor: View {
    let model: AppModel
    let service: TranslationService
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?
    @State private var confirmingDelete: TranslationProfile?

    private var actions: TranslationProfileActions { TranslationProfileActions(model: model, service: service) }

    var body: some View {
        let profiles = actions.all
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach(profiles) { profile in
                            HStack {
                                Text(profile.name).lineLimit(1)
                                Spacer()
                                if profile.id == actions.selectedID {
                                    Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                        .help("正在使用")
                                }
                            }
                            .tag(profile.id)
                        }
                    }
                    .listStyle(.bordered(alternatesRowBackgrounds: false))
                    listButtons(profiles)
                }
                .frame(width: 200)
                .padding([.leading, .vertical], 16)

                if let id = selection, let profile = profiles.first(where: { $0.id == id }) {
                    ProfileForm(model: model, service: service, profileID: profile.id,
                                inUse: profile.id == actions.selectedID) { actions.use(profile) }
                        .id(profile.id)
                } else {
                    ContentUnavailableView("没有配置", systemImage: "server.rack",
                                           description: Text("点 + 添加一个服务商的 Base URL、API Key 和模型"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                Text("\(service.displayName) 的配置").foregroundStyle(.secondary)
                Spacer()
                Button("完成") { finish() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 640, height: 420)
        .onAppear {
            // Values typed before configurations existed become the first one, so nothing is lost.
            actions.keepUnsavedValues()
            selection = actions.selectedID ?? actions.all.first?.id
        }
        .confirmationDialog("删除配置「\(confirmingDelete?.name ?? "")」？", isPresented: Binding(
            get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } })) {
            Button("删除", role: .destructive) {
                guard let profile = confirmingDelete else { return }
                let index = profiles.firstIndex { $0.id == profile.id } ?? 0
                actions.remove(profile)
                let rest = actions.all
                selection = rest.isEmpty ? nil : rest[min(index, rest.count - 1)].id
            }
        } message: {
            Text("它保存的 Base URL、模型和 API Key 都会删除")
        }
    }

    /// + / − / ⋯ under the list, as in macOS's account and network lists.
    private func listButtons(_ profiles: [TranslationProfile]) -> some View {
        HStack(spacing: 0) {
            Button {
                selection = actions.add().id
            } label: {
                Image(systemName: "plus").frame(width: 24, height: 20)
            }
            .help("添加配置")
            Divider().frame(height: 14)
            Button {
                confirmingDelete = profiles.first { $0.id == selection }
            } label: {
                Image(systemName: "minus").frame(width: 24, height: 20)
            }
            .disabled(selection == nil)
            .help("删除配置")
            Divider().frame(height: 14)
            Menu {
                Button("复制配置") {
                    if let source = profiles.first(where: { $0.id == selection }) { selection = actions.add(copying: source).id }
                }
                .disabled(selection == nil)
                Button("设为当前使用") {
                    if let profile = profiles.first(where: { $0.id == selection }) { actions.use(profile) }
                }
                .disabled(selection == nil || selection == actions.selectedID)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多")
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 4)
        .frame(height: 24)
        .background(.quaternary.opacity(0.5))
        .overlay(alignment: .top) { Divider() }
    }

    private func finish() {
        // The configuration in use may have been edited: put its values back into effect.
        if let id = actions.selectedID, let profile = actions.all.first(where: { $0.id == id }) { actions.use(profile) }
        dismiss()
    }
}

/// One configuration's name and fields, saved as they are typed.
private struct ProfileForm: View {
    let model: AppModel
    let service: TranslationService
    let profileID: String
    let inUse: Bool
    let onUse: () -> Void
    @State private var secrets: [String: String] = [:]
    @State private var showAdvanced = false

    private var settings: AppSettings { model.settings }
    private var index: Int? { settings.translationProfiles.firstIndex { $0.id == profileID } }
    private var profile: TranslationProfile? { index.map { settings.translationProfiles[$0] } }

    var body: some View {
        Form {
            Section {
                TextField("名称", text: Binding(get: { profile?.name ?? "" }, set: { name in
                    if let index, !name.trimmingCharacters(in: .whitespaces).isEmpty { settings.translationProfiles[index].name = name }
                }))
                LabeledContent("状态") {
                    if inUse {
                        Label("正在使用", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("设为当前使用", action: onUse)
                    }
                }
            }
            Section {
                ForEach(service.fields.filter { !$0.isAdvanced }) { row(for: $0) }
                let advanced = service.fields.filter(\.isAdvanced)
                if !advanced.isEmpty {
                    DisclosureGroup("高级", isExpanded: $showAdvanced) { ForEach(advanced) { row(for: $0) } }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadSecrets)
    }

    @ViewBuilder
    private func row(for field: TranslationServiceField) -> some View {
        let title = field.isRequired ? field.title : "\(field.title)（选填）"
        switch field.kind {
        case .secret:
            SecureField(title, text: Binding(get: { secrets[field.option] ?? "" }, set: { value in
                secrets[field.option] = value
                if let profile { try? TranslationProfiles.recordSecret(value, option: field.option, in: profile, secrets: model.translations.secrets) }
            }), prompt: Text(field.placeholder ?? "未填写"))
        case .toggle:
            Toggle(title, isOn: Binding(get: { value(field) == "true" }, set: { setValue($0 ? "true" : "", field) }))
        default:
            if ModelListFetcher.supports(serviceID: service.id, modelOption: field.option) {
                LabeledContent(title) {
                    HStack(spacing: 6) {
                        TextField(title, text: Binding(get: { value(field) }, set: { setValue($0, field) }),
                                  prompt: Text(field.placeholder ?? field.defaultValue ?? ""))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                        ModelListButton(model: model, serviceID: service.id,
                                        values: { (profile?.fields ?? [:], secrets.filter { !$0.value.isEmpty }) }) { setValue($0, field) }
                    }
                }
            } else {
                TextField(title, text: Binding(get: { value(field) }, set: { setValue($0, field) }),
                          prompt: Text(field.placeholder ?? field.defaultValue ?? ""))
            }
        }
    }

    private func value(_ field: TranslationServiceField) -> String { profile?.fields[field.option] ?? "" }

    private func setValue(_ value: String, _ field: TranslationServiceField) {
        guard let index else { return }
        settings.translationProfiles[index].fields[field.option] = value.isEmpty ? nil : value
    }

    private func loadSecrets() {
        guard let profile else { return }
        for field in service.secretFields {
            secrets[field.option] = (try? model.translations.secrets.get(serviceID: profile.secretOwner, option: field.option)) ?? nil
        }
    }
}
