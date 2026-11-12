import AppKit
import FolioCore
import FolioMetadata
import FolioTranslate
import Observation

/// 期刊分区与影响因子 (META-30): keeps the easyScholar key, feeds the library's journals to `JournalMetricsService`
/// as items arrive or change, and reports its state to 设置 ▸ 检索 and the inspector.
@Observable
final class JournalMetricsCoordinator {
    /// What 设置 shows under the key.
    enum TestState: Equatable {
        case idle, testing
        case success(String)
        case failure(String)
    }

    private(set) var hasKey = false
    private(set) var status = JournalMetricsService.Status()
    var testState = TestState.idle

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var service: JournalMetricsService?
    /// The library `service` works for: a library opened later gets its own service.
    @ObservationIgnored private weak var serviceLibrary: Library?
    @ObservationIgnored private var key: String?
    @ObservationIgnored private var keyLoaded = false
    @ObservationIgnored private var retryTimer: Timer?
    @ObservationIgnored private var lastEnqueued: [String] = []

    /// UI tests and screenshot runs keep the key in memory and never touch the Keychain.
    @ObservationIgnored private let inMemory = UserDefaults.standard.bool(forKey: "FolioUITesting")
    private static let store = SecretStore(service: "com.nnqc.Folio.easyscholar", label: "Folio：easyScholar SecretKey")
    private static let account = (service: "easyscholar", option: "secretKey")

    init(model: AppModel) {
        self.model = model
    }

    // MARK: Key

    /// The saved key (read from the Keychain once).
    var secretKey: String {
        loadKeyIfNeeded()
        return key ?? ""
    }

    private func loadKeyIfNeeded() {
        guard !keyLoaded else { return }
        keyLoaded = true
        if !inMemory { key = (try? Self.store.get(serviceID: Self.account.service, option: Self.account.option)) ?? nil }
        if key?.isEmpty == true { key = nil }
        hasKey = key != nil
    }

    /// Saves (or, empty, removes) the key; a different key forgets earlier refusals and asks again for journals
    /// it may know better.
    func saveKey(_ value: String) {
        loadKeyIfNeeded()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (key ?? "") else { return }
        if !inMemory {
            do {
                try Self.store.set(trimmed, serviceID: Self.account.service, option: Self.account.option)
            } catch {
                model?.toasts.show(error.localizedDescription, systemImage: "exclamationmark.triangle")
                return
            }
        }
        key = trimmed.isEmpty ? nil : trimmed
        hasKey = key != nil
        testState = .idle
        lastEnqueued = []
        let service = currentService()
        Task {
            await service?.setKey(key)
            await MainActor.run { self.snapshotDidChange() }
        }
    }

    // MARK: Fetching

    /// The service for the library now open (another library gets its own).
    private func currentService() -> JournalMetricsService? {
        guard let model else { return nil }
        if let service, serviceLibrary === model.library { return service }
        if let old = service { Task { await old.cancelAll() } }
        let created = JournalMetricsService(library: model.library, retryDelay: .seconds(300)) { [weak self] status in
            Task { @MainActor in self?.status = status }
        }
        service = created
        serviceLibrary = model.library
        lastEnqueued = []
        loadKeyIfNeeded()
        let key = self.key
        Task { await created.setKey(key) }
        return created
    }

    /// After every snapshot: journals that were never looked up (new items, changed journal names) or whose ranks
    /// are older than 30 days join the queue. Cheap when nothing is stale.
    func snapshotDidChange() {
        loadKeyIfNeeded()
        guard let model, hasKey, model.settings.journalMetricsAutoFetch else { return }
        let names = JournalMetricsService.staleJournals(in: model.snapshot)
        guard !names.isEmpty, names != lastEnqueued else { return }
        lastEnqueued = names
        let service = currentService()
        Task { await service?.enqueue(names) }
        scheduleRetries()
    }

