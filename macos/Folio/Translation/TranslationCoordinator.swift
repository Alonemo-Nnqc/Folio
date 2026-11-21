import AppKit
import FolioCore
import FolioTranslate
import Observation

/// Queues whole-document translations (several at once: 设置 ▸ 翻译 ▸ 同时翻译), shows their progress in the list and files
/// the results under their items (TRANS-01…06). The engine is built in: nothing to install.
@Observable
final class TranslationCoordinator {
    /// Progress of a queued or running translation, keyed by item id.
    struct JobState: Equatable {
        var fileId: String
        var fraction: Double?
        var stage: String
        /// The translation so far (pages done translated, the rest original), for reading while it runs.
        var preview: URL?
        /// What to tell the user when it is done (paragraphs the service would not translate).
        var notices: [String] = []
    }

    private(set) var jobs: [String: JobState] = [:] {
        didSet {
            current = jobs
            let keys = Set(jobs.keys)
            if keys != jobIDs { jobIDs = keys }
        }
    }
    /// The items with a job: changes when one starts or ends, not with its progress, which moves several times a second.
    private(set) var jobIDs: Set<String> = []
    /// `jobs`, for reading without being told of each change.
    @ObservationIgnored private var current: [String: JobState] = [:]

    func currentJob(of itemId: String) -> JobState? { current[itemId] }

    /// Screenshots of the progress UI without running the engine (`-FolioPreviewTranslating`).
    func previewJob(itemId: String, fileId: String, stage: String, fraction: Double?) {
        jobs[itemId] = JobState(fileId: fileId, fraction: fraction, stage: stage)
    }
    /// Bumped when the old engine is deleted, so settings re-read its size.
    private(set) var legacyRevision = 0

    @ObservationIgnored private weak var model: AppModel?
    /// Screenshot and UI-test runs (`-FolioUITesting YES`) keep their keys apart: a build signed differently from the
    /// installed app would otherwise make the Keychain ask the user about every key it reads.
    @ObservationIgnored let secrets = UserDefaults.standard.bool(forKey: "FolioUITesting")
        ? SecretStore(service: SecretStore.defaultService + ".uitesting") : SecretStore()
    /// A paper waiting its turn, with the service and settings it was queued with (changing them in 设置 later does
    /// not change what a queued paper uses).
    private struct Queued {
        let itemId: String
        let fileId: String
        let serviceID: String
        let fields: [String: String]
        let options: TranslationOptions
        let profileName: String?
    }
    @ObservationIgnored private var queue: [Queued] = []
    private final class Running {
        let itemId: String
        let serviceID: String
        var job: TranslationJob?
        var task: Task<Void, Never>?
        var cancelled = false
        init(itemId: String, serviceID: String) {
            self.itemId = itemId
            self.serviceID = serviceID
        }

        func cancel() {
            cancelled = true
            job?.cancel()
        }
    }

    /// Translations running now, by item.
    @ObservationIgnored private var running: [String: Running] = [:]
    /// Papers of one service at the same time (设置 ▸ 翻译 ▸ 同一服务): what a service's rate limits and a local
    /// model's or agent's machine can take.
    private var perService: Int { min(4, max(1, model?.settings.translationParallelJobs ?? 2)) }
    /// Papers at the same time across all services (设置 ▸ 翻译 ▸ 总数): what this Mac can lay out and typeset at once.
    private var total: Int { max(perService, min(8, max(1, model?.settings.translationParallelTotal ?? 6))) }

    private func runningCount(of serviceID: String) -> Int { running.values.filter { $0.serviceID == serviceID }.count }

    init(model: AppModel) {
        self.model = model
    }

    var activeItemIds: Set<String> { Set(jobs.keys) }

    static var logsDirectory: URL { TranslationJob.supportDirectory.appending(path: "logs", directoryHint: .isDirectory) }

    // MARK: Requests

