import FolioCore
import Foundation

/// What Zotero's recognizer contributed while a PDF is being resolved.
///
/// Its results rank below the PDF's own (self-describing) identifiers and above title-search
/// candidates: verified lookups of identifiers it named first, then its own fields when their
/// title is verified against the page. Nothing here ever counts towards the "not found" tally.
struct RecognizerState: Sendable {
    /// The service's answer, once it arrived.
    var response: RecognizerResponse?
    /// The answer's own fields, when the title was verified against the page.
    var fields: Metadata?
    /// Verified lookups of identifiers the answer named, with their preference rank (lower wins).
    var verified: [(rank: Int, metadata: Metadata)] = []
    /// Lookups of identifiers the answer named that are still running.
    var pendingLookups = 0

    var bestVerified: Metadata? {
        verified.min { $0.rank < $1.rank }?.metadata
    }

    var hasResult: Bool { fields != nil || !verified.isEmpty }

    /// Like `CandidateRanking`: the published version first, unless the PDF itself is an arXiv preprint.
    static func rank(of identifier: Identifier, pdfHasArxivID: Bool) -> Int {
        switch identifier {
        case .doi: pdfHasArxivID ? 1 : 0
        case .arxiv: pdfHasArxivID ? 0 : 1
        case .isbn: 2
        }
    }

    /// The answer's identifiers that are worth a lookup: canonical (arXiv DOIs become arXiv IDs),
    /// deduplicated and not already part of the PDF's own lookup plan.
    static func lookups(for response: RecognizerResponse, excluding planned: [Identifier]) -> [Identifier] {
        var result: [Identifier] = []
        for identifier in (response.identifiers.map(canonical)) {
            guard !result.contains(identifier), !planned.map(canonical).contains(identifier) else { continue }
            result.append(identifier)
        }
        return result
    }

    static func canonical(_ identifier: Identifier) -> Identifier {
        if case .doi(let doi) = identifier, let arxivID = IdentifierExtractor.arxivID(fromDOI: doi) {
            return .arxiv(arxivID)
        }
        return identifier
    }

    /// Fills in an abstract the record lacks from the recognizer's answer about the same work.
    func enriched(_ metadata: Metadata) -> Metadata {
        guard metadata.abstract == nil, let response, let abstract = FieldNormalizer.cleanAbstract(response.abstract),
              let title = response.title, TitleNormalizer.similarity(title, metadata.title) >= 0.9 else { return metadata }
        var metadata = metadata
        metadata.abstract = abstract
        return metadata
    }

    /// Whether a search record describes the same work as the recognizer's fields, so that the
    /// (usually richer) search record can stand in for them.
    static func isSameWork(_ record: Metadata, as fields: Metadata) -> Bool {
        guard TitleNormalizer.similarity(record.title, fields.title) >= 0.95 else { return false }
        if let a = record.year, let b = fields.year, abs(a - b) > 1 { return false }
        if let a = record.doi, let b = fields.doi, a != b { return false }
        return true
    }
}
