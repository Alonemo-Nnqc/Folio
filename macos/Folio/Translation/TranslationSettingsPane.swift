import FolioAgent
import FolioTranslate
import SwiftUI
import Translation

/// 设置 ▸ 翻译 (TRANS-02/03): the engine, the service and the default options.
struct TranslationSettingsPane: View {
    let model: AppModel

    var body: some View {
        Form {
            ServiceSection(model: model)
            OptionsSection(settings: model.settings)
            SelectionTranslationSection(model: model)
            EngineSection(coordinator: model.translations)
        }
        .formStyle(.grouped)
        // No caret in the first text field just for opening the page.
        .task {
            try? await Task.sleep(for: .milliseconds(80))
            if let window = NSApp.keyWindow, window.firstResponder is NSTextView { window.makeFirstResponder(nil) }
        }
    }

    static func abbreviatedPath(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}

/// "翻译全文…": confirm service, languages and outputs for this run (they become the new defaults).
struct TranslateSheet: View {
    let model: AppModel
    let fileId: String
    @Environment(\.sheetDismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("翻译全文").font(.headline)
                if let file = model.snapshot.files[fileId] {
                    Text(model.snapshot.items[file.itemId]?.title ?? file.fileName)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding([.horizontal, .top], 20)
            Form {
                ServiceSection(model: model, compact: true)
                OptionsSection(settings: model.settings, compact: true)
            }
            .formStyle(.grouped)
            .frame(minHeight: 360)
            HStack {
                Text("保留版面、公式与图表，译文将作为附件加入该条目")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("开始翻译") {
                    dismiss()
                    model.translations.start(fileId: fileId)
                }
                .keyboardShortcut(.defaultAction)
                .glassProminentButtonStyle()
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 520)
    }
}

/// The engine: built in, nothing to install; the logs; and the old pdf2zh_next engine, if it is still on disk.
private struct EngineSection: View {
    let coordinator: TranslationCoordinator
    @State private var legacySize: Int64?

    var body: some View {
        Section {
            LabeledContent("翻译日志") {
                Button("在 Finder 中显示") {
                    let logs = TranslationCoordinator.logsDirectory
                    try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(logs)
                }
            }
            if let legacySize {
                LabeledContent {
                    Button("删除…", role: .destructive, action: confirmRemove)
                } label: {
                    Text("旧版翻译组件（pdf2zh_next）")
                    Text("已不再使用，占用 \(ByteCountFormatter.string(fromByteCount: legacySize, countStyle: .file))")
                }
            }
        } header: {
            Text("翻译引擎")
        }
        .task(id: coordinator.legacyRevision) {
            legacySize = LegacyTranslator.exists ? await Task.detached { LegacyTranslator.size() }.value : nil
        }
    }

