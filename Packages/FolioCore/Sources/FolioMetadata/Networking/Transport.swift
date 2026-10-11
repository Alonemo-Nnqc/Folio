import Foundation

/// Sends requests for the source clients: adds headers, honours per-host throttling and
/// maps every failure to a `SourceError`.
struct Transport: Sendable {
    let http: any HTTPClient
    let throttle: HostThrottle
    let userAgent: String

    init(http: any HTTPClient, throttle: HostThrottle, mailto: String?) {
        self.http = http
        self.throttle = throttle
        if let mailto = FieldNormalizer.nonEmpty(mailto) {
            userAgent = "Folio/1.0 (mailto:\(mailto))"
        } else {
            userAgent = "Folio/1.0"
        }
    }

    /// Returns the body for 2xx, nil for 404/410, throws otherwise.
    func get(_ url: URL, accept: String = "application/json") async throws(SourceError) -> Data? {
        if Task.isCancelled { throw .cancelled }
        if let host = url.host(), let slot = await throttle.reserve(host: host) {
            do {
                try await Task.sleep(until: slot, clock: .continuous)
            } catch {
                throw .cancelled
            }
        }
        return try await perform {
            try await http.get(url, headers: ["User-Agent": userAgent, "Accept": accept])
        }
    }

    /// POSTs a JSON body; same status handling as `get`.
    func post(_ url: URL, json body: Data, accept: String = "application/json") async throws(SourceError) -> Data? {
        if Task.isCancelled { throw .cancelled }
        return try await perform {
            try await http.post(url, body: body, headers: [
                "User-Agent": userAgent, "Accept": accept, "Content-Type": "application/json",
            ])
        }
    }

    /// Runs one request and maps transport failures and statuses to `SourceError`.
    private func perform(_ request: () async throws -> (Data, Int)) async throws(SourceError) -> Data? {
        let response: (Data, Int)
        do {
            response = try await request()
        } catch let error as URLError {
            throw error.code == .cancelled ? .cancelled : .network
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw Task.isCancelled ? .cancelled : .rejected(status: 0)
        }
        let (data, status) = response
        switch status {
        case 200..<300: return data
        case 404, 410: return nil
        case 429, 500...599: throw .unavailable(status: status)
        default: throw .rejected(status: status)
        }
    }

    /// Like `get`, then decodes JSON; undecodable bodies become `.malformed`.
    func getJSON<T: Decodable>(_ type: T.Type, from url: URL, accept: String = "application/json")
        async throws(SourceError) -> T? {
        guard let data = try await get(url, accept: accept) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw .malformed
        }
    }
}

extension URL {
    /// Builds `base` with the given query items (nil values skipped), percent-encoding as needed.
    static func make(_ base: String, query: [(String, String?)] = []) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        let items = query.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
        if !items.isEmpty { components.queryItems = items }
        // URLComponents leaves "+" alone, which servers decode as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}
