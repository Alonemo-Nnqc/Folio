import AppKit
import FolioCore
import FolioTranslate
import Observation

/// Queues whole-document translations (one at a time), shows their progress in the list and files
/// the results under their items (TRANS-01…06). Also owns installing the engine (TRANS-02).
@Observable
final class TranslationCoordinator {
    /// Progress of a queued or running translation, keyed by item id.
    struct JobState: Equatable {
        var fileId: String
        var fraction: Double?
        var stage: String
    }

    enum InstallState: Equatable {
        case idle
        case installing(TranslatorInstallProgress)
        case failed(String)
    }

    private(set) var jobs: [String: JobState] = [:]
    private(set) var installState = InstallState.idle
    /// Bumped after installs / uninstalls so views re-read the engine status.
    private(set) var engineRevision = 0

    @ObservationIgnored private weak var model: AppModel?
    /// `-FolioTranslatorDirectory <dir>` points tests at a scratch install instead of Application Support.
    @ObservationIgnored let installation = TranslatorInstallation(
        baseDirectory: UserDefaults.standard.string(forKey: "FolioTranslatorDirectory").map { URL(filePath: $0) }
            ?? TranslatorInstallation.defaultBaseDirectory)
    @ObservationIgnored let secrets = SecretStore()
    @ObservationIgnored private var queue: [(itemId: String, fileId: String)] = []
    /// The translation in progress. `job` is nil while the engine is still being located.
    private final class Running {
        let itemId: String
        var job: TranslationJob?
        var task: Task<Void, Never>?
        var cancelled = false
        init(itemId: String) { self.itemId = itemId }

        func cancel() {
            cancelled = true
            job?.cancel()
        }
    }

    @ObservationIgnored private var running: Running?
    @ObservationIgnored private var installTask: Task<Void, Never>?
    /// Translations asked for before the engine was installed; started when the install finishes.
    @ObservationIgnored private var waitingForInstall: [String] = []

    init(model: AppModel) {
        self.model = model
    }

    var activeItemIds: Set<String> { Set(jobs.keys) }

    // MARK: Requests

    /// "翻译全文…": checks the engine and the service, then asks for this run's options.
    func requestTranslation(fileId: String) {
        guard let model, let file = model.snapshot.files[fileId], file.isPDF else { return }
        guard jobs[file.itemId] == nil else {
            model.toasts.show("这篇论文正在翻译", systemImage: "character.book.closed")
            return
        }
        switch engineStatus {
        case .ready:
            model.activeSheet = .translate(fileId: fileId)
        case .notInstalled:
            offerInstall(then: fileId)
        case .broken(let reason):
            alert("翻译组件无法使用", reason + "\n\n可以在 设置 ▸ 翻译 中重新安装，或改用自己安装的 pdf2zh_next。",
                  primary: "打开设置") { self.openSettings() }
        }
    }

    /// Starts (or queues) a translation with the current settings — called by the options sheet.
    func start(fileId: String) {
        guard let model, let file = model.snapshot.files[fileId] else { return }
        let service = model.settings.translationService
        if let problem = configurationProblem(serviceID: service) {
            alert("翻译服务还没有配置好", problem, primary: "打开设置") { self.openSettings() }
            return
        }
        if service == TranslationServiceCatalog.appleServiceID {
            let options = model.settings.translationOptions
            Task {
                switch await AppleSystemTranslator.availability(from: options.langIn, to: options.langOut) {
                case .installed: self.enqueue(itemId: file.itemId, fileId: fileId)
                case .needsDownload:
                    self.alert("需要先下载语言包", "Apple 系统翻译需要先下载所选语言的离线语言包。可以在 设置 ▸ 翻译 中点击\"下载语言包\"。",
                               primary: "打开设置") { self.openSettings() }
                case .unsupported:
                    self.alert("Apple 系统翻译不支持这组语言", "请在 设置 ▸ 翻译 中换用其他翻译服务。", primary: "打开设置") { self.openSettings() }
                }
            }
            return
        }
        enqueue(itemId: file.itemId, fileId: fileId)
    }

    func cancel(itemId: String) {
        queue.removeAll { $0.itemId == itemId }
        if let running, running.itemId == itemId {
            running.cancel()
            if running.job == nil { jobs[itemId] = nil }
        } else {
            jobs[itemId] = nil
        }
    }