    private func confirmRemove() {
        let alert = NSAlert()
        alert.messageText = String(localized: "删除旧版翻译组件？")
        alert.informativeText = String(localized: "会删除早期版本下载的 Python、pdf2zh_next 和版面模型，翻译已改用内置引擎。已翻译好的 PDF 不受影响。")
        alert.addButton(withTitle: String(localized: "删除"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.buttons[0].hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { coordinator.removeLegacyEngine() }
    }
}

/// The service picker and the fields the chosen service needs. Secrets go to the Keychain.
struct ServiceSection: View {
    let model: AppModel
    var compact = false
    @State private var showAdvanced = false
    @State private var appleStatus: AppleSystemTranslator.Availability?
    @State private var appleDownloadRequested = false
    @State private var configured: Set<String> = []

    /// "OpenAI 兼容接口 · 老李、DeepSeek": the service and its saved configurations.
    private func label(for service: TranslationService) -> String {
        let names = model.settings.translationProfiles.filter { $0.serviceID == service.id }.map(\.name)
        guard configured.contains(service.id), !names.isEmpty else { return service.displayName }
        return service.displayName + " · " + names.prefix(3).joined(separator: "、") + (names.count > 3 ? "…" : "")
    }

    /// Services with something entered (fields, keys, saved configurations), and agents found on this Mac.
    private func findConfigured() async -> Set<String> {
        let result = ServiceAvailability.configured(settings: model.settings, secrets: model.translations.secrets)
        return result.union(await ServiceAvailability.agents())
    }

    var body: some View {
        @Bindable var settings = model.settings
        let service = TranslationServiceCatalog.service(id: settings.translationService)
        Section {
            Picker(selection: $settings.translationService) {
                ForEach(groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.services) { Text(label(for: $0)).tag($0.id) }
                    }
                }
            } label: {
                Label {
                    Text("翻译服务")
                    if let note = service?.note { Text(note) }
                } icon: {
                    if let service { ServiceIcon(service: service) }
                }
            }
            .task(id: "\(settings.translationProfiles.count)-\(settings.translationFields.count)-\(settings.translationService)") {
                configured = await findConfigured()
            }
            if let service {
                if TranslationProfiles.supportsProfiles(service) { TranslationProfileRow(model: model, service: service) }
                // Rows are rebuilt when another configuration is chosen, so key fields reload from the Keychain.
                let profileID = settings.selectedTranslationProfiles[service.id] ?? ""
                ForEach(service.fields.filter { !$0.isAdvanced }) { FieldRow(model: model, serviceID: service.id, field: $0).id("\($0.id)-\(profileID)") }
                ReasoningRow(settings: settings, serviceID: service.id)
                if service.id == TranslationServiceCatalog.appleServiceID { appleRow }
                if hasStatus(service) {
                    ServiceStatusRow(model: model, service: service, canTest: !compact).id("\(service.id)-\(profileID)")
                }
                let advanced = service.fields.filter { $0.isAdvanced && !ReasoningEffort.managedOptions.contains($0.option) }
                if !compact, !advanced.isEmpty {
                    DisclosureGroup("高级", isExpanded: $showAdvanced) {
                        ForEach(advanced) { FieldRow(model: model, serviceID: service.id, field: $0).id("\($0.id)-\(profileID)") }
                    }
                }
            }
        }
        .task(id: "\(settings.translationService)-\(settings.translationOptions.langIn)-\(settings.translationOptions.langOut)") {
            guard settings.translationService == TranslationServiceCatalog.appleServiceID else { return }
            appleStatus = await AppleSystemTranslator.availability(from: settings.translationOptions.langIn,
                                                                   to: settings.translationOptions.langOut)
        }
        .background {
            if #available(macOS 15, *) {
                AppleLanguageDownloader(requested: $appleDownloadRequested, from: settings.translationOptions.langIn,
                                        to: settings.translationOptions.langOut) {
                    appleStatus = await AppleSystemTranslator.availability(from: settings.translationOptions.langIn,
                                                                           to: settings.translationOptions.langOut)
                }
            }
        }
    }

    /// An agent's row says whether it is installed, so the sheet has it too; a test needs the whole page.
    private func hasStatus(_ service: TranslationService) -> Bool {
        if case .agent = service.backend { return true }
        return !compact && service.category != .free
    }