    /// "翻译全文…": asks for this run's options, for one paper or a batch.
    func requestTranslation(fileIds: [String]) {
        guard let model else { return }
        let files = fileIds.compactMap { model.snapshot.files[$0] }.filter { $0.isPDF && $0.translationOf == nil }
        guard !files.isEmpty else {
            model.toasts.show(String(localized: "所选文献没有可翻译的 PDF"), systemImage: "questionmark.circle")
            return
        }
        let waiting = files.filter { jobs[$0.itemId] == nil }
        guard !waiting.isEmpty else {
            model.toasts.show(String(localized: "这篇论文正在翻译"), systemImage: "character.book.closed")
            return
        }
        model.activeSheet = .translate(fileIds: waiting.map(\.id))
    }

    /// Starts (or queues) translations of several papers with the current settings, and the pages typed for this run.
    func start(fileIds: [String], pages: String? = nil) {
        for id in fileIds { start(fileId: id, pages: pages) }
    }

    /// The settings' options for a run of `pages` (empty: all). Pages are never a setting: a range saved by an earlier
    /// version stays out of every later paper.
    static func options(_ saved: TranslationOptions, pages: String?) -> TranslationOptions {
        var options = saved
        let typed = pages?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        options.pages = typed.isEmpty ? nil : typed
        return options
    }

    /// More papers may run at once now: starts the waiting ones.
    func parallelChanged() { pump() }

    /// Starts (or queues) a translation with the current settings — called by the options sheet.
    func start(fileId: String, pages: String? = nil) {
        guard let model, let file = model.snapshot.files[fileId] else { return }
        let service = model.settings.translationService
        if let problem = configurationProblem(serviceID: service) {
            alert(String(localized: "翻译服务还没有配置好"), problem, primary: String(localized: "打开设置")) { self.openSettings() }
            return
        }
        if service == TranslationServiceCatalog.appleServiceID {
            let options = model.settings.translationOptions
            Task {
                switch await AppleSystemTranslator.availability(from: options.langIn, to: options.langOut) {
                case .installed: self.enqueue(itemId: file.itemId, fileId: fileId, pages: pages)
                case .needsDownload:
                    self.alert(String(localized: "需要先下载语言包"), String(localized: "Apple 系统翻译需要先下载所选语言的离线语言包。可以在 设置 ▸ 翻译 中点击\"下载语言包\"。"),
                               primary: String(localized: "打开设置")) { self.openSettings() }
                case .unsupported:
                    self.alert(String(localized: "Apple 系统翻译不支持这组语言"), String(localized: "请在 设置 ▸ 翻译 中换用其他翻译服务。"), primary: String(localized: "打开设置")) { self.openSettings() }
                }
            }
            return
        }
        enqueue(itemId: file.itemId, fileId: fileId, pages: pages)
    }

    // MARK: New papers (设置 ▸ 翻译 ▸ 自动翻译新添加的论文)

    @ObservationIgnored private var toldNotConfigured = false

