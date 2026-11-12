import FolioCore
import Foundation

/// Fetches journal ranks from easyScholar into the library's cache (META-30).
///
/// One journal at a time, at least `interval` apart (easyScholar allows two requests a second). Answers — "not
/// listed" included — are cached for 30 days, so each journal is asked about once. A refused key stops everything
/// until the key changes; network trouble pauses the queue for `retryDelay`; a journal whose lookups keep failing is
/// left alone for the session after `maximumAttempts`.
public actor JournalMetricsService {
    public enum Problem: Sendable, Equatable {
        case invalidKey(String)
        case network(String)
        case service(String)
    }

    public struct Status: Sendable, Equatable {
        /// Journals waiting or being looked up.
        public var pending = 0
        public var problem: Problem?
        public init(pending: Int = 0, problem: Problem? = nil) {
            self.pending = pending
            self.problem = problem
        }
    }

    private struct Job: Sendable {
        var key: String
        var name: String
        var force: Bool
    }

    public let library: Library
    private let client: EasyScholarClient
    private let interval: Duration
    private let retryDelay: Duration
    private let maximumAttempts: Int
    private let onStatus: @Sendable (Status) -> Void

    private var secretKey: String?
    private var queue: [Job] = []
    private var failures: [String: (count: Int, notBefore: ContinuousClock.Instant)] = [:]
    private var pausedUntil: ContinuousClock.Instant?
    private var problem: Problem?
    private var worker: Task<Void, Never>?
    private var generation = 0
    private var current: String?
    private var nextSlot: ContinuousClock.Instant?
    private var unsaved: [(name: String, metrics: JournalMetrics)] = []
    private var lastSave = ContinuousClock.now

    public init(library: Library, client: EasyScholarClient = EasyScholarClient(), interval: Duration = .milliseconds(600),
                retryDelay: Duration = .seconds(600), maximumAttempts: Int = 3,
                onStatus: @escaping @Sendable (Status) -> Void = { _ in }) {
        self.library = library
        self.client = client
        self.interval = interval
        self.retryDelay = retryDelay
        self.maximumAttempts = maximumAttempts
        self.onStatus = onStatus
    }

    public var status: Status { Status(pending: queue.count + (current == nil ? 0 : 1), problem: problem) }

    /// A new (or removed) key starts over: earlier refusals and failures no longer apply.
    public func setKey(_ key: String?) {
        let key = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = key?.isEmpty == false ? key : nil
        guard normalized != secretKey else { return }
        secretKey = normalized
        problem = nil
        failures = [:]
        pausedUntil = nil
        if secretKey == nil { queue.removeAll() }
        report()
        startIfNeeded()
    }

    /// Adds journals to look up. `force` (the user's "刷新期刊指标") asks again even when the cache is fresh, goes
    /// first and ignores earlier failures.
    public func enqueue(_ names: [String], force: Bool = false) {
        guard secretKey != nil else { return }
        if case .invalidKey = problem { return }
        let now = ContinuousClock.now
        if !force, let pausedUntil, now < pausedUntil { return }
        var known = Set(queue.map(\.key))
        if let current { known.insert(current) }
        var added: [Job] = []
        for name in names {
            let key = JournalMetrics.key(for: name)
            guard !key.isEmpty else { continue }
            if force {
                failures[key] = nil
                queue.removeAll { $0.key == key }
                if key != current { added.append(Job(key: key, name: JournalMetrics.queryName(for: name), force: true)) }
                continue
            }
            guard !known.contains(key) else { continue }
            if let failure = failures[key], failure.count >= maximumAttempts || now < failure.notBefore { continue }
            known.insert(key)
            added.append(Job(key: key, name: JournalMetrics.queryName(for: name), force: false))
        }
        guard !added.isEmpty else { return }
        if force { queue.insert(contentsOf: added, at: 0) } else { queue.append(contentsOf: added) }
        report()
        startIfNeeded()
    }

    /// Stops and forgets what is queued (another library opened, auto fetch turned off).
    public func cancelAll() {
        queue.removeAll()
        worker?.cancel()
        worker = nil
        generation += 1
        current = nil
        flush()
        report()
    }

    /// Waits until the queue is empty (tests).
    public func idle() async {
        while let worker { await worker.value }
    }

    /// "测试": one lookup with `key` (not necessarily the saved one), in turn with the queue.
    public func test(key: String, journal: String = "Nature") async throws -> EasyScholarResult {
        await waitForSlot()
        return try await client.lookup(journal, secretKey: key.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Worker

    private func startIfNeeded() {
        guard worker == nil, !queue.isEmpty, secretKey != nil else { return }
        generation += 1
        let run = self.generation
        worker = Task { [weak self] in await self?.run(run) }
    }

    private func run(_ generation: Int) async {
        var rateLimitedInARow = 0
        while !Task.isCancelled, generation == self.generation, !queue.isEmpty, let key = secretKey {
            let job = queue.removeFirst()
            current = job.key
            report()
            await waitForSlot()
            guard !Task.isCancelled, generation == self.generation, secretKey == key else { break }
            do {
                let result = try await client.lookup(job.name, secretKey: key)
                guard generation == self.generation, secretKey == key else { break }
                switch result {
                case .found(let ranks):
                    rateLimitedInARow = 0
                    store(job, JournalMetrics(ranks: ranks))
                    if case .service = problem { problem = nil }
                case .notIndexed:
                    rateLimitedInARow = 0
                    store(job, JournalMetrics(ranks: [:]))
                case .invalidKey(let message):
                    problem = .invalidKey(message)
                    queue.removeAll()
                case .rateLimited:
                    rateLimitedInARow += 1
                    if rateLimitedInARow <= 5 {
                        queue.insert(job, at: 0)
                        nextSlot = max(nextSlot ?? .now, .now) + .seconds(rateLimitedInARow * 2)
                    } else {
                        fail(job, .service("too many requests"))
                        rateLimitedInARow = 0
                    }
                case .failed(let message):
                    fail(job, .service(message))
                }
            } catch {
                // Offline, DNS, timeout: everything else would fail the same way; try again later.
                fail(job, .network(error.localizedDescription))
                pausedUntil = .now + retryDelay
                queue.removeAll { !$0.force }
            }
            if generation == self.generation { current = nil }
            if queue.isEmpty || job.force || unsaved.count >= 10 || ContinuousClock.now - lastSave > .seconds(2) { flush() }
            report()
        }
        flush()
        guard generation == self.generation else { return }
        current = nil
        worker = nil
        report()
        // A job forced while the last one finished.
        startIfNeeded()
    }

    private func store(_ job: Job, _ metrics: JournalMetrics) {
        failures[job.key] = nil
        unsaved.append((job.key, metrics))
    }

    private func fail(_ job: Job, _ problem: Problem) {
        let count = (failures[job.key]?.count ?? 0) + 1
        failures[job.key] = (count, .now + retryDelay)
        self.problem = problem
    }

    private func flush() {
        lastSave = .now
        guard !unsaved.isEmpty else { return }
        let entries = unsaved
        unsaved.removeAll()
        try? library.saveJournalMetrics(entries)
    }

    /// Reserves the next request slot, `interval` after the previous one, and waits for it.
    private func waitForSlot() async {
        let now = ContinuousClock.now
        let slot = max(now, nextSlot ?? now)
        nextSlot = slot + interval
        if slot > now { try? await Task.sleep(until: slot, clock: .continuous) }
    }

    private func report() {
        onStatus(status)
    }

    // MARK: What needs fetching

    /// Journals of the library whose ranks were never fetched or are older than 30 days, most recently changed
    /// items first, each once.
    public static func staleJournals(in snapshot: LibrarySnapshot, now: Date = Date()) -> [String] {
        // Runs after every snapshot: one pass, and sorting only what is stale.
        var stale: [String: (name: String, modified: Date)] = [:]
        for item in snapshot.items.values where !item.isTrashed {
            guard let name = JournalMetrics.journalName(of: item) else { continue }
            let key = JournalMetrics.key(for: name)
            if let cached = snapshot.journalMetrics[key], cached.isFresh(now: now) { continue }
            if let known = stale[key], known.modified >= item.dateModified { continue }
            stale[key] = (name, item.dateModified)
        }
        return stale.values.sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.name < $1.name }.map(\.name)
    }
}