    /// App termination: the engine runs in its own process group and would outlive Folio.
    func cancelAll() {
        queue.removeAll()
        running?.cancel()
        installTask?.cancel()
    }

    // MARK: Engine

    enum EngineStatus: Equatable {
        case ready, notInstalled, broken(String)
    }

    var engineStatus: EngineStatus {
        _ = engineRevision
        if let model, !model.settings.translatorCustomPath.isEmpty {
            return FileManager.default.isExecutableFile(atPath: model.settings.translatorCustomPath)
                ? .ready : .broken("找不到 \(model.settings.translatorCustomPath)")
        }
        switch installation.status() {
        case .installed: return .ready
        case .notInstalled: return .notInstalled
        case .broken(let reason): return .broken(reason)
        }
    }

    private func runtime() async throws -> TranslatorRuntime {
        if let path = model?.settings.translatorCustomPath, !path.isEmpty {
            return try await installation.customRuntime(executable: URL(filePath: path)).runtime
        }
        return try installation.runtime()
    }

    private func offerInstall(then fileId: String) {
        alert("需要下载翻译组件",
              "保留排版的翻译由开源引擎 pdf2zh_next（BabelDOC）完成。首次使用需要下载 Python、引擎和版面模型，约占 1.4 GB 磁盘空间，通常需要几分钟。\n\n组件安装在 ~/Library/Application Support/Folio/Translator，不会改动系统里的其他 Python。",
              primary: "下载并安装") {
            self.waitingForInstall.append(fileId)
            self.install()
            self.openSettings()
        }
    }

    func install() {
        guard installTask == nil else { return }
        installState = .installing(TranslatorInstallProgress(phase: .preparing, fractionCompleted: 0, detail: nil))
        let installation = self.installation
        installTask = Task {
            do {
                try await installation.install { progress in
                    Task { @MainActor [weak self] in
                        if case .installing = self?.installState { self?.installState = .installing(progress) }
                    }
                }
                installState = .idle
                engineRevision += 1
                model?.toasts.show("翻译组件已安装", systemImage: "checkmark.circle")
                let waiting = waitingForInstall
                waitingForInstall = []
                for fileId in waiting { requestTranslation(fileId: fileId) }
            } catch is CancellationError {
                installState = .idle
                engineRevision += 1
            } catch {
                installState = .failed(error.localizedDescription)
                engineRevision += 1
            }
            installTask = nil
        }
    }

    func cancelInstall() {
        installTask?.cancel()
        waitingForInstall = []
    }

    func uninstall() {
        do {
            try installation.uninstall()
            model?.toasts.show("已卸载翻译组件", systemImage: "trash")
        } catch {
            model?.toasts.show("无法卸载：\(error.localizedDescription)", systemImage: "exclamationmark.triangle")
        }
        engineRevision += 1
    }

    /// What is missing before `serviceID` can run, in words for the user; nil when ready.
    func configurationProblem(serviceID: String) -> String? {
        guard let service = TranslationServiceCatalog.service(id: serviceID) else { return "请在设置中选择翻译服务。" }
        let values = model?.settings.translationFields[serviceID] ?? [:]
        for field in service.requiredFields {
            let value = field.isSecret
                ? (try? secrets.get(serviceID: serviceID, option: field.option)) ?? nil
                : values[field.option]
            if (value ?? "").trimmingCharacters(in: .whitespaces).isEmpty && field.defaultValue == nil {
                return "\(service.displayName) 需要填写\"\(field.title)\"。"
            }
        }
        return nil
    }

    // MARK: Queue

    private func enqueue(itemId: String, fileId: String) {
        guard jobs[itemId] == nil else { return }
        jobs[itemId] = JobState(fileId: fileId, fraction: nil, stage: running == nil ? "正在启动翻译" : "等待翻译")
        queue.append((itemId, fileId))
        pump()
    }

