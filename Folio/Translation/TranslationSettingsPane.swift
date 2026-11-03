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
            EngineSection(coordinator: model.translations)
        }
        .formStyle(.grouped)
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
                Text("保留原文排版、公式和图表，翻译时就可以对照阅读\n译文会作为新文件加入该条目")
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
        } footer: {
            Text("Folio 内置的翻译引擎直接解析 PDF 版面并按原样排入译文，图表内文字和公式保持原样，无需下载任何组件")
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

    var body: some View {
        @Bindable var settings = model.settings
        let service = TranslationServiceCatalog.service(id: settings.translationService)
        Section {
            Picker("翻译服务", selection: $settings.translationService) {
                ForEach(groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.services) { Text($0.displayName).tag($0.id) }
                    }
                }
            }
            if let note = service?.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if let service {
                if TranslationProfiles.supportsProfiles(service) { TranslationProfileRow(model: model, service: service) }
                // Rows are rebuilt when another configuration is chosen, so key fields reload from the Keychain.
                let profileID = settings.selectedTranslationProfiles[service.id] ?? ""
                ForEach(service.fields.filter { !$0.isAdvanced }) { FieldRow(model: model, serviceID: service.id, field: $0).id("\($0.id)-\(profileID)") }
                ReasoningRow(settings: settings, serviceID: service.id)
                let advanced = service.fields.filter { $0.isAdvanced && !ReasoningEffort.managedOptions.contains($0.option) }
                if !compact, !advanced.isEmpty {
                    DisclosureGroup("高级", isExpanded: $showAdvanced) {
                        ForEach(advanced) { FieldRow(model: model, serviceID: service.id, field: $0).id("\($0.id)-\(profileID)") }
                    }
                }
                if service.id == TranslationServiceCatalog.appleServiceID { appleRow }
                if case .agent(let agent) = service.backend { AgentStatusRow(agent: agent, settings: settings, service: service) }
            }
        } header: {
            Text("翻译服务")
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
        let all = TranslationServiceCatalog.all.filter {
            $0.id != TranslationServiceCatalog.appleServiceID || AppleSystemTranslator.isSupportedOnThisSystem
        }
        return [(String(localized: "免费"), all.filter { $0.category == .free }),
                (String(localized: "本机"), all.filter { $0.category == .local }),
                (String(localized: "本机智能体（无需 Key）"), all.filter { $0.category == .agent }),
                (String(localized: "大模型 API"), all.filter { $0.category == .llm }),
                (String(localized: "机器翻译 API"), all.filter { $0.category == .machine })].filter { !$0.services.isEmpty }
    }
}

/// Whether the chosen agent is on this Mac, and where.
private struct AgentStatusRow: View {
    let agent: LocalAgent
    let settings: AppSettings
    let service: TranslationService
    @State private var location: URL??

