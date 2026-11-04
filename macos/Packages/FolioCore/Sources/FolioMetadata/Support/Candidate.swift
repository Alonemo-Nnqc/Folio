import FolioCore

/// The metadata source a record came from.
enum SourceKind: String, Sendable, CaseIterable {
    case crossref, doiNegotiation, arxiv, openAlex, dblp, openLibrary
}

/// A record returned by a source, before scoring.
struct Candidate: Sendable, Equatable {
    var metadata: Metadata
    var source: SourceKind
}
