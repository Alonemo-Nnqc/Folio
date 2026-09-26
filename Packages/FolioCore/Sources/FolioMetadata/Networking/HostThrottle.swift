import Foundation

/// Enforces a minimum interval between requests to the same host.
///
/// Slots are handed out atomically, so concurrent callers queue up behind each other
/// instead of all firing once the interval has passed.
actor HostThrottle {
    /// arXiv asks API clients for at most one request every few seconds; one second keeps
    /// bursts polite while staying within the latency budget.
    static let shared = HostThrottle(minimumIntervals: ["export.arxiv.org": .seconds(1)])

    private let minimumIntervals: [String: Duration]
    private var nextFree: [String: ContinuousClock.Instant] = [:]

    init(minimumIntervals: [String: Duration]) {
        self.minimumIntervals = minimumIntervals
    }

    /// Reserves the next slot for `host`; returns the instant to wait for, or nil to go right away.
    func reserve(host: String) -> ContinuousClock.Instant? {
        let host = host.lowercased()
        guard let interval = minimumIntervals[host], interval > .zero else { return nil }
        let now = ContinuousClock.now
        let slot = max(now, nextFree[host] ?? now)
        nextFree[host] = slot + interval
        return slot > now ? slot : nil
    }
}