    var body: some View {
        Group {
            switch location {
            case .some(.some(let url)):
                Label("已找到 \(TranslationSettingsPane.abbreviatedPath(url.path))", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            case .some(.none):
                Label("没有在这台 Mac 上找到 \(agent.command)，请先安装并登录", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            case .none:
                ProgressView().controlSize(.small)
            }
        }
        .task(id: pathValue) {
            let path = pathValue
            location = .some(await Task.detached { agent.locate(customPath: path) }.value)
        }
    }

    private var pathValue: String {
        service.fields.first { $0.option.hasSuffix("-path") }.flatMap { settings.translationFields[service.id]?[$0.option] } ?? ""
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
                        HStack(spacing: 6) {
                            TextField(title, text: Binding(get: { value }, set: { setValue($0) }),
                                      prompt: Text(field.placeholder ?? field.defaultValue ?? ""))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                            ModelListButton(model: model, serviceID: serviceID) { setValue($0) }
                        }
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
        Section {
            Picker("原文语言", selection: $settings.translationOptions.langIn) {
                ForEach(TranslationOptions.commonLanguages, id: \.code) { Text($0.name).tag($0.code) }
            }
            Picker("译文语言", selection: $settings.translationOptions.langOut) {
                ForEach(TranslationOptions.commonLanguages, id: \.code) { Text($0.name).tag($0.code) }
            }
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
            TextField("页码范围（选填）", text: Binding(get: { settings.translationOptions.pages ?? "" },
                                                set: { settings.translationOptions.pages = $0.isEmpty ? nil : $0 }),
                      prompt: Text("全部，例如 1-3,5"))
            Toggle("翻译表格", isOn: $settings.translationOptions.translateTables)
                .help("逐格翻译表格中的文字；数字和符号保持原样")
            if !compact {
                Toggle("翻译参考文献", isOn: $settings.translationOptions.translateReferences)
                    .help("默认保留参考文献列表的原文")
                LabeledContent("术语表（选填）") {
                    HStack {
                        Text(settings.translationOptions.glossaryFile?.lastPathComponent ?? String(localized: "未选择"))
                            .foregroundStyle(.secondary)
                        if settings.translationOptions.glossaryFile != nil {
                            Button("清除") { settings.translationOptions.glossaryFile = nil }
                        }
                        Button("选择…", action: chooseGlossary)
                    }
                }
                Picker("同时请求数", selection: Binding(get: { settings.translationOptions.concurrency ?? 0 },
                                                   set: { settings.translationOptions.concurrency = $0 == 0 ? nil : $0 })) {
                    Text("自动").tag(0)
                    ForEach([1, 2, 4, 8, 12, 16], id: \.self) { Text("\($0)").tag($0) }
                }
                .help("同时发出的翻译请求数。付费接口额度较高时调大可以更快；遇到限流时调小")
                Toggle("重新翻译（不使用缓存）", isOn: $settings.translationOptions.ignoreCache)
                    .help("默认会复用同一篇论文用同一服务翻译过的段落，重试时更快、更省")
            }
        } header: {
            Text(compact ? String(localized: "选项") : String(localized: "默认选项"))
        }
    }

    private func chooseGlossary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = String(localized: "选择术语表 CSV（两列：原文, 译文）")
        if panel.runModal() == .OK { settings.translationOptions.glossaryFile = panel.url }
    }
}

/// "获取模型列表": fetches the service's models with the key and address entered above and lets the
/// user pick one from a searchable list.
struct ModelListButton: View {
    let model: AppModel
    let serviceID: String
    /// The values to query with (a saved configuration); nil: the service's current values.
    var values: (() -> (fields: [String: String], secrets: [String: String]))?
    let onPick: (String) -> Void
    @State private var showing = false
    @State private var loading = false
    @State private var models: [String] = []
    @State private var error: String?
    @State private var filter = ""

    var body: some View {
        Button {
            showing = true
            Task { await load() }
        } label: {
            if loading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "list.bullet")
            }
        }
        .help("获取模型列表")
        .accessibilityLabel(String(localized: "获取模型列表"))
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("选择模型").font(.headline)
                    Spacer()
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("重新获取")
                    .disabled(loading)
                }
                if loading && models.isEmpty {
                    ProgressView("正在获取…").frame(maxWidth: .infinity, minHeight: 120)
                } else if let error {
                    ContentUnavailableView("无法获取模型列表", systemImage: "exclamationmark.triangle", description: Text(error))
                        .frame(minHeight: 160)
                } else {
                    PopoverSearchField(prompt: String(localized: "搜索模型"), text: $filter)
                    List(filtered, id: \.self) { name in
                        Button {
                            onPick(name)
                            showing = false
                        } label: {
                            Text(name).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                    // Let the popover's own glass show through, like a native menu.
                    .scrollContentBackground(.hidden)
                    .background(.clear)
                    .frame(height: 260)
                    Text("\(models.count) 个模型").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(width: 320)
        }
    }

    private var filtered: [String] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? models : models.filter { $0.lowercased().contains(q) }
    }

    private func load() async {
        guard let service = TranslationServiceCatalog.service(id: serviceID) else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let current = values?() ?? (fields: model.settings.translationFields[serviceID] ?? [:],
                                         secrets: (try? model.translations.secrets.secrets(for: service)) ?? [:])
            models = try await ModelListFetcher.fetch(serviceID: serviceID, fieldValues: current.fields, secrets: current.secrets)
        } catch {
            models = []
            self.error = error.localizedDescription
        }
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

/// The reasoning levels the service and model accept, as a segmented control beside the address, key and model.
struct ReasoningPicker: View {
    let serviceID: String
    @Binding var fields: [String: String]

    var body: some View {
        switch ReasoningEffort.support(serviceID: serviceID, fields: fields) {
        case .none:
            EmptyView()
        case .unsupportedModel:
            LabeledContent("推理强度") {
                Text("当前模型不支持").foregroundStyle(.secondary)
            }
            .help("所选模型不是推理模型，不会发送推理强度参数")
        case let .choices(choices, _):
            Picker("推理强度", selection: Binding(
                get: { ReasoningEffort.current(serviceID: serviceID, fields: fields) ?? "" },
                set: { value in
                    var updated = fields
                    ReasoningEffort.set(value, serviceID: serviceID, fields: &updated)
                    fields = updated
                })) {
                ForEach(choices) { Text($0.title).tag($0.value) }
            }
            .pickerStyle(.segmented)
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
