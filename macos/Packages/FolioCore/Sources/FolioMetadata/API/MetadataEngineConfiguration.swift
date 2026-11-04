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
    /// Also sends the layout of a PDF's first five pages (words, positions, fonts) to Zotero's
    /// recognizer service (`services.zotero.org`). When false, no data leaves for Zotero and
    /// `resolve(pdfAt:)` behaves exactly as without the service.
    public var useZoteroRecognizer: Bool = true

    public init() {}
}
