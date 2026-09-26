import FolioCore
import Foundation

extension MetadataEngine {
    /// Identifies the paper in a PDF (META-02).
    ///
    /// Identifier lookups and title searches start together. A verified identifier result wins
    /// immediately; otherwise the best accepted search candidate is taken once every source has
    /// answered, or `searchGrace` after the first acceptable one arrived.
    public func resolve(pdfAt url: URL) async -> ResolveResult {
        guard let facts = PDFFacts.extract(from: url) else { return .notFound }
        let plan = LookupPlan(found: IdentifierExtractor.extract(from: facts))
        let guesses = TitleGuesser.guesses(from: facts)
        guard !plan.identifiers.isEmpty || !guesses.isEmpty else { return .notFound }
        let scorer = CandidateScorer(pageText: facts.firstPageText + "\n" + facts.secondPageText, guesses: guesses)
        let started = ContinuousClock.now
        let outcome = await Deadline.run(overallTimeout) {
            await self.identify(plan: plan, guesses: guesses, scorer: scorer, started: started)
        }
        return outcome ?? .networkError
    }

    typealias TraceableEvent = Event

    enum Event: Sendable {
        case identifier(FoundIdentifier, Result<Metadata?, SourceError>)
        case search(SourceKind, Result<[Metadata], SourceError>)
        case graceElapsed

        var traceDescription: String {
            switch self {
            case let .identifier(found, result): "id \(found.identifier) → \(result.map { $0?.title.prefix(40) ?? "nil" })"
            case let .search(source, result): "search \(source) → \(result.map { "\($0.count) records" })"
            case .graceElapsed: "grace elapsed"
            }
        }
    }

    /// Tallies why sources failed, to tell "not found" (final) from "could not ask" (retry later).
    private struct Tally {
        var answered = 0
        var searchesAnswered = 0
        var identifierFailedTransiently = false

        mutating func record(_ error: SourceError, identifier: Bool) {
            if error.isTransient {
                if identifier { identifierFailedTransiently = true }
            } else if error != .cancelled {
                answered += 1
                if !identifier { searchesAnswered += 1 }
            }
        }

        /// "Not found" is only final when every identifier lookup got an answer and at least two
        /// title searches did; otherwise the network is the likelier culprit.
        var outcomeWithoutMatch: ResolveResult {
            identifierFailedTransiently || searchesAnswered < 2 ? .networkError : .notFound
        }
    }

    private func identify(plan: LookupPlan, guesses: [String], scorer: CandidateScorer,
                          started: ContinuousClock.Instant) async -> ResolveResult {
        var tally = Tally()
        var accepted: [(candidate: Candidate, evaluation: CandidateScorer.Evaluation)] = []
        let rounds = min(guesses.count, Self.maxSearchRounds)

        for round in 0..<max(rounds, 1) {
            if round > 0 {
                let elapsed = ContinuousClock.now - started
                guard accepted.isEmpty, overallTimeout - elapsed >= Self.minimumTimeForRound else { break }
            }
            let includeIdentifiers = round == 0
            let guess = guesses.indices.contains(round) ? guesses[round] : nil
            let result = await runRound(plan: includeIdentifiers ? plan : nil, guess: guess,
                                        searchArxiv: !plan.pdfHasArxivID, scorer: scorer,
                                        tally: &tally, accepted: &accepted)
            if let result { return result }
            if !accepted.isEmpty { break }
        }
        guard let best = CandidateRanking.best(accepted, pdfHasArxivID: plan.pdfHasArxivID) else {
            return tally.outcomeWithoutMatch
        }
        return .found(await enriched(best.candidate))
    }

