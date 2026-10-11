import FolioCore
import Foundation

extension MetadataEngine {
    /// Identifies the paper in a PDF (META-02).
    ///
    /// Identifier lookups, title searches and (optionally) Zotero's recognizer start together.
    /// A verified lookup of an identifier the PDF names wins immediately; identifiers the recognizer
    /// named come next, then the recognizer's own verified fields, then the best accepted search
    /// candidate. Search candidates are taken once every source has answered, or `searchGrace`
    /// after the first acceptable result arrived.
    public func resolve(pdfAt url: URL) async -> ResolveResult {
        guard let facts = autoreleasepool(invoking: { PDFFacts.extract(from: url) }) else { return .notFound }
        let plan = LookupPlan(found: IdentifierExtractor.extract(from: facts))
        let guesses = TitleGuesser.guesses(from: facts)
        guard !plan.identifiers.isEmpty || !guesses.isEmpty else { return .notFound }
        let scorer = CandidateScorer(pageText: facts.firstPageText + "\n" + facts.secondPageText, guesses: guesses)
        let cvfLookup = CVFLookup.detect(facts, guesses: guesses)
        // A scanned page recognised with OCR has no text layer to describe to the service.
        let recognizerPDF = configuration.useZoteroRecognizer && !facts.usedOCR ? url : nil
        let started = ContinuousClock.now
        let outcome = await Deadline.run(overallTimeout) {
            await self.identify(plan: plan, guesses: guesses, cvf: cvfLookup, recognizerPDF: recognizerPDF,
                                scorer: scorer, started: started)
        }
        return outcome ?? .networkError
    }

    typealias TraceableEvent = Event

    enum Event: Sendable {
        case identifier(FoundIdentifier, Result<Metadata?, SourceError>)
        case search(SourceKind, Result<[Metadata], SourceError>)
        case cvf(Result<Metadata?, SourceError>)
        /// Zotero's recognizer answered (or failed, or ran out of time).
        case recognizer(Result<RecognizerResponse?, SourceError>)
        /// Lookup of an identifier the recognizer named.
        case recognizerLookup(Identifier, Result<Metadata?, SourceError>)
        case graceElapsed

