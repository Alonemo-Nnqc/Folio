import FolioCore
import Foundation

/// Retrieves bibliographic metadata for PDFs, identifiers and free-text queries from open
/// sources (Crossref, DOI content negotiation, arXiv, OpenAlex, DBLP, Open Library).
///
/// Thread-safe; keep one instance for the whole app so HTTP connections and the per-host
/// request throttle are shared.
public final class MetadataEngine: Sendable {
    let configuration: MetadataEngineConfiguration
    let crossref: CrossrefClient
    let negotiation: DOIContentNegotiationClient
    let arxiv: ArxivClient
    let openAlex: OpenAlexClient
    let dblp: DBLPClient
    let openLibrary: OpenLibraryClient
    /// How long to keep waiting for a better-ranked source once an acceptable match is in hand.
    let searchGrace: Duration

    /// Search rounds with successive title guesses when the first guess finds nothing.
    static let maxSearchRounds = 2
    /// A further search round is only started when at least this much time remains.
    static let minimumTimeForRound: Duration = .milliseconds(2500)

    public convenience init(configuration: MetadataEngineConfiguration = .init(), http: (any HTTPClient)? = nil) {
        self.init(configuration: configuration,
                  http: http ?? URLSessionHTTPClient(timeout: configuration.requestTimeout),
                  throttle: .shared)
    }

    init(configuration: MetadataEngineConfiguration, http: any HTTPClient, throttle: HostThrottle,
         searchGrace: Duration = .milliseconds(800)) {
        self.configuration = configuration
        let transport = Transport(http: http, throttle: throttle, mailto: configuration.mailto)
        crossref = CrossrefClient(transport: transport, mailto: FieldNormalizer.nonEmpty(configuration.mailto))
        negotiation = DOIContentNegotiationClient(transport: transport)
        arxiv = ArxivClient(transport: transport)
        openAlex = OpenAlexClient(transport: transport, mailto: FieldNormalizer.nonEmpty(configuration.mailto))
        dblp = DBLPClient(transport: transport)
        openLibrary = OpenLibraryClient(transport: transport)
        self.searchGrace = searchGrace
    }

    var overallTimeout: Duration {
        .milliseconds(Int64(max(configuration.overallTimeout, 0.1) * 1000))
    }

    // MARK: - Identifiers

    /// Resolves a DOI, arXiv ID or ISBN (bare, prefixed or as URL).
    public func resolve(identifier: String) async -> ResolveResult {
        guard let parsed = Identifier.parse(identifier) else { return .notFound }
        guard let result = await Deadline.run(overallTimeout, { await self.lookup(parsed) }) else {
            return .networkError
        }
        switch result {
        case .success(let metadata?): return .found(metadata)
        case .success(nil): return .notFound
        case .failure(let error): return error.isTransient ? .networkError : .notFound
        }
    }

    /// Looks one identifier up at the source that owns it.
    func lookup(_ identifier: Identifier) async -> Result<Metadata?, SourceError> {
        do {
            switch identifier {
            case .doi(let doi):
                if let arxivID = IdentifierExtractor.arxivID(fromDOI: doi) {
                    return .success(try await arxiv.lookup(id: arxivID))
                }
                do {
                    if let record = try await crossref.work(doi: doi) { return .success(record) }
                } catch .unavailable {
                    // Crossref is struggling; content negotiation goes through other infrastructure.
                }
                // Not a Crossref DOI (DataCite, mEDRA, …): ask the resolver.
                return .success(try await negotiation.lookup(doi: doi))
            case .arxiv(let id):
                return .success(try await arxiv.lookup(id: id))
            case .isbn(let isbn):
                return .success(try await openLibrary.lookup(isbn: isbn))
            }
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Title search

    /// Runs one source's title search.
    func titleSearch(_ source: SourceKind, title: String, limit: Int = 5) async -> Result<[Metadata], SourceError> {
        do {
            switch source {
            case .crossref: return .success(try await crossref.search(title: title, rows: limit))
            case .openAlex: return .success(try await openAlex.search(title: title, perPage: limit))
            case .dblp: return .success(try await dblp.search(title: title, hits: limit))
            case .arxiv: return .success(try await arxiv.search(title: title, maxResults: limit))
            case .doiNegotiation, .openLibrary: return .success([])
            }
        } catch {
            return .failure(error)
        }
    }
}