    /// One round: optional identifier lookups plus the four title searches for `guess`.
    /// Returns a result when an identifier lookup was verified; otherwise fills `accepted`.
    /// `searchArxiv` is false when the PDF carries an arXiv ID: its lookup already covers arXiv, and
    /// arXiv's one-request-per-second limit makes a second request there the slowest part of a batch.
    private func runRound(plan: LookupPlan?, guess: String?, searchArxiv: Bool, scorer: CandidateScorer, tally: inout Tally,
                          accepted: inout [(candidate: Candidate, evaluation: CandidateScorer.Evaluation)]) async -> ResolveResult? {
        await withTaskGroup(of: Event.self) { group in
            var pending = 0
            for found in plan?.identifiers ?? [] {
                pending += 1
                group.addTask { .identifier(found, await self.lookup(found.identifier)) }
            }
            if let guess {
                let sources: [SourceKind] = searchArxiv ? [.crossref, .openAlex, .dblp, .arxiv] : [.crossref, .openAlex, .dblp]
                for source in sources {
                    pending += 1
                    group.addTask { .search(source, await self.titleSearch(source, title: guess)) }
                }
            }
            var graceStarted = false
            let roundStart = ContinuousClock.now
            while pending > 0, let event = await group.next() {
                Trace.log(roundStart, event: event)
                switch event {
                case .graceElapsed:
                    group.cancelAll()
                    return nil
                case let .identifier(found, result):
                    pending -= 1
                    switch result {
                    case .success(let metadata?):
                        tally.answered += 1
                        if scorer.verifiesIdentifierResult(metadata, selfDescribing: found.isSelfDescribing) {
                            group.cancelAll()
                            return .found(metadata)
                        }
                    case .success(nil):
                        tally.answered += 1
                    case .failure(let error):
                        tally.record(error, identifier: true)
                    }
                case let .search(source, result):
                    pending -= 1
                    switch result {
                    case .success(let records):
                        tally.answered += 1
                        tally.searchesAnswered += 1
                        for metadata in records {
                            let evaluation = scorer.evaluate(metadata)
                            if evaluation.isAccepted {
                                accepted.append((Candidate(metadata: metadata, source: source), evaluation))
                            }
                        }
                    case .failure(let error):
                        tally.record(error, identifier: false)
                    }
                }
                if !accepted.isEmpty && !graceStarted && pending > 0 {
                    graceStarted = true
                    let grace = searchGrace
                    group.addTask {
                        try? await Task.sleep(for: grace)
                        return .graceElapsed
                    }
                }
            }
            group.cancelAll()
            return nil
        }
    }

    /// DBLP and OpenAlex records carrying a DOI are completed from Crossref (volume, pages,
    /// abstract…), keeping fields Crossref lacks.
    func enriched(_ candidate: Candidate) async -> Metadata {
        var metadata = candidate.metadata
        guard candidate.source == .dblp || candidate.source == .openAlex, let doi = metadata.doi,
              IdentifierExtractor.arxivID(fromDOI: doi) == nil else { return metadata }
        let lookup = await Deadline.run(.seconds(3)) { try? await self.crossref.work(doi: doi) }
        guard let full = lookup ?? nil, TitleNormalizer.similarity(full.title, metadata.title) >= 0.9 else {
            return metadata
        }
        let abstract = metadata.abstract
        metadata = full
        if metadata.abstract == nil { metadata.abstract = abstract }
        if metadata.authors.isEmpty { metadata.authors = candidate.metadata.authors }
        return metadata
    }

    // MARK: - Manual matching (META-07)

    /// Identifier or free-text search across sources, deduplicated and ranked by title
    /// similarity to `query`. At most 10 results.
    public func search(query: String) async -> [Metadata] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        if let identifier = Identifier.parse(text) {
            let result = await Deadline.run(overallTimeout) { await self.lookup(identifier) }
            if case .success(let metadata?)? = result { return [metadata] }
            return []
        }
        let batches: [[Metadata]] = await Deadline.run(overallTimeout) { () async -> [[Metadata]] in
            await withTaskGroup(of: [Metadata].self) { group -> [[Metadata]] in
                for source in [SourceKind.crossref, .openAlex, .dblp, .arxiv] {
                    group.addTask { (try? await self.titleSearch(source, title: text, limit: 6).get()) ?? [] }
                }
                var all: [[Metadata]] = []
                for await batch in group { all.append(batch) }
                return all
            }
        } ?? []
        var unique: [Metadata] = []
        for record in batches.flatMap({ $0 }) where !unique.contains(where: { DuplicateMatcher.isSameWork($0, record) }) {
            unique.append(record)
        }
        return Array(unique
            .map { ($0, TitleNormalizer.similarity($0.title, text)) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
            .prefix(10))
    }
}


/// Timing trace for tuning; enabled with `FOLIO_TRACE=1`.
enum Trace {
    static let enabled = ProcessInfo.processInfo.environment["FOLIO_TRACE"] == "1"

    fileprivate static func log(_ start: ContinuousClock.Instant, event: MetadataEngine.TraceableEvent) {
        guard enabled else { return }
        print(String(format: "  +%.2fs %@", Double((ContinuousClock.now - start).components.attoseconds) / 1e18
                     + Double((ContinuousClock.now - start).components.seconds), event.traceDescription))
    }
}
