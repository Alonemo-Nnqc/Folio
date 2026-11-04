import Foundation

/// Minimal HTTP abstraction so the engine can be tested without the network.
///
/// Implementations return the response body and HTTP status code. Transport failures
/// (offline, DNS, timeout, TLS) must be thrown as `URLError`; the engine uses that to tell
/// network problems apart from "the server answered but had nothing".
public protocol HTTPClient: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> (Data, Int)
    /// Sends `body` with POST. Only the Zotero recognizer uses it; clients that do not
    /// implement it make that optional source fail quietly.
    func post(_ url: URL, body: Data, headers: [String: String]) async throws -> (Data, Int)
}

extension HTTPClient {
    public func post(_ url: URL, body: Data, headers: [String: String]) async throws -> (Data, Int) {
        throw URLError(.unsupportedURL)
    }
}
