import FolioAgent
import FolioTranslate
import SwiftUI
import Translation

/// 设置 ▸ 翻译 (TRANS-02/03): the engine, the service and the default options.
struct TranslationSettingsPane: View {
    let model: AppModel

    var body: some View {
        Form {
            EngineSection(coordinator: model.translations, settings: model.settings)
            ServiceSection(model: model)
            OptionsSection(settings: model.settings)
            Section {
                Button("打开翻译日志文件夹") {
                    let logs = model.translations.installation.layout.logsDirectory
                    try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(logs)
                }
            }
        }
        .formStyle(.grouped)
    }
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
                Text("保留原文排版、公式和图表；译文会作为新文件加入该条目。")
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
                .buttonStyle(.glassProminent)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 520)
    }
}

private struct EngineSection: View {
    let coordinator: TranslationCoordinator
    @Bindable var settings: AppSettings
    @State private var usage: Int64 = 0
    @State private var searching = false
    /// The user's own pdf2zh_next: its version, or why it does not run.
    @State private var custom: Result<String, CustomError>?

    struct CustomError: Error { let message: String }

    var body: some View {
        Section {
            Toggle("使用自己安装的 pdf2zh_next", isOn: Binding(get: { usesOwn || searching },
                                                         set: { $0 ? findOwn() : (settings.translatorCustomPath = "") }))
                .disabled(searching)
            if searching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在查找 pdf2zh_next…").foregroundStyle(.secondary)
                }
            } else if usesOwn {
                ownRow
            } else {
                builtIn
            }
        } header: {
            Text("翻译组件")
        } footer: {
            Text("由 pdf2zh_next（BabelDOC，AGPL-3.0）完成保留排版的翻译。内置组件首次使用时下载，约 1.4 GB。")
        }
        .task(id: coordinator.engineRevision) { refresh() }
        .task(id: settings.translatorCustomPath) { await checkOwn() }
    }

    private var usesOwn: Bool { !settings.translatorCustomPath.isEmpty }

    @ViewBuilder
    private var ownRow: some View {
        LabeledContent {
            Button("更改…", action: chooseExecutable)
        } label: {
            switch custom {
            case .success(let version)?: Text("pdf2zh_next \(version)")
            case .failure?: Label("无法运行", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case nil: Text("pdf2zh_next")
            }
            Text(Self.abbreviated(settings.translatorCustomPath)).textSelection(.enabled)
        }
        if case .failure(let error)? = custom {
            Text(error.message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
        }
    }

    @ViewBuilder
    private var builtIn: some View {
        switch coordinator.installState {
        case .installing(let progress):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(progress.phase.title)
                    Spacer()
                    Button("取消安装") { coordinator.cancelInstall() }
                }
                ProgressView(value: progress.fractionCompleted)
                if let detail = progress.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        case .failed(let message):
            LabeledContent("安装失败") {
                Button("重试") { coordinator.install() }
            }
            Text(message).font(.caption).foregroundStyle(.red)
        case .idle:
            switch coordinator.installation.status() {
            case .installed(let installed, _):
                LabeledContent("内置组件 pdf2zh_next \(installed)") {
                    HStack {
                        Text(ByteCountFormatter.string(fromByteCount: usage, countStyle: .file)).foregroundStyle(.secondary)
                        Button("在 Finder 中显示") { NSWorkspace.shared.open(coordinator.installation.baseDirectory) }
                        Button("卸载…", role: .destructive, action: confirmUninstall)
                    }
                }
            case .notInstalled:
                LabeledContent("内置组件未安装") {
                    Button("下载并安装") { coordinator.install() }
                        .buttonStyle(.glassProminent)
                }
            case .broken(let reason):
                LabeledContent("内置组件已损坏") {
                    Button("重新安装") { coordinator.install() }
                }
                Text(reason).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func refresh() {
        let installation = coordinator.installation
        Task.detached { let size = installation.diskUsage(); await MainActor.run { usage = size } }
    }

    /// Runs the configured pdf2zh_next once to show its version (or why it cannot be used).
    private func checkOwn() async {
        custom = nil
        guard usesOwn else { return }
        do {
            custom = .success(try await coordinator.installation.customRuntime(executable: URL(filePath: settings.translatorCustomPath)).version)
        } catch {
            custom = .failure(CustomError(message: error.localizedDescription))
        }
    }

    /// First use: look for the user's pdf2zh_next and configure it; say so plainly when there is none.
    private func findOwn() {
        searching = true
        let installation = coordinator.installation
        Task {
            let found = await Task.detached {
                await TranslatorDiscovery.discover(installation: installation, pathFolders: ShellEnvironment.loginPATH())
            }.value
            searching = false
            if let found {
                settings.translatorCustomPath = found.executable.path
                AppDelegate.shared.model?.toasts.show("已找到 pdf2zh_next \(found.version)，翻译将使用它", systemImage: "checkmark.circle")
            } else {
                let alert = NSAlert()
                alert.messageText = "没有在这台 Mac 上找到 pdf2zh_next"
                alert.informativeText = "已查找终端的 PATH 以及 uv、pipx、conda、Homebrew 的安装位置。可以在终端运行 uv tool install pdf2zh-next 安装后再打开此开关，或手动选择它的位置。\n\n不开启时，Folio 使用内置的翻译组件。"
                alert.addButton(withTitle: "手动选择…")
                alert.addButton(withTitle: "好")
                if alert.runModal() == .alertFirstButtonReturn { chooseExecutable() }
            }
        }
    }

    private func confirmUninstall() {
        let alert = NSAlert()
        alert.messageText = "卸载翻译组件？"
        alert.informativeText = "会删除 Python、pdf2zh_next 和版面模型（\(ByteCountFormatter.string(fromByteCount: usage, countStyle: .file))）。已翻译好的 PDF 不受影响，之后需要时可以重新下载。"
        alert.addButton(withTitle: "卸载")
        alert.addButton(withTitle: "取消")
        alert.buttons[0].hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { coordinator.uninstall() }
    }

    /// Picks the file by hand; it is used only if it runs.
    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.message = "选择 pdf2zh_next 可执行文件"
        panel.prompt = "使用"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin")
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let installation = coordinator.installation
        Task {
            do {
                _ = try await installation.customRuntime(executable: url)
                settings.translatorCustomPath = url.path
            } catch {
                let alert = NSAlert()
                alert.messageText = "无法使用这个文件"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    static func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// The service picker and the fields the chosen service needs. Secrets go to the Keychain.
private struct ServiceSection: View {
    let model: AppModel
    var compact = false
    @State private var showAdvanced = false
    @State private var appleStatus: AppleSystemTranslator.Availability?
    @State private var appleDownload: TranslationSession.Configuration?

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
                ForEach(service.fields.filter { !$0.isAdvanced }) { FieldRow(model: model, serviceID: service.id, field: $0) }
                ReasoningRow(settings: settings, serviceID: service.id)
                let advanced = service.fields.filter { $0.isAdvanced && !ReasoningEffort.managedOptions.contains($0.option) }
                if !compact, !advanced.isEmpty {
                    DisclosureGroup("高级", isExpanded: $showAdvanced) {
                        ForEach(advanced) { FieldRow(model: model, serviceID: service.id, field: $0) }
                    }
                }
                if service.id == TranslationServiceCatalog.appleServiceID { appleRow }
            }
        } header: {
            Text("翻译服务")
        }
        .task(id: "\(settings.translationService)-\(settings.translationOptions.langIn)-\(settings.translationOptions.langOut)") {
            guard settings.translationService == TranslationServiceCatalog.appleServiceID else { return }
            appleStatus = await AppleSystemTranslator.availability(from: settings.translationOptions.langIn,
                                                                   to: settings.translationOptions.langOut)
        }
        .translationTask(appleDownload) { session in
            // Shows the system prompt that downloads the offline language models. The session is only
            // used inside this closure, on the main actor.
            nonisolated(unsafe) let session = session
            try? await session.prepareTranslation()
            appleStatus = await AppleSystemTranslator.availability(from: settings.translationOptions.langIn,
                                                                   to: settings.translationOptions.langOut)
        }
    }

    @ViewBuilder
    private var appleRow: some View {
        let options = model.settings.translationOptions
        switch appleStatus {
        case .installed:
            Label("语言包已就绪，可以离线翻译", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        case .needsDownload:
            LabeledContent("需要下载离线语言包") {
                Button("下载语言包…") {
                    appleDownload = TranslationSession.Configuration(source: AppleSystemTranslator.language(forCode: options.langIn),
                                                                     target: AppleSystemTranslator.language(forCode: options.langOut))
                }
            }
        case .unsupported:
            Label("Apple 系统翻译不支持这组语言", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
        case nil:
            ProgressView().controlSize(.small)
        }
    }

    private var groups: [(title: String, services: [TranslationService])] {
        let all = TranslationServiceCatalog.all
        return [("免费", all.filter { $0.isFree && !$0.isLocal }),
                ("本地 / 离线", all.filter(\.isLocal)),
                ("需要 API Key", all.filter { !$0.isFree && !$0.isLocal })].filter { !$0.services.isEmpty }
    }
}

private struct FieldRow: View {
    let model: AppModel
    let serviceID: String
    let field: TranslationServiceField
    @State private var secret = ""
    @State private var loaded = false

    var body: some View {
        Group {
            switch field.kind {
            case .secret:
                SecureField(title, text: $secret, prompt: Text(field.placeholder ?? "未填写"))
                    .onSubmit(saveSecret)
                    .onChange(of: secret) { saveSecret() }
            case .toggle:
                Toggle(title, isOn: Binding(get: { value == "true" }, set: { setValue($0 ? "true" : "") }))
            default:
                if ModelListFetcher.supports(serviceID: serviceID, modelOption: field.option) {
                    LabeledContent(title) {
                        HStack(spacing: 6) {
                            TextField(title, text: Binding(get: { value }, set: setValue),
                                      prompt: Text(field.placeholder ?? field.defaultValue ?? ""))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                            ModelListButton(model: model, serviceID: serviceID) { setValue($0) }
                        }
                    }
                } else {
                    TextField(title, text: Binding(get: { value }, set: setValue),
                              prompt: Text(field.placeholder ?? field.defaultValue ?? ""))
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: serviceID) { loaded = false; load() }
    }

    private var title: String { field.isRequired ? field.title : "\(field.title)（选填）" }

    private var value: String { model.settings.translationFields[serviceID]?[field.option] ?? "" }

    private func setValue(_ newValue: String) {
        var fields = model.settings.translationFields[serviceID] ?? [:]
        fields[field.option] = newValue.isEmpty ? nil : newValue
        model.settings.translationFields[serviceID] = fields
    }

    private func load() {
        guard field.isSecret, !loaded else { return }
        loaded = true
        secret = (try? model.translations.secrets.get(serviceID: serviceID, option: field.option)) ?? nil ?? ""
    }

    private func saveSecret() {
        guard loaded else { return }
        let store = model.translations.secrets
        if secret.isEmpty {
            try? store.delete(serviceID: serviceID, option: field.option)
        } else {
            try? store.set(secret, serviceID: serviceID, option: field.option)
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
            if !compact {
                Toggle("翻译表格中的文字", isOn: $settings.translationOptions.translateTableText)
                Toggle("兼容模式", isOn: $settings.translationOptions.enhanceCompatibility)
                    .help("译文 PDF 在部分阅读器中显示异常时打开")
                LabeledContent("术语表（选填）") {
                    HStack {
                        Text(settings.translationOptions.glossaryFile?.lastPathComponent ?? "未选择")
                            .foregroundStyle(.secondary)
                        if settings.translationOptions.glossaryFile != nil {
                            Button("清除") { settings.translationOptions.glossaryFile = nil }
                        }
                        Button("选择…", action: chooseGlossary)
                    }
                }
                Stepper(value: Binding(get: { settings.translationOptions.qps ?? 4 },
                                       set: { settings.translationOptions.qps = $0 }), in: 1...50) {
                    Text("每秒请求数：\(settings.translationOptions.qps ?? 4)")
                }
                .help("付费接口额度较高时可以调大以加快速度；免费服务请保持较低")
            }
        } header: {
            Text(compact ? "选项" : "默认选项")
        }
    }

    private func chooseGlossary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = "选择术语表 CSV（两列：原文, 译文）"
        if panel.runModal() == .OK { settings.translationOptions.glossaryFile = panel.url }
    }
}

/// "获取模型列表": fetches the service's models with the key and address entered above and lets the
/// user pick one from a searchable list.
private struct ModelListButton: View {
    let model: AppModel
    let serviceID: String
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
        .accessibilityLabel("获取模型列表")
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
                    PopoverSearchField(prompt: "搜索模型", text: $filter)
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
            let secrets = (try? model.translations.secrets.secrets(for: service)) ?? [:]
            models = try await ModelListFetcher.fetch(serviceID: serviceID,
                                                      fieldValues: model.settings.translationFields[serviceID] ?? [:],
                                                      secrets: secrets)
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
        let fields = settings.translationFields[serviceID] ?? [:]
        switch ReasoningEffort.support(serviceID: serviceID, fields: fields) {
        case .none:
            EmptyView()
        case .unsupportedModel:
            LabeledContent("推理强度") {
                Text("当前模型不支持").foregroundStyle(.secondary)
            }
            .help("所选模型不是推理模型，不会发送推理强度参数。")
        case let .choices(choices, _):
            Picker("推理强度", selection: Binding(
                get: { ReasoningEffort.current(serviceID: serviceID, fields: fields) ?? "" },
                set: { value in
                    var updated = settings.translationFields[serviceID] ?? [:]
                    ReasoningEffort.set(value, serviceID: serviceID, fields: &updated)
                    settings.translationFields[serviceID] = updated
                })) {
                ForEach(choices) { Text($0.title).tag($0.value) }
            }
            .pickerStyle(.segmented)
        }
    }
}
