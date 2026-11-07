import FolioCore

/// Orders accepted candidates: formally published version with DOI > DBLP record > preprint,
/// except that a PDF carrying an arXiv identifier prefers the arXiv record.
enum CandidateRanking {
    static func tier(of candidate: Candidate, pdfHasArxivID: Bool) -> Int {
        let metadata = candidate.metadata
        let isPreprint = metadata.type == .preprint || metadata.arxivId != nil
            || (metadata.doi.map { IdentifierExtractor.arxivID(fromDOI: $0) != nil } ?? false)
        if pdfHasArxivID {
            return isPreprint && metadata.arxivId != nil ? 0 : (metadata.doi != nil ? 1 : 2)
        }
        if !isPreprint, metadata.doi != nil { return 0 }
        if !isPreprint, candidate.source == .dblp { return 1 }
        return isPreprint ? 3 : 2
    }

    static func best(_ accepted: [(candidate: Candidate, evaluation: CandidateScorer.Evaluation)],
                     pdfHasArxivID: Bool) -> (candidate: Candidate, evaluation: CandidateScorer.Evaluation)? {
        accepted.min { lhs, rhs in
            let lt = tier(of: lhs.candidate, pdfHasArxivID: pdfHasArxivID)
            let rt = tier(of: rhs.candidate, pdfHasArxivID: pdfHasArxivID)
            if lt != rt { return lt < rt }
            let ls = lhs.evaluation.titleSimilarity, rs = rhs.evaluation.titleSimilarity
            if ls != rs { return ls > rs }
            return completeness(lhs.candidate.metadata) > completeness(rhs.candidate.metadata)
        }
    }

    /// Tie-breaker between equally good records: the one with more filled-in fields.
    static func completeness(_ metadata: Metadata) -> Int {
        let fields: [Any?] = [metadata.year, metadata.source, metadata.volume, metadata.issue, metadata.pages,
                              metadata.publisher, metadata.doi, metadata.abstract]
        return fields.count { $0 != nil } + min(metadata.authors.count, 3)
    }
}
