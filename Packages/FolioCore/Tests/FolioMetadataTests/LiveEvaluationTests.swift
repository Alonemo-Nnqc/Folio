import FolioCore
import Foundation
import Testing
@testable import FolioMetadata

/// Runs the engine against real PDFs and ground truth from the user's Zotero library.
///
/// `FOLIO_LIVE=1 FOLIO_EVAL_DIR=/tmp/folio-eval FOLIO_EVAL_TRUTH=/tmp/folio-eval-truth.json swift test --filter LiveEvaluation`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FOLIO_LIVE"] == "1"))
struct LiveEvaluationTests {
    struct Truth: Decodable {
        var title: String
        var doi: String?
        var type: String
        var variant: String
    }

    enum Verdict: String { case hit = "hit", miss = "miss", wrong = "WRONG" }

    @Test func evaluatesRealPDFs() async throws {
        let env = ProcessInfo.processInfo.environment
        let dir = URL(filePath: try #require(env["FOLIO_EVAL_DIR"]))
        let truth = try JSONDecoder().decode([String: Truth].self,
                                             from: Data(contentsOf: URL(filePath: try #require(env["FOLIO_EVAL_TRUTH"]))))
        let engine = MetadataEngine()
        let only = env["FOLIO_EVAL_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        let files = truth.keys.sorted().filter { only?.contains($0) ?? true }

        // Resolve 4 at a time, like the app does.
        var results: [(String, Verdict, Double, String)] = []
        for batch in stride(from: 0, to: files.count, by: 4).map({ Array(files[$0..<min($0 + 4, files.count)]) }) {
            let outcomes = await withTaskGroup(of: (String, ResolveResult, Double).self) { group in
                for name in batch {
                    group.addTask {
                        let clock = ContinuousClock()
                        var result = ResolveResult.notFound
                        let elapsed = await clock.measure { result = await engine.resolve(pdfAt: dir.appending(path: name)) }
                        return (name, result, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
                    }
                }
                var collected: [(String, ResolveResult, Double)] = []
                for await outcome in group { collected.append(outcome) }
                return collected
            }
            for (name, result, seconds) in outcomes {
                let expected = truth[name]!
                switch result {
                case .found(let metadata):
                    let sameDOI = expected.doi != nil && expected.doi == metadata.doi
                    let similar = TitleNormalizer.similarity(metadata.title, expected.title) >= 0.9
                    results.append((name, sameDOI || similar ? .hit : .wrong, seconds, metadata.title))
                case .notFound:
                    results.append((name, .miss, seconds, "(not found)"))
                case .networkError:
                    results.append((name, .miss, seconds, "(network error)"))
                }
            }
        }

        for (name, verdict, seconds, title) in results.sorted(by: { $0.0 < $1.0 }) {
            print(String(format: "%-8@ %-5@ %5.2fs  %@  | truth: %@", name as NSString, verdict.rawValue as NSString,
                         seconds, String(title.prefix(70)) as NSString, String(truth[name]!.title.prefix(60)) as NSString))
        }
        for variant in ["original", "compare"] {
            let subset = results.filter { truth[$0.0]!.variant == variant }
            guard !subset.isEmpty else { continue }
            let hits = subset.filter { $0.1 == .hit }.count
            let wrong = subset.filter { $0.1 == .wrong }.count
            let times = subset.map(\.2).sorted()
            let p50 = times[times.count / 2], p90 = times[min(times.count - 1, Int(Double(times.count) * 0.9))]
            print(String(format: "[%@] n=%d hit=%d (%.0f%%) wrong=%d p50=%.2fs p90=%.2fs", variant as NSString,
                         subset.count, hits, Double(hits) * 100 / Double(subset.count), wrong, p50, p90))
        }
        let wrongOriginals = results.filter { truth[$0.0]!.variant == "original" && $0.1 == .wrong }
        #expect(wrongOriginals.isEmpty)
    }
}