    @ViewBuilder
    private var appleRow: some View {
        switch appleStatus {
        case .installed:
            Label("语言包已就绪，可以离线翻译", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        case .needsDownload:
            LabeledContent("需要下载离线语言包") {
                Button("下载语言包…") { appleDownloadRequested = true }
            }
        case .unsupported:
            Label("Apple 系统翻译不支持这组语言", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
        case nil:
            ProgressView().controlSize(.small)
        }
    }

    private var groups: [(title: String, services: [TranslationService])] {
        let available = TranslationServiceCatalog.all.filter {
            $0.id != TranslationServiceCatalog.appleServiceID || AppleSystemTranslator.isSupportedOnThisSystem
        }
        // Services set up before (a key, an address, saved configurations) and agents on this Mac come first.
        // Agents not found here are left out (the one in use stays, so the picker can show it).
        let mine = available.filter { configured.contains($0.id) }
        let all = available.filter { !configured.contains($0.id) }
        let current = model.settings.translationService
        return [(String(localized: "我的服务"), mine),
                (String(localized: "免费"), all.filter { $0.category == .free }),
                (String(localized: "本机"), all.filter { $0.category == .local || ($0.category == .agent && $0.id == current) }),
                (String(localized: "大模型 API"), all.filter { $0.category == .llm }),
                (String(localized: "机器翻译 API"), all.filter { $0.category == .machine })].filter { !$0.services.isEmpty }
    }
}

/// What kind of service this is, as a plain system symbol in the label's colour.
private struct ServiceIcon: View {
    let service: TranslationService

    private var symbol: String {
        if service.id == TranslationServiceCatalog.appleServiceID { return "apple.logo" }
        switch service.category {
        case .free: return "globe"
        case .local: return "desktopcomputer"
        case .agent: return "terminal"
        case .llm: return "sparkles"
        case .machine: return "character.book.closed"
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}

/// Where the service stands: the agent found on this Mac and its version, and what a test with one sentence says.
private struct ServiceStatusRow: View {
    let model: AppModel
    let service: TranslationService
    var canTest = true
    @State private var testing = false
    @State private var outcome: TranslationServiceTest.Outcome?
    @State private var location: URL??
    @State private var version: String?

    private var agent: LocalAgent? {
        if case .agent(let agent) = service.backend { return agent }
        return nil
    }

    var body: some View {
        LabeledContent {
            if canTest {
                Button(testing ? String(localized: "测试中…") : String(localized: "测试")) { test() }
                    .disabled(testing || (agent != nil && location == .some(nil)))
                    .accessibilityIdentifier("translationServiceTest")
            }
        } label: {
            status
        }
        .task(id: pathValue) {
            guard let agent else { return }
            let path = pathValue
            version = nil
            let found = await Task.detached { agent.locate(customPath: path) }.value
            location = .some(found)
            if let found { version = await Task.detached { agent.version(at: found) }.value }
        }
    }

    @ViewBuilder
    private var status: some View {
        if testing {
            Label {
                Text("正在翻译一句话…")
            } icon: {
                ProgressView().controlSize(.small)
            }
            .foregroundStyle(.secondary)
        } else if let outcome {
            Label {
                Text(outcome.message).textSelection(.enabled)
            } icon: {
                Image(systemName: outcome.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(outcome.succeeded ? Color.green : Color.orange)
            }
        } else if agent != nil {
            switch location {
            case .some(.some(let url)):
                Label {
                    Text(found(url))
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .foregroundStyle(.secondary)
            case .some(.none):
                Label {
                    Text("没有在这台 Mac 上找到 \(agent?.command ?? "")，请先安装并登录")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            case .none:
                ProgressView().controlSize(.small)
            }
        } else {
            Text("测试服务是否可用").foregroundStyle(.secondary)
        }
    }

    private func found(_ url: URL) -> String {
        let path = TranslationSettingsPane.abbreviatedPath(url.path)
        return version.map { String(localized: "已找到 \(path)（\($0)）") } ?? String(localized: "已找到 \(path)")
    }

    private var pathValue: String {
        service.fields.first { $0.option.hasSuffix("-path") }.flatMap { model.settings.translationFields[service.id]?[$0.option] } ?? ""
    }

    private func test() {
        testing = true
        outcome = nil
        let fields = model.settings.translationFields[service.id] ?? [:]
        let secrets = (try? model.translations.secrets.secrets(for: service)) ?? [:]
        let language = model.settings.translationOptions.langOut
        let id = service.id
        Task {
            outcome = await TranslationServiceTest.run(serviceID: id, fields: fields, secrets: secrets, language: language)
            testing = false
        }
    }
}

private struct FieldRow: View {
    let model: AppModel
    let serviceID: String
    let field: TranslationServiceField
    @State private var secret = ""
    @State private var loaded = false
    /// The key as stored, so loading it is not mistaken for an edit (which would also copy it into the
    /// configuration in use).
    @State private var stored = ""

    var body: some View {
        Group {
            switch field.kind {
            case .secret:
                SecureField(title, text: $secret, prompt: Text(field.placeholder ?? String(localized: "未填写")))
                    .onSubmit(saveSecret)
                    .onChange(of: secret) { saveSecret() }
            case .toggle:
                Toggle(title, isOn: Binding(get: { value == "true" }, set: { setValue($0 ? "true" : "") }))
            default:
                if ModelListFetcher.supports(serviceID: serviceID, modelOption: field.option) {
                    LabeledContent(title) {
                        ModelListButton(model: model, serviceID: serviceID, current: value,
                                        placeholder: field.defaultValue ?? field.placeholder ?? "") { setValue($0) }
                    }
                } else {
                    TextField(title, text: Binding(get: { value }, set: { setValue($0) }),
                              prompt: Text(field.placeholder ?? field.defaultValue ?? ""))
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: serviceID) { loaded = false; load() }
    }

    private var title: String { field.isRequired ? field.title : String(localized: "\(field.title)（选填）") }

    private var value: String { model.settings.translationFields[serviceID]?[field.option] ?? "" }

    private func setValue(_ newValue: String) {
        var fields = model.settings.translationFields[serviceID] ?? [:]
        fields[field.option] = newValue.isEmpty ? nil : newValue
        model.settings.translationFields[serviceID] = fields
    }

    private func load() {
        guard field.isSecret, !loaded else { return }
        loaded = true
        stored = (try? model.translations.secrets.get(serviceID: serviceID, option: field.option)) ?? nil ?? ""
        secret = stored
    }

    private func saveSecret() {
        guard loaded, secret != stored else { return }
        stored = secret
        let store = model.translations.secrets
        if secret.isEmpty {
            try? store.delete(serviceID: serviceID, option: field.option)
        } else {
            try? store.set(secret, serviceID: serviceID, option: field.option)
        }
        // The configuration in use keeps the same key.
        if let id = model.settings.selectedTranslationProfiles[serviceID],
           let profile = model.settings.translationProfiles.first(where: { $0.id == id }) {
            try? TranslationProfiles.recordSecret(secret, option: field.option, in: profile, secrets: store)
        }
    }
}

private struct OptionsSection: View {
    @Bindable var settings: AppSettings
    var compact = false

    var body: some View {
        if compact {
            Section("选项") {
                languageRows
                outputRows
                tablesToggle
            }
        } else {
            Section("语言") { languageRows }
            Section("输出") { outputRows }
            Section("翻译内容") {
                tablesToggle
                Toggle(isOn: $settings.translationOptions.translateReferences) {
                    Text("翻译参考文献")
                }
                LabeledContent {
                    HStack {
                        Text(settings.translationOptions.glossaryFile?.lastPathComponent ?? String(localized: "未选择"))
                            .foregroundStyle(.secondary)
                        if settings.translationOptions.glossaryFile != nil {
                            Button("清除") { settings.translationOptions.glossaryFile = nil }
                        }
                        Button("选择…", action: chooseGlossary)
                    }
                } label: {
                    Text("术语表（选填）")
                    Text("CSV：原文, 译文")
                }
            }
            Section("速度") {
                Picker(selection: Binding(get: { settings.translationOptions.concurrency ?? 0 },
                                          set: { settings.translationOptions.concurrency = $0 == 0 ? nil : $0 })) {
                    Text("自动").tag(0)
                    ForEach([1, 2, 4, 8, 12, 16], id: \.self) { Text("\($0)").tag($0) }
                } label: {
                    Text("同时请求数")
                    Text("遇到限流时调小")
                }
                Toggle(isOn: $settings.translationOptions.ignoreCache) {
                    Text("重新翻译（不使用缓存）")
                }
            }
        }
    }

    @ViewBuilder
    private var languageRows: some View {
        Picker("原文语言", selection: $settings.translationOptions.langIn) {
            ForEach(TranslationOptions.commonLanguages, id: \.code) { Text($0.name).tag($0.code) }
        }
        Picker("译文语言", selection: $settings.translationOptions.langOut) {
            ForEach(TranslationOptions.commonLanguages, id: \.code) { Text($0.name).tag($0.code) }
        }
    }

    @ViewBuilder
    private var outputRows: some View {
        Picker("生成", selection: $settings.translationOptions.outputs) {
            Text("纯译文和双语对照").tag(TranslationOptions.Outputs.both)
            Text("仅纯译文").tag(TranslationOptions.Outputs.mono)
            Text("仅双语对照").tag(TranslationOptions.Outputs.dual)
        }
        if settings.translationOptions.outputs != .mono {
            Picker("双语排版", selection: $settings.translationOptions.dualLayout) {
                Text("原文与译文左右并排").tag(TranslationOptions.DualLayout.sideBySide)
                Text("原文页与译文页交替").tag(TranslationOptions.DualLayout.alternatingPages)
            }
        }
        if !compact {
            Picker(selection: $settings.translationOptions.duplicates) {
                Text("保留两者").tag(TranslationOptions.Duplicates.keepBoth)
                Text("替换旧的译文").tag(TranslationOptions.Duplicates.replace)
            } label: {
                Text("再次翻译")
                Text("同一服务与模型重复翻译时")
            }
        }
        TextField("页码范围（选填）", text: Binding(get: { settings.translationOptions.pages ?? "" },
                                            set: { settings.translationOptions.pages = $0.isEmpty ? nil : $0 }),
                  prompt: Text("全部，例如 1-3,5"))
    }

    private var tablesToggle: some View {
        Toggle(isOn: $settings.translationOptions.translateTables) {
            Text("翻译表格")
        }
    }

    private func chooseGlossary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = String(localized: "选择术语表 CSV（两列：原文, 译文）")
        if panel.runModal() == .OK { settings.translationOptions.glossaryFile = panel.url }
    }
}

/// The model chosen, in the same dress as the pop-up buttons around it. Opens a searchable list of the models the service
/// offers, fetched with the key and address entered above; a name typed in the search field can be used as it is.
struct ModelListButton: View {
    let model: AppModel
    let serviceID: String
    /// The model chosen now ("" = the service's default, shown as `placeholder`).
    var current: String = ""
    var placeholder: String = ""
    /// The values to query with (a saved configuration); nil: the service's current values.
    var values: (() -> (fields: [String: String], secrets: [String: String]))?
    let onPick: (String) -> Void
    @State private var showing = false
    @State private var loading = false
    @State private var models: [String] = []
    @State private var error: String?

    var body: some View {
        Button {
            showing = true
            Task { await load() }
        } label: {
            HStack(spacing: 8) {
                Text(current.isEmpty ? (placeholder.isEmpty ? String(localized: "默认") : placeholder) : current)
                    .foregroundStyle(current.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Color.primary.opacity(0.1), in: Circle())
                    .padding(.trailing, 3.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("选择模型")
        .accessibilityLabel(String(localized: "选择模型"))
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ModelPickerPanel(current: current, models: models, loading: loading, error: error,
                             reload: { Task { await load() } }, pick: pick)
        }
        .onAppear {
            guard UserDefaults.standard.bool(forKey: "FolioPreviewModelPicker"), !showing else { return }
            showing = true
            Task { await load() }
        }
    }

    private func pick(_ name: String) {
        onPick(name.trimmingCharacters(in: .whitespaces))
        showing = false
    }

    private func load() async {
        guard let service = TranslationServiceCatalog.service(id: serviceID) else { return }
        let current = values?() ?? (fields: model.settings.translationFields[serviceID] ?? [:],
                                     secrets: (try? model.translations.secrets.secrets(for: service)) ?? [:])
        // The last list at once; a fresh one follows.
        if models.isEmpty, let remembered = ModelListFetcher.rememberedModels(serviceID: serviceID, fieldValues: current.fields) {
            models = remembered
        }
        loading = true
        error = nil
        defer { loading = false }
        do {
            models = try await ModelListFetcher.fetch(serviceID: serviceID, fieldValues: current.fields, secrets: current.secrets)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// What the model button opens: one field to search or type a name, the models by family, and what to do at the bottom.
private struct ModelPickerPanel: View {
    let current: String
    let models: [String]
    let loading: Bool
    let error: String?
    let reload: () -> Void
    let pick: (String) -> Void
    @State private var filter = UserDefaults.standard.string(forKey: "FolioPreviewModelFilter") ?? ""
    @State private var hovered: String?
    @FocusState private var searching: Bool

    private var query: String { filter.trimmingCharacters(in: .whitespaces) }

    private var matches: [String] {
        query.isEmpty ? models : models.filter { $0.lowercased().contains(query.lowercased()) }
    }

    /// What Return picks: the name exactly as typed if the list has it, else the first match, else the name as typed.
    private var returnTarget: String? {
        guard !query.isEmpty else { return nil }
        return models.contains(query) ? query : matches.first ?? query
    }

    /// "gemini-3.8-flash" and "gemini-2.5-pro" under gemini; "openai/gpt-5" under openai. Only when that helps.
    private var groups: [(name: String, models: [String])] {
        guard query.isEmpty, models.count > 6 else { return [("", matches)] }
        var order: [String] = []
        var byFamily: [String: [String]] = [:]
        for model in matches {
            let family = model.split(whereSeparator: { "/-:".contains($0) }).first.map(String.init) ?? model
            if byFamily[family] == nil { order.append(family) }
            byFamily[family, default: []].append(model)
        }
        return order.count > 1 ? order.map { ($0, byFamily[$0]!) } : [("", matches)]
    }

    var body: some View {
        VStack(spacing: 0) {
            PopoverSearchField(prompt: String(localized: "搜索或输入模型名称"), text: $filter, onSubmit: submit)
                .focused($searching)
                .padding(10)
            Divider()
            content
                .frame(height: 260)
            Divider()
            footer
        }
        .frame(width: 360)
        .onAppear { searching = true }
    }

    @ViewBuilder
    private var content: some View {
        if loading && models.isEmpty {
            ProgressView("正在获取…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if let error, models.isEmpty {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(10)
                    }
                    ForEach(groups, id: \.name) { group in
                        if !group.name.isEmpty {
                            Text(group.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.top, 8)
                                .padding(.bottom, 2)
                        }
                        ForEach(group.models, id: \.self) { row($0) }
                    }
                    if !query.isEmpty, !models.contains(query) {
                        row(query, title: String(localized: "使用“\(query)”"), symbol: "text.cursor")
                    }
                    if models.isEmpty, error == nil, query.isEmpty {
                        Text("这个服务没有提供模型列表，请直接输入模型名称")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(10)
                    }
                }
                .padding(6)
            }
        }
    }

    private func row(_ name: String, title: String? = nil, symbol: String? = nil) -> some View {
        Button {
            pick(name)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol ?? "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(symbol == nil ? Color.accentColor : Color.secondary)
                    .opacity(symbol != nil || name == current ? 1 : 0)
                    .frame(width: 14)
                Text(title ?? name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if name == returnTarget {
                    Image(systemName: "return")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(hovered == name ? Color.primary.opacity(0.1) : name == returnTarget ? Color.primary.opacity(0.06) : .clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = name } else if hovered == name { hovered = nil }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if loading {
                // The list has its own spinner until there is a list.
                if !models.isEmpty { ProgressView().controlSize(.small) }
            } else {
                Button(action: reload) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("重新获取")
                .accessibilityLabel(String(localized: "重新获取"))
            }
            if !models.isEmpty {
                Text(query.isEmpty ? String(localized: "\(models.count) 个模型") : String(localized: "\(matches.count) / \(models.count) 个模型"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !current.isEmpty {
                Button("恢复默认") { pick("") }
                    .buttonStyle(.borderless)
                    .font(.callout)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func submit() {
        if let returnTarget { pick(returnTarget) }
    }
}

/// 推理强度: choices that depend on the service and the chosen model (TRANS-03).
private struct ReasoningRow: View {
    @Bindable var settings: AppSettings
    let serviceID: String

    var body: some View {
        ReasoningPicker(serviceID: serviceID, fields: Binding(get: { settings.translationFields[serviceID] ?? [:] },
                                                               set: { settings.translationFields[serviceID] = $0 }))
    }
}

/// The thinking levels the service and model accept: a segmented control when they fit, otherwise a menu.
struct ReasoningPicker: View {
    let serviceID: String
    @Binding var fields: [String: String]

    private var selection: Binding<String> {
        Binding(get: { ReasoningEffort.current(serviceID: serviceID, fields: fields) ?? "" },
                set: { value in
                    var updated = fields
                    ReasoningEffort.set(value, serviceID: serviceID, fields: &updated)
                    fields = updated
                })
    }

    var body: some View {
        switch ReasoningEffort.support(serviceID: serviceID, fields: fields) {
        case .none:
            EmptyView()
        case .unsupportedModel:
            LabeledContent("思考程度") {
                Text("当前模型不支持").foregroundStyle(.secondary)
            }
            .help("所选模型不是推理模型，不会发送推理强度参数")
        case .decidedByModel(let level):
            LabeledContent {
                Text(level).foregroundStyle(.secondary)
            } label: {
                Text("思考程度")
                Text("由所选模型决定")
            }
        case let .choices(choices, _):
            if choices.count > 5 {
                Picker(selection: selection) {
                    ForEach(choices) { Text($0.title).tag($0.value) }
                } label: {
                    Text("思考程度")
                }
            } else {
                Picker(selection: selection) {
                    ForEach(choices) { Text($0.title).tag($0.value) }
                } label: {
                    Text("思考程度")
                }
                .pickerStyle(.segmented)
            }
        }
    }
}

/// Shows the system prompt that downloads Apple's offline language models for a language pair.
@available(macOS 15, *)
private struct AppleLanguageDownloader: View {
    @Binding var requested: Bool
    let from: String
    let to: String
    let finished: () async -> Void
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .onChange(of: requested) {
                guard requested else { return }
                configuration = TranslationSession.Configuration(source: AppleSystemTranslator.language(forCode: from),
                                                                 target: AppleSystemTranslator.language(forCode: to))
            }
            .translationTask(configuration) { session in
                // The session is only used inside this closure, on the main actor.
                nonisolated(unsafe) let session = session
                try? await session.prepareTranslation()
                requested = false
                await finished()
            }
    }
}

/// 划词翻译 (TRANS-10): a selection in the reader translated in a popover, by its own service.
private struct SelectionTranslationSection: View {
    let model: AppModel
    @State private var services: [TranslationService] = []

    var body: some View {
        @Bindable var settings = model.settings
        Section {
            Toggle("划词翻译", isOn: $settings.selectionTranslationEnabled)
            if settings.selectionTranslationEnabled {
                Picker("触发方式", selection: $settings.selectionTranslationTrigger) {
                    ForEach(AppSettings.SelectionTrigger.allCases) { Text($0.title).tag($0) }
                }
                Picker("翻译服务", selection: $settings.selectionTranslationService) {
                    Text("与全文翻译相同").tag("")
                    Divider()
                    ForEach(choices) { Text($0.displayName).tag($0.id) }
                }
                LabeledContent("快捷键") {
                    ShortcutRecorder(shortcut: $settings.selectionTranslationShortcut, defaultShortcut: .defaultSelectionTranslation)
                }
            }
        } header: {
            Text("划词翻译")
        }
        .task(id: "\(settings.translationProfiles.count)-\(settings.translationFields.count)") {
            services = ServiceAvailability.ready(settings: settings, secrets: model.translations.secrets, agents: ServiceAvailability.knownAgents)
            let agents = await ServiceAvailability.agents()
            services = ServiceAvailability.ready(settings: settings, secrets: model.translations.secrets, agents: agents)
        }
    }

    /// Ready services, plus the one chosen before even if it is not ready now (so the picker can show it).
    private var choices: [TranslationService] {
        let chosen = model.settings.selectionTranslationService
        guard !chosen.isEmpty, !services.contains(where: { $0.id == chosen }), let service = TranslationServiceCatalog.service(id: chosen) else { return services }
        return services + [service]
    }
}
