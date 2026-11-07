import FolioCore
import Foundation
import SQLite3
import Testing
@testable import FolioMetadata

/// Old engine (no Zotero recognizer) against new engine on the PDFs in the user's Zotero library,
/// with the parent items' title / DOI / year as ground truth.
///
/// `~/Zotero/zotero.sqlite` (and its WAL) is copied to a temporary directory and only the copy is
/// opened; nothing under `~/Zotero` is written. PDFs are read in place.
///
/// `FOLIO_LIVE=1 swift test --filter ZoteroCorpusEvaluation`
/// Optional: `FOLIO_ZOTERO_DIR` (default `~/Zotero`), `FOLIO_EVAL_LIMIT`, `FOLIO_EVAL_REPORT` (TSV output path).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FOLIO_LIVE"] == "1"), .serialized)
struct ZoteroCorpusEvaluationTests {
    struct Sample: Sendable {
        var id: Int
        var url: URL
        var title: String
        var doi: String?
        var year: Int?
        var parentType: String
        /// Bilingual "compare" PDF produced by a translation plug-in.
        var isCompare: Bool { url.lastPathComponent.lowercased().contains(".compare.") || url.lastPathComponent.contains(".dual.") }
    }

    enum Verdict: String, Sendable { case hit, miss, wrong }

    struct Outcome: Sendable {
        var verdict: Verdict
        var seconds: Double
        var detail: String
    }

    // MARK: - Corpus

    static func corpus(zoteroDirectory: URL) throws -> [Sample] {
        let temp = FileManager.default.temporaryDirectory.appending(path: "folio-zotero-eval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        for suffix in ["", "-wal"] {
            let source = zoteroDirectory.appending(path: "zotero.sqlite" + suffix)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: temp.appending(path: "zotero.sqlite" + suffix))
            }
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(temp.appending(path: "zotero.sqlite").path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_close(db) }