    /// A paper just added (a PDF imported, saved from the browser, or downloaded for it): translated with the current
    /// settings when 自动翻译新添加的论文 is on and it has no translation yet. Waits for metadata retrieval, which may
    /// rename the file, and lets a scan be recognised first (the queue does that).
    func translateNewPaper(itemId: String) {
        guard let model, model.settings.autoTranslateImports else { return }
        Task { [weak self] in
            // Up to a minute for retrieval to settle.
            for _ in 0..<60 {
                guard let item = model.snapshot.items[itemId] else { return }
                if item.metadataState != .pending { break }
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, model.settings.autoTranslateImports, self.jobs[itemId] == nil,
                  let file = Self.untranslatedPDF(of: itemId, snapshot: model.snapshot) else { return }
            if let problem = self.configurationProblem(serviceID: model.settings.translationService) {
                // Said once, not at every import.
                if !self.toldNotConfigured {
                    self.toldNotConfigured = true
                    model.toasts.show(String(localized: "没有自动翻译新论文：\(problem)"), systemImage: "exclamationmark.triangle")
                }
                return
            }
            self.start(fileId: file.id)
        }
    }

    /// The paper's PDF to translate: an original (not a translation, not named like one) when the paper has no
    /// translation yet.
    static func untranslatedPDF(of itemId: String, snapshot: LibrarySnapshot) -> FileRecord? {
        let files = snapshot.files(of: itemId)
        guard !files.contains(where: { $0.translationKind != nil || $0.translationOf != nil }) else { return nil }
        let originals = files.filter { file in
            file.isPDF && !["双语对照", "译文", ".dual", ".mono", "-dual", "-mono", "_dual", "_mono"].contains { file.fileName.localizedCaseInsensitiveContains($0) }
        }
        let item = snapshot.items[itemId]
        return originals.first { $0.id == item?.defaultFileId } ?? originals.first
    }

    func cancel(itemId: String) {
        queue.removeAll { $0.itemId == itemId }
        if let running = running[itemId] {
            running.cancel()
            if running.job == nil { jobs[itemId] = nil }
        } else {
            jobs[itemId] = nil
        }
    }

    /// App termination: the engine runs in its own process group and would outlive Folio.
    func cancelAll() {
        queue.removeAll()
        running.values.forEach { $0.cancel() }
    }

    // MARK: Old engine

    /// Deletes the pdf2zh_next engine earlier versions downloaded.
    func removeLegacyEngine() {
        do {
            try LegacyTranslator.remove()
            model?.toasts.show(String(localized: "已删除旧翻译组件"), systemImage: "trash")
        } catch {
            model?.toasts.show(String(localized: "无法删除：\(error.localizedDescription)"), systemImage: "exclamationmark.triangle")
        }
        legacyRevision += 1
    }

    /// What is missing before `serviceID` can run, in words for the user; nil when ready.
    func configurationProblem(serviceID: String) -> String? {
        guard let service = TranslationServiceCatalog.service(id: serviceID) else { return String(localized: "请在设置中选择翻译服务。") }
        let values = model?.settings.translationFields[serviceID] ?? [:]
        for field in service.requiredFields {
            let value = field.isSecret
                ? (try? secrets.get(serviceID: serviceID, option: field.option)) ?? nil
                : values[field.option]
            if (value ?? "").trimmingCharacters(in: .whitespaces).isEmpty && field.defaultValue == nil {
                return String(localized: "\(service.displayName) 需要填写\"\(field.title)\"。")
            }
        }
        if case .agent(let agent) = service.backend {
            let path = service.fields.first { $0.option.hasSuffix("-path") }.flatMap { values[$0.option] }
            if agent.locate(customPath: path) == nil {
                return String(localized: "在这台 Mac 上找不到 \(agent.command)。请先安装并登录 \(service.displayName)，或在设置中填写它的路径。")
            }
        }
        return nil
    }

    // MARK: Queue

    private func enqueue(itemId: String, fileId: String, pages: String?) {
        guard jobs[itemId] == nil, let model else { return }
        let settings = model.settings
        let serviceID = settings.translationService
        // Who translates and how, taken now: the settings may change while the paper waits or runs.
        let profileName = settings.selectedTranslationProfiles[serviceID].flatMap { id in settings.translationProfiles.first { $0.id == id }?.name }
        queue.append(Queued(itemId: itemId, fileId: fileId, serviceID: serviceID, fields: settings.translationFields[serviceID] ?? [:],
                            options: Self.options(settings.translationOptions, pages: pages), profileName: profileName))
        jobs[itemId] = JobState(fileId: fileId, fraction: nil, stage: String(localized: "等待翻译"))
        pump()
    }

    /// Starts waiting papers, in the order they were queued, while there is room: in all (`total`) and for their
    /// service (`perService`). A paper whose service is busy waits without holding up papers for other services.
    private func pump() {
        while let index = TranslationScheduler.next(waiting: queue.map(\.serviceID), running: running.values.map(\.serviceID),
                                                     perService: perService, total: total) {
            startNext(queue.remove(at: index))
        }
        // What the waiting ones are waiting for.
        for waiting in queue where jobs[waiting.itemId]?.stage != nil {
            let busy = runningCount(of: waiting.serviceID) >= perService
            let name = TranslationServiceCatalog.service(id: waiting.serviceID)?.displayName ?? waiting.serviceID
            let stage = busy ? String(localized: "等待翻译（\(name) 已有 \(perService) 篇在翻译）") : String(localized: "等待翻译")
            if jobs[waiting.itemId]?.stage != stage { jobs[waiting.itemId]?.stage = stage }
        }
    }

    private func startNext(_ next: Queued) {
        guard let model else { return }
        guard let file = model.snapshot.files[next.fileId] else {
            jobs[next.itemId] = nil
            return
        }
        let serviceID = next.serviceID
        let provider = TranslationServiceCatalog.service(id: serviceID).map {
            TranslationNaming.Provider(service: $0, fields: next.fields, profileName: next.profileName)
        } ?? TranslationNaming.Provider(name: serviceID, model: nil)
        let source = model.fileURL(file)
        let output = TranslationJob.supportDirectory.appending(path: "output/\(UUID().uuidString)", directoryHint: .isDirectory)
        jobs[next.itemId] = JobState(fileId: next.fileId, fraction: nil, stage: String(localized: "正在启动翻译"))
        let current = Running(itemId: next.itemId, serviceID: serviceID)
        running[next.itemId] = current
        current.task = Task { [weak self] in
            guard let self else { return }
            do {
                // A scan has no text to translate: its text is recognised first (OCR-01).
                if await model.ocr.isScanned(fileId: next.fileId), !current.cancelled {
                    self.jobs[next.itemId]?.stage = String(localized: "正在识别扫描件文字")
                    try await model.ocr.recognizeAndWait(fileId: next.fileId) { [weak self] progress in
                        self?.jobs[next.itemId]?.fraction = progress.fraction
                    }
                    self.jobs[next.itemId]?.fraction = nil
                    self.jobs[next.itemId]?.stage = String(localized: "正在启动翻译")
                }
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let service = TranslationServiceCatalog.service(id: serviceID)
                let request = TranslationRequest(
                    input: source, outputDirectory: output, serviceID: serviceID,
                    fieldValues: next.fields,
                    secrets: service.map { (try? self.secrets.secrets(for: $0)) ?? [:] } ?? [:],
                    options: next.options)
                if !current.cancelled {
                    let job = TranslationJob(request: request)
                    current.job = job
                    for await event in job.start() {
                        self.handle(event, itemId: next.itemId, fileId: next.fileId, provider: provider, options: next.options)
                    }
                }
            } catch {
                if !current.cancelled {
                    self.fail(itemId: next.itemId, fileId: next.fileId, pages: next.options.pages, message: error.localizedDescription, log: nil)
                }
            }
            if current.cancelled { self.jobs[next.itemId] = nil }
            try? FileManager.default.removeItem(at: output)
            self.running[next.itemId] = nil
            self.pump()
        }
    }

    private func handle(_ event: TranslationEvent, itemId: String, fileId: String, provider: TranslationNaming.Provider,
                        options: TranslationOptions) {
        switch event {
        case .stage(let stage):
            jobs[itemId]?.stage = stage
        case .progress(let fraction):
            jobs[itemId]?.fraction = fraction
            if jobs[itemId]?.stage == String(localized: "正在启动翻译") { jobs[itemId]?.stage = String(localized: "正在翻译") }
        case .preview(let url):
            jobs[itemId]?.preview = url
        case .notice(let text):
            jobs[itemId]?.notices.append(text)
        case .problem(let text):
            // At once, with what the service said: the translation is not stuck, and the cause may be the user's to fix.
            let title = model?.snapshot.items[itemId]?.title ?? ""
            model?.toasts.show(String(localized: "「\(title)」：\(text)"), systemImage: "exclamationmark.triangle")
        case .finished(let mono, let dual):
            let notices = jobs[itemId]?.notices ?? []
            jobs[itemId] = nil
            file(mono: mono, dual: dual, of: fileId, provider: provider, options: options, notices: notices)
        case .failed(let message, let logURL):
            fail(itemId: itemId, fileId: fileId, pages: options.pages, message: message, log: logURL)
        case .cancelled:
            jobs[itemId] = nil
            model?.toasts.show(String(localized: "已取消翻译"), systemImage: "xmark.circle")
        }
    }

    /// Copies the results into the library next to the original (TRANS-05), named by language, provider and
    /// model ("论文（简体中文译文 · DeepSeek · deepseek-chat）.pdf").
    private func file(mono: URL?, dual: URL?, of fileId: String, provider: TranslationNaming.Provider, options: TranslationOptions,
                      notices: [String] = []) {
        guard let model, let source = model.snapshot.files[fileId] else { return }
        let base = (source.fileName as NSString).deletingPathExtension
        let language = TranslationOptions.commonLanguages.first { $0.code == options.langOut }?.name ?? ""
        let existing = Set(model.snapshot.files(of: source.itemId).map { ($0.fileName as NSString).deletingPathExtension })
        func name(_ kind: TranslationNaming.TranslationKindName) -> String {
            TranslationNaming.baseName(original: base, kind: kind, language: language, provider: provider, existing: existing)
        }
        // The same paper by the same service and model before: replaced, if that is what the user chose.
        let earlier = options.duplicates == .replace
            ? model.snapshot.files.values.filter { $0.translationOf == fileId && $0.translatedBy == provider.label }.map(\.id) : []
        var added: [FileRecord] = []
        model.perform(String(localized: "无法保存译文")) {
            if let mono {
                added.append(try model.library.addTranslatedFile(at: mono, of: fileId, kind: .mono, baseName: name(.mono), translatedBy: provider.label))
            }
            if let dual {
                added.append(try model.library.addTranslatedFile(at: dual, of: fileId, kind: .dual, baseName: name(.dual), translatedBy: provider.label))
            }
        }
        guard let first = added.first else { return }
        if !earlier.isEmpty { model.trashFiles(earlier) }
        model.importer.indexFulltext()
        let title = model.snapshot.items[source.itemId]?.title ?? base
        let done = ([String(localized: "「\(title)」翻译完成")] + notices).joined(separator: " ")
        model.toasts.show(done, systemImage: "character.book.closed.fill", actionTitle: String(localized: "打开译文")) {
            model.open(fileId: first.id, mode: .reader)
        }
    }

    /// Says why a translation failed; 重试 runs it again as it was (the same pages).
    private func fail(itemId: String, fileId: String, pages: String?, message: String, log: URL?) {
        jobs[itemId] = nil
        let title = model?.snapshot.items[itemId]?.title ?? ""
        let alert = NSAlert()
        alert.messageText = String(localized: "「\(title)」翻译失败")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "重试"))
        alert.addButton(withTitle: String(localized: "取消"))
        if log != nil { alert.addButton(withTitle: String(localized: "查看日志")) }
        present(alert) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.start(fileId: fileId, pages: pages)
            case .alertThirdButtonReturn: if let log { NSWorkspace.shared.activateFileViewerSelecting([log]) }
            default: break
            }
        }
    }

    // MARK: Helpers

    private func openSettings() {
        AppDelegate.shared.showSettings(nil)
        AppDelegate.shared.settingsWindow?.select(pane: String(localized: "翻译"))
    }

    private func alert(_ title: String, _ text: String, primary: String, action: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: primary)
        alert.addButton(withTitle: String(localized: "取消"))
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
