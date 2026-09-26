import Foundation

/// Tunables for `MetadataEngine`.
public struct MetadataEngineConfiguration: Sendable {
    /// Contact address for the Crossref / OpenAlex "polite pool"; also sent in the User-Agent.
    public var mailto: String? = nil
    /// Optional OpenAlex API key; without one OpenAlex is best-effort (shared per-IP budget).
    public var openAlexAPIKey: String? = nil
    /// Timeout of a single HTTP request, in seconds.
    public var requestTimeout: TimeInterval = 6
    /// Upper bound for one `resolve`/`search` call, in seconds.
    public var overallTimeout: TimeInterval = 15

    public init() {}
}