        func rows(_ sql: String, _ bind: [Int] = []) -> [[String?]] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            for (index, value) in bind.enumerated() { sqlite3_bind_int64(statement, Int32(index + 1), Int64(value)) }
            var result: [[String?]] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append((0..<sqlite3_column_count(statement)).map { column in
                    sqlite3_column_text(statement, column).map { String(cString: $0) }
                })
            }
            return result
        }
        func field(_ item: Int, _ name: String) -> String? {
            rows("""
                SELECT v.value FROM itemData d JOIN fields f ON f.fieldID = d.fieldID
                JOIN itemDataValues v ON v.valueID = d.valueID WHERE d.itemID = ? AND f.fieldName = '\(name)'
                """, [item]).first?.first ?? nil
        }

        let attachments = rows("""
            SELECT ai.itemID, ia.key, ai.path, p.itemID, t.typeName
            FROM itemAttachments ai
            JOIN items ia ON ia.itemID = ai.itemID
            JOIN items p ON p.itemID = ai.parentItemID
            JOIN itemTypes t ON t.itemTypeID = p.itemTypeID
            WHERE ai.contentType = 'application/pdf' AND ai.linkMode IN (0, 1)
              AND t.typeName NOT IN ('note', 'attachment', 'annotation')
              AND ai.itemID NOT IN (SELECT itemID FROM deletedItems)
              AND p.itemID NOT IN (SELECT itemID FROM deletedItems)
            ORDER BY ai.itemID
            """)
        var samples: [Sample] = []
        for row in attachments {
            guard let id = row[0].flatMap({ Int($0) }), let key = row[1], let path = row[2], path.hasPrefix("storage:"),
                  let parent = row[3].flatMap({ Int($0) }), let title = field(parent, "title") else { continue }
            let url = zoteroDirectory.appending(path: "storage").appending(path: key)
                .appending(path: String(path.dropFirst("storage:".count)))
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let year = field(parent, "date").flatMap { FieldNormalizer.date(fromString: $0)?.year }
            samples.append(Sample(id: id, url: url, title: title, doi: FieldNormalizer.normalizeDOI(field(parent, "DOI")),
                                  year: year, parentType: row[4] ?? "?"))
        }
        return samples
    }

    // MARK: - Running

    static func judge(_ result: ResolveResult, _ sample: Sample, seconds: Double) -> Outcome {
        switch result {
        case .found(let metadata):
            let sameDOI = sample.doi != nil && sample.doi == metadata.doi
            let similar = TitleNormalizer.similarity(metadata.title, sample.title) >= 0.9
            let detail = "\(metadata.title.prefix(80)) [\(metadata.doi ?? metadata.arxivId.map { "arXiv:\($0)" } ?? "-")]"
            return Outcome(verdict: sameDOI || similar ? .hit : .wrong, seconds: seconds, detail: detail)
        case .notFound:
            return Outcome(verdict: .miss, seconds: seconds, detail: "(not found)")
        case .networkError:
            return Outcome(verdict: .miss, seconds: seconds, detail: "(network error)")
        }
    }

    static func run(_ engine: MetadataEngine, on batch: [Sample]) async -> [Int: Outcome] {
        await withTaskGroup(of: (Int, Outcome).self) { group in
            for sample in batch {
                group.addTask {
                    let clock = ContinuousClock()
                    var result = ResolveResult.notFound
                    let elapsed = await clock.measure { result = await engine.resolve(pdfAt: sample.url) }
                    return (sample.id, judge(result, sample, seconds: seconds(elapsed)))
                }
            }
            var outcomes: [Int: Outcome] = [:]
            for await (id, outcome) in group { outcomes[id] = outcome }
            return outcomes
        }
    }

    /// Simulates an outage of every title-search source (Crossref search, OpenAlex, DBLP, arXiv
    /// search) with 503s; identifier lookups and the recognizer still go through.
    struct SearchOutageHTTPClient: HTTPClient {
        let base = URLSessionHTTPClient(timeout: 6)

        static func isSearch(_ url: URL) -> Bool {
            switch url.host() {
            case "api.crossref.org": url.path == "/works"
            case "api.openalex.org", "dblp.org": true
            case "export.arxiv.org": url.query()?.contains("search_query") == true
            default: false
            }
        }

        func get(_ url: URL, headers: [String: String]) async throws -> (Data, Int) {
            if Self.isSearch(url) { return (Data(), 503) }
            return try await base.get(url, headers: headers)
        }

        func post(_ url: URL, body: Data, headers: [String: String]) async throws -> (Data, Int) {
            try await base.post(url, body: body, headers: headers)
        }
    }

    static func runAll(_ engines: [MetadataEngine], on samples: [Sample]) async -> [[Int: Outcome]] {
        var outcomes = Array(repeating: [Int: Outcome](), count: engines.count)
        let batches = stride(from: 0, to: samples.count, by: 4).map { Array(samples[$0..<min($0 + 4, samples.count)]) }
        for (index, batch) in batches.enumerated() {
            // Alternate the order per batch so that every engine sees the same network conditions.
            let order = index.isMultiple(of: 2) ? Array(engines.indices) : Array(engines.indices.reversed())
            for engine in order {
                outcomes[engine].merge(await run(engines[engine], on: batch)) { $1 }
            }
        }
        return outcomes
    }

    static func summarize(_ name: String, _ outcomes: [Int: Outcome], _ samples: [Sample]) {
        for subset in ["all", "original", "compare"] {
            let chosen = samples.filter { subset == "all" || (subset == "compare") == $0.isCompare }
            guard !chosen.isEmpty else { continue }
            let values = chosen.map { outcomes[$0.id]! }
            let hits = values.count { $0.verdict == .hit }
            let wrong = values.count { $0.verdict == .wrong }
            let network = values.count { $0.detail == "(network error)" }
            let times = values.map(\.seconds).sorted()
            let p50 = times[times.count / 2]
            let p90 = times[min(times.count - 1, Int((Double(times.count) * 0.9).rounded(.up)) - 1)]
            print(String(format: "[%@ %@] n=%d hit=%d (%.1f%%) miss=%d (network %d) wrong=%d p50=%.2fs p90=%.2fs",
                         name, subset, chosen.count, hits, Double(hits) * 100 / Double(chosen.count),
                         chosen.count - hits - wrong, network, wrong, p50, p90))
        }
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// What the recognizer alone says about each PDF (one extra request per file).
    static func probeRecognizer(_ samples: [Sample]) async -> [Int: (String, Double)] {
        let client = ZoteroRecognizerClient(transport: Transport(http: URLSessionHTTPClient(timeout: 10),
                                                                  throttle: HostThrottle(minimumIntervals: [:]), mailto: nil))
        var answers: [Int: (String, Double)] = [:]
        for batch in stride(from: 0, to: samples.count, by: 4).map({ Array(samples[$0..<min($0 + 4, samples.count)]) }) {
            await withTaskGroup(of: (Int, String, Double).self) { group in
                for sample in batch {
                    group.addTask {
                        let clock = ContinuousClock()
                        var kind = ""
                        let elapsed = await clock.measure {
                            guard let payload = RecognizerPayload.extract(from: sample.url) else { kind = "no-text"; return }
                            do throws(SourceError) {
                                guard let response = try await client.recognize(payload) else { kind = "empty"; return }
                                if let arxiv = response.arxiv { kind = "arxiv"; _ = arxiv }
                                else if response.doi != nil { kind = "doi" }
                                else if response.isbn != nil { kind = "isbn" }
                                else {
                                    let similar = TitleNormalizer.similarity(response.title ?? "", sample.title) >= 0.9
                                    kind = similar ? "fields" : "fields-wrong"
                                }
                                if kind == "doi", let doi = FieldNormalizer.normalizeDOI(response.doi), let truth = sample.doi,
                                   doi != truth { kind = "doi-differs" }
                            } catch {
                                kind = "error(\(error))"
                            }
                        }
                        return (sample.id, kind, seconds(elapsed))
                    }
                }
                for await (id, kind, time) in group { answers[id] = (kind, time) }
            }
        }
        return answers
    }

    // MARK: - Test

    @Test func oldVersusNewEngine() async throws {
        let env = ProcessInfo.processInfo.environment
        let zotero = env["FOLIO_ZOTERO_DIR"].map { URL(filePath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Zotero")
        var samples = try Self.corpus(zoteroDirectory: zotero)
        if let limit = env["FOLIO_EVAL_LIMIT"].flatMap({ Int($0) }) { samples = Array(samples.prefix(limit)) }
        if let only = env["FOLIO_EVAL_ONLY"].map({ Set($0.split(separator: ",").compactMap { Int($0) }) }) {
            samples = samples.filter { only.contains($0.id) }
        }
        #expect(!samples.isEmpty)
        print("corpus: \(samples.count) PDFs (\(samples.filter(\.isCompare).count) bilingual)")

        var oldConfiguration = MetadataEngineConfiguration()
        oldConfiguration.useZoteroRecognizer = false
        let old = MetadataEngine(configuration: oldConfiguration)
        let new = MetadataEngine()

        // Batches of 4 like the app; old and new alternate per batch so that both see the same
        // network conditions and the same server-side caches.
        let both = await Self.runAll([old, new], on: samples)
        let (oldOutcomes, newOutcomes) = (both[0], both[1])
        let recognizer = env["FOLIO_EVAL_PROBE"] == "0" ? [:] : await Self.probeRecognizer(samples)

        // Fallback scenario: every title-search source down (as with Crossref outages, the OpenAlex
        // daily quota or DBLP's bot wall), identifier lookups still available.
        var outage: [[Int: Outcome]] = []
        if env["FOLIO_EVAL_OUTAGE"] == "1" {
            let engines = [false, true].map { useRecognizer in
                var configuration = MetadataEngineConfiguration()
                configuration.useZoteroRecognizer = useRecognizer
                return MetadataEngine(configuration: configuration, http: SearchOutageHTTPClient(),
                                      cvfHTTP: URLSessionHTTPClient(timeout: 12), throttle: .shared)
            }
            outage = await Self.runAll(engines, on: samples)
        }

        var report = "id\tsubset\ttype\told\told_s\tnew\tnew_s\trecognizer\trecognizer_s\toutage_old\toutage_new"
            + "\ttruth\told_detail\tnew_detail\toutage_old_detail\toutage_new_detail\tfile\n"
        for sample in samples {
            let o = oldOutcomes[sample.id]!, n = newOutcomes[sample.id]!
            let r = recognizer[sample.id] ?? ("-", 0)
            let oo = outage.first?[sample.id], on = outage.last?[sample.id]
            report += "\(sample.id)\t\(sample.isCompare ? "compare" : "original")\t\(sample.parentType)\t\(o.verdict.rawValue)\t"
                + String(format: "%.2f", o.seconds) + "\t\(n.verdict.rawValue)\t" + String(format: "%.2f", n.seconds)
                + "\t\(r.0)\t" + String(format: "%.2f", r.1)
                + "\t\(oo?.verdict.rawValue ?? "-")\t\(on?.verdict.rawValue ?? "-")"
                + "\t\(sample.title.prefix(80)) [\(sample.doi ?? "-")]\t\(o.detail)\t\(n.detail)"
                + "\t\(oo?.detail ?? "-")\t\(on?.detail ?? "-")\t\(sample.url.lastPathComponent)\n"
        }
        if let path = env["FOLIO_EVAL_REPORT"] { try report.write(toFile: path, atomically: true, encoding: .utf8) }
        print(report)

        Self.summarize("old", oldOutcomes, samples)
        Self.summarize("new", newOutcomes, samples)
        if outage.count == 2 {
            Self.summarize("outage old", outage[0], samples)
            Self.summarize("outage new", outage[1], samples)
        }
        if !recognizer.isEmpty {
            var kinds: [String: Int] = [:]
            for (kind, _) in recognizer.values { kinds[kind, default: 0] += 1 }
            let times = recognizer.values.map(\.1).sorted()
            print("recognizer answers: \(kinds.sorted { $0.key < $1.key })  p50=\(times[times.count / 2])s")
        }
        // A wrong match is worse than none.
        for outcomes in [newOutcomes] + outage.dropFirst() {
            #expect(samples.filter { outcomes[$0.id]!.verdict == .wrong }.map(\.url.lastPathComponent) == [])
        }
    }
}