    private func pump() {
        guard running == nil, !queue.isEmpty, let model else { return }
        let next = queue.removeFirst()
        guard let file = model.snapshot.files[next.fileId] else {
            jobs[next.itemId] = nil
            return pump()
        }
        let settings = model.settings
        let serviceID = settings.translationService
        let source = model.fileURL(file)
        let output = installation.layout.base.appending(path: "output/\(UUID().uuidString)", directoryHint: .isDirectory)
        jobs[next.itemId] = JobState(fileId: next.fileId, fraction: nil, stage: "正在启动翻译")
        let current = Running(itemId: next.itemId)
        running = current
        current.task = Task { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let service = TranslationServiceCatalog.service(id: serviceID)
                let request = TranslationRequest(
                    input: source, outputDirectory: output, serviceID: serviceID,
                    fieldValues: settings.translationFields[serviceID] ?? [:],
                    secrets: service.map { (try? self.secrets.secrets(for: $0)) ?? [:] } ?? [:],
                    options: settings.translationOptions)
                let runtime = try await self.runtime()
                if !current.cancelled {
                    let job = TranslationJob(request: request, runtime: runtime,
                                             appleTranslatorCommand: Self.appleHelper.map { [$0.path] })
                    current.job = job
                    for await event in job.start() {
                        self.handle(event, itemId: next.itemId, fileId: next.fileId)
                    }
                }
            } catch {
                if !current.cancelled { self.fail(itemId: next.itemId, fileId: next.fileId, message: error.localizedDescription, log: nil) }
            }
            if current.cancelled { self.jobs[next.itemId] = nil }
            try? FileManager.default.removeItem(at: output)
            self.running = nil
            self.pump()
        }
    }

    private func handle(_ event: TranslationEvent, itemId: String, fileId: String) {
        switch event {
        case .stage(let stage):
            jobs[itemId]?.stage = stage
        case .progress(let fraction):
            jobs[itemId]?.fraction = fraction
            if jobs[itemId]?.stage == "正在启动翻译" { jobs[itemId]?.stage = "正在翻译" }
        case .finished(let mono, let dual):
            jobs[itemId] = nil
            file(mono: mono, dual: dual, of: fileId)
        case .failed(let message, let logURL):
            fail(itemId: itemId, fileId: fileId, message: message, log: logURL)
        case .cancelled:
            jobs[itemId] = nil
            model?.toasts.show("已取消翻译", systemImage: "xmark.circle")
        }
    }

    /// Copies the results into the library next to the original (TRANS-05).
    private func file(mono: URL?, dual: URL?, of fileId: String) {
        guard let model, let source = model.snapshot.files[fileId] else { return }
        let base = (source.fileName as NSString).deletingPathExtension
        let language = TranslationOptions.commonLanguages.first { $0.code == model.settings.translationOptions.langOut }?.name ?? "译文"
        var added: [FileRecord] = []
        model.perform("无法保存译文") {
            if let mono {
                added.append(try model.library.addTranslatedFile(at: mono, of: fileId, kind: .mono, baseName: "\(base)（\(language)译文）"))
            }
            if let dual {
                added.append(try model.library.addTranslatedFile(at: dual, of: fileId, kind: .dual, baseName: "\(base)（双语对照）"))
            }
        }
        guard let first = added.first else { return }
        model.importer.indexFulltext()
        let title = model.snapshot.items[source.itemId]?.title ?? base
        model.toasts.show("「\(title)」翻译完成", systemImage: "character.book.closed.fill", actionTitle: "打开译文") {
            model.open(fileId: first.id, mode: .reader)
        }
    }

    private func fail(itemId: String, fileId: String, message: String, log: URL?) {
        jobs[itemId] = nil
        let title = model?.snapshot.items[itemId]?.title ?? ""
        let alert = NSAlert()
        alert.messageText = "「\(title)」翻译失败"
        alert.informativeText = message
        alert.addButton(withTitle: "重试")
        alert.addButton(withTitle: "取消")
        if log != nil { alert.addButton(withTitle: "查看日志") }
        present(alert) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.start(fileId: fileId)
            case .alertThirdButtonReturn: if let log { NSWorkspace.shared.activateFileViewerSelecting([log]) }
            default: break
            }
        }
    }

    // MARK: Helpers

    /// `folio-apple-translate`, embedded next to the app's executable.
    static var appleHelper: URL? {
        let url = Bundle.main.bundleURL.appending(path: "Contents/MacOS/folio-apple-translate")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    private func openSettings() {
        AppDelegate.shared.showSettings(nil)
        AppDelegate.shared.settingsWindow?.select(pane: "翻译")
    }

    private func alert(_ title: String, _ text: String, primary: String, action: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: primary)
        alert.addButton(withTitle: "取消")
        present(alert) { if $0 == .alertFirstButtonReturn { action() } }
    }

    private func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = NSApp.keyWindow ?? model?.libraryWindow, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}
