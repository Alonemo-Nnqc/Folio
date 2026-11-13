import Foundation

/// A token a free service hands out for a while (Bing's translator session, Edge's bearer token).
///
/// Everyone asking at the same moment shares one fetch (a warm-up and the translation that follows it never fetch
/// twice), and while the token is in use it is fetched again in the background `renewBefore` seconds before it runs out,
/// so no translation has to wait for a token after the first.
actor TokenStore<Value: Sendable> {
    typealias Fetch = @Sendable () async throws -> (value: Value, lifetime: TimeInterval)

    private let fetch: Fetch
    /// How long before it runs out a token in use is renewed.
    let renewBefore: TimeInterval
    /// A token nobody has used for this long is left to run out.
    let idleAfter: TimeInterval

    private var value: Value?
    private var expiry = Date.distantPast
    private var lastUse = Date.distantPast
    private var inFlight: Task<(value: Value, lifetime: TimeInterval), Error>?
    private var renewal: Task<Void, Never>?
    /// Fetches made (for tests).
    private(set) var fetches = 0

    init(renewBefore: TimeInterval = 60, idleAfter: TimeInterval = 15 * 60, fetch: @escaping Fetch) {
        self.fetch = fetch
        self.renewBefore = renewBefore
        self.idleAfter = idleAfter
    }

    /// The current token, fetched first if there is none or it has run out.
    func get() async throws -> Value {
        lastUse = Date()
        if let value, Date() < expiry { return value }
        return try await load()
    }

    /// The token if one is at hand, without fetching.
    func cached() -> Value? {
        if let value, Date() < expiry { return value }
        return nil
    }

    /// The service refused the token: the next request fetches another.
    func invalidate() {
        value = nil
        expiry = .distantPast
        renewal?.cancel()
    }

    private func load() async throws -> Value {
        if let inFlight { return try await inFlight.value.value }
        let fetch = self.fetch
        let task = Task { try await fetch() }
        inFlight = task
        fetches += 1
        do {
            let result = try await task.value
            inFlight = nil
            let lifetime = max(result.lifetime, 10)
            value = result.value
            expiry = Date().addingTimeInterval(lifetime)
            scheduleRenewal(in: lifetime - renewBefore)
            return result.value
        } catch {
            inFlight = nil
            throw error
        }
    }

    private func scheduleRenewal(in seconds: TimeInterval) {
        renewal?.cancel()
        renewal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(seconds, 1)))
            guard !Task.isCancelled else { return }
            await self?.renewIfInUse()
        }
    }

    private func renewIfInUse() async {
        guard Date().timeIntervalSince(lastUse) < idleAfter else { return }
        _ = try? await load()
    }
}

enum JWT {
    /// Seconds until a JSON Web Token's `exp`, nil when it has none.
    static func lifetime(_ token: String) -> TimeInterval? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = (object["exp"] as? NSNumber)?.doubleValue else { return nil }
        return exp - Date().timeIntervalSince1970
    }
}