        var traceDescription: String {
            switch self {
            case let .identifier(found, result): "id \(found.identifier) → \(result.map { $0?.title.prefix(40) ?? "nil" })"
            case let .search(source, result): "search \(source) → \(result.map { "\($0.count) records" })"
            case let .cvf(result): "cvf → \(result.map { $0?.title.prefix(40) ?? "nil" })"
            case let .recognizer(result):
                "recognizer → \(result.map { "\($0?.identifiers ?? []) \($0?.title?.prefix(40) ?? "nil")" })"
            case let .recognizerLookup(identifier, result):
                "recognizer id \(identifier) → \(result.map { $0?.title.prefix(40) ?? "nil" })"
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

    private func identify(plan: LookupPlan, guesses: [String], cvf: CVFLookup?, recognizerPDF: URL?,
                          scorer: CandidateScorer, started: ContinuousClock.Instant) async -> ResolveResult {
        var tally = Tally()
        var accepted: [(candidate: Candidate, evaluation: CandidateScorer.Evaluation)] = []
        var recognizer = RecognizerState()
        let rounds = min(guesses.count, Self.maxSearchRounds)

        for round in 0..<max(rounds, 1) {
            if round > 0 {
                let elapsed = ContinuousClock.now - started
                guard accepted.isEmpty, overallTimeout - elapsed >= Self.minimumTimeForRound else { break }
            }
            let firstRound = round == 0
            let guess = guesses.indices.contains(round) ? guesses[round] : nil
            let result = await runRound(plan: firstRound ? plan : nil, guess: guess, cvf: firstRound ? cvf : nil,
                                        recognizerPDF: firstRound ? recognizerPDF : nil,
                                        pdfHasArxivID: plan.pdfHasArxivID, scorer: scorer,
                                        tally: &tally, accepted: &accepted, recognizer: &recognizer)
            if case .found(let metadata)? = result { return .found(recognizer.enriched(metadata)) }
            if let result { return result }
            if !accepted.isEmpty || recognizer.hasResult { break }
        }
        if let metadata = recognizer.bestVerified { return .found(recognizer.enriched(metadata)) }
        let best = CandidateRanking.best(accepted, pdfHasArxivID: plan.pdfHasArxivID)
        if let fields = recognizer.fields {
            // A search record of the same work usually carries more (DOI, venue details); a
            // different work is outranked by the recognizer.
            if let best, RecognizerState.isSameWork(best.candidate.metadata, as: fields) {
                return .found(recognizer.enriched(await enriched(best.candidate)))
            }
            return .found(fields)
        }
        guard let best else {
            // A CVF paper that no source knows yet (new, or a workshop paper): its own verified
            // title/author fields are still a trustworthy record.
            if let fallback = cvf?.fallback { return .found(fallback) }
            return tally.outcomeWithoutMatch
        }
        return .found(recognizer.enriched(await enriched(best.candidate)))
    }

    /// One round: optional identifier lookups and recognizer query plus the four title searches
    /// for `guess`. Returns a result when an identifier lookup was verified; otherwise fills
    /// `accepted` and `recognizer`.
    /// arXiv is not title-searched when the PDF carries an arXiv ID: its lookup already covers arXiv,
    /// and arXiv's one-request-per-second limit makes a second request there the slowest part of a batch.
    private func runRound(plan: LookupPlan?, guess: String?, cvf: CVFLookup?, recognizerPDF: URL?, pdfHasArxivID: Bool,
                          scorer: CandidateScorer, tally: inout Tally,
                          accepted: inout [(candidate: Candidate, evaluation: CandidateScorer.Evaluation)],
                          recognizer: inout RecognizerState) async -> ResolveResult? {
        await withTaskGroup(of: Event.self) { group in
            var pending = 0
            // Lookups the PDF itself points to (arXiv stamp, its own DOI, its CVF page) beat title-search
            // hits, so the grace period only starts once none of them is outstanding.
            var pendingAuthoritative = 0
            for found in plan?.identifiers ?? [] {
                pending += 1
                if found.isSelfDescribing { pendingAuthoritative += 1 }
                group.addTask { .identifier(found, await self.lookup(found.identifier)) }
            }
            if let cvf {
                pending += 1
                pendingAuthoritative += 1
                group.addTask {
                    do throws(SourceError) { return .cvf(.success(try await self.cvf.paper(for: cvf))) }
                    catch { return .cvf(.failure(error)) }
                }
            }
            if let recognizerPDF {
                pending += 1
                let budget = recognizerTimeout
                group.addTask {
                    let answer = await Deadline.run(budget) { () async -> Result<RecognizerResponse?, SourceError> in
                        guard let payload = RecognizerPayload.extract(from: recognizerPDF) else { return .success(nil) }
                        do throws(SourceError) { return .success(try await self.recognizer.recognize(payload)) }
                        catch { return .failure(error) }
                    }
                    return .recognizer(answer ?? .failure(.network))
                }
            }
            if let guess {
                let sources: [SourceKind] = pdfHasArxivID ? [.crossref, .openAlex, .dblp] : [.crossref, .openAlex, .dblp, .arxiv]
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
                    // Identifiers the recognizer named outrank search candidates: let their lookups finish.
                    if recognizer.pendingLookups > 0 {
                        graceStarted = false
                    } else {
                        group.cancelAll()
                        return nil
                    }
                case let .identifier(found, result):
                    pending -= 1
                    if found.isSelfDescribing { pendingAuthoritative -= 1 }
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
                case let .cvf(result):
                    pending -= 1
                    pendingAuthoritative -= 1
                    switch result {
                    case .success(let metadata?):
                        tally.answered += 1
                        // The page was addressed from this PDF's own title and author (self-describing).
                        if scorer.verifiesIdentifierResult(metadata, selfDescribing: true) {
                            group.cancelAll()
                            return .found(metadata)
                        }
                    case .success(nil):
                        tally.answered += 1
                    case .failure(let error):
                        tally.record(error, identifier: true)
                    }
                case let .recognizer(result):
                    pending -= 1
                    // Failures are deliberately not tallied: the service is optional.
                    guard case .success(let response?) = result else { break }
                    recognizer.response = response
                    if let fields = response.metadata, scorer.evaluate(fields).isAccepted {
                        recognizer.fields = fields
                    }
                    let planned = plan?.identifiers.map(\.identifier) ?? []
                    let budget = recognizerLookupTimeout
                    for identifier in RecognizerState.lookups(for: response, excluding: planned) {
                        pending += 1
                        recognizer.pendingLookups += 1
                        group.addTask {
                            let result = await Deadline.run(budget) { await self.lookup(identifier) }
                            return .recognizerLookup(identifier, result ?? .failure(.network))
                        }
                    }
                case let .recognizerLookup(identifier, result):
                    pending -= 1
                    recognizer.pendingLookups -= 1
                    // Same check as for identifiers found in the text: the title must be on the page.
                    if case .success(let metadata?) = result,
                       scorer.verifiesIdentifierResult(metadata, selfDescribing: false) {
                        recognizer.verified.append((RecognizerState.rank(of: identifier, pdfHasArxivID: pdfHasArxivID),
                                                    metadata))
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
                let higherPending = pendingAuthoritative + recognizer.pendingLookups
                // A verified recognizer identifier wins once the PDF's own identifiers have had their say.
                if higherPending == 0, let metadata = recognizer.bestVerified {
                    group.cancelAll()
                    return .found(metadata)
                }
                if !accepted.isEmpty || recognizer.fields != nil, !graceStarted, pending > 0, higherPending == 0 {
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
