import Foundation

/// Why one request to a metadata source produced no usable answer.
enum SourceError: Error, Sendable, Equatable {
    /// No HTTP response at all (offline, DNS, timeout, TLS): a `URLError`.
    case network
    /// The server answered with a status that should succeed later (429, 5xx).
    case unavailable(status: Int)
    /// The server answered definitively without usable data (other 4xx, unexpected status).
    case rejected(status: Int)
    /// The body could not be decoded (e.g. an HTML bot wall instead of JSON).
    case malformed
    /// The request was cancelled because the engine no longer needed it.
    case cancelled

    /// Failures that say nothing about the paper and are worth retrying once the network is back.
    var isTransient: Bool {
        switch self {
        case .network, .unavailable: true
        case .rejected, .malformed, .cancelled: false
        }
    }
}