    /// Failed lookups get another chance every ten minutes while Folio runs.
    private func scheduleRetries() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.lastEnqueued = []
                self?.snapshotDidChange()
            }
        }
    }

    /// Auto fetch turned off: what is queued is dropped.
    func autoFetchDidChange() {
        if model?.settings.journalMetricsAutoFetch == true {
            lastEnqueued = []
            snapshotDidChange()
        } else if let service {
            Task { await service.cancelAll() }
        }
    }

    /// "刷新期刊指标" on items: asks again now, whatever the cache holds.
    func refresh(itemIds: [String]) {
        guard let model else { return }
        let names = itemIds.compactMap { model.snapshot.items[$0] }.compactMap(JournalMetrics.journalName(of:))
        guard !names.isEmpty else {
            model.toasts.show(String(localized: "所选条目没有期刊名"), systemImage: "questionmark.circle")
            return
        }
        loadKeyIfNeeded()
        guard hasKey else {
            model.toasts.show(String(localized: "请先在设置中填写 easyScholar 密钥"), systemImage: "key",
                              actionTitle: String(localized: "设置…")) { Self.openSettings() }
            return
        }
        if case .invalidKey = status.problem {
            model.toasts.show(String(localized: "easyScholar 密钥无效"), systemImage: "exclamationmark.triangle",
                              actionTitle: String(localized: "设置…")) { Self.openSettings() }
            return
        }
        let service = currentService()
        Task { await service?.enqueue(names, force: true) }
        model.toasts.show(String(localized: "正在刷新期刊指标…"), systemImage: "arrow.clockwise")
    }

    /// Whether an item's journal is waiting to be looked up (the inspector says so instead of nothing).
    func isPending(_ item: Item) -> Bool {
        guard hasKey, status.pending > 0, JournalMetrics.journalName(of: item) != nil else { return false }
        return model?.snapshot.journalMetrics(for: item) == nil
    }

    // MARK: 测试

    /// Looks up "Nature" with `value` and says what came back.
    func test(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            testState = .failure(String(localized: "请先填写密钥"))
            return
        }
        guard let service = currentService() else { return }
        testState = .testing
        Task {
            let started = ContinuousClock.now
            let state: TestState
            do {
                state = switch try await service.test(key: trimmed) {
                case .found(let ranks):
                    .success(String(localized: "连接成功：Nature \(JournalMetrics(ranks: ranks).summary)"))
                case .notIndexed:
                    .success(String(localized: "连接成功"))
                case .invalidKey:
                    .failure(String(localized: "密钥无效，请检查是否完整复制"))
                case .rateLimited:
                    .failure(String(localized: "请求过于频繁，请稍后再试"))
                case .failed(let message):
                    .failure(String(localized: "easyScholar 暂时无法使用（\(message)）"))
                }
            } catch {
                state = .failure(String(localized: "无法连接 easyScholar：\(error.localizedDescription)"))
            }
            // A check that ends in an instant reads as "nothing happened".
            try? await Task.sleep(until: started + .milliseconds(500))
            testState = state
            if case .success = state, trimmed != secretKey { saveKey(trimmed) }
        }
    }

    /// One line for 设置 about what is going on.
    var statusText: (text: String, tone: StatusBadge.Tone)? {
        switch status.problem {
        case .invalidKey: return (String(localized: "密钥无效，已停止获取"), .attention)
        case .network: if status.pending == 0 { return (String(localized: "网络不可用，稍后自动重试"), .attention) }
        case .service(let message): if status.pending == 0 { return (String(localized: "easyScholar 暂时无法使用（\(message)）"), .attention) }
        case nil: break
        }
        if status.pending > 0 { return (String(localized: "正在获取 \(status.pending) 个期刊的指标…"), .info) }
        return nil
    }

    static func openSettings() {
        AppDelegate.shared.showSettings(nil)
        AppDelegate.shared.settingsWindow?.select(pane: "retrieval")
    }
}
