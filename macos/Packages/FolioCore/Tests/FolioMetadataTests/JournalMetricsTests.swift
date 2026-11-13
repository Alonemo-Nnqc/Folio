import FolioCore
import Foundation
import Testing
@testable import FolioMetadata

/// META-30: easyScholar answers, the cache and the request queue.
@Suite struct JournalMetricsTests {
    /// The documentation's success example, verbatim (trailing commas included).
    static let documentedSuccess = """
    {
        "code": 200,
        "msg": "SUCCESS",
        "data": {
            "customRank": {
                "rankInfo": [
                     {
                        "uuid": "1613157898765070336",
                        "abbName": "国自然管科",
                        "oneRankText": "A",
                        "twoRankText": "B"
                    },
                    {
                        "uuid": "1614986460329492480",
                        "abbName": "DUFE",
                        "oneRankText": "TOP",
                        "twoRankText": "A",
                        "threeRankText": "B",
                        "fourRankText": "C",
                        "fiveRankText": "D"
                    },
                ],
                "rank": [
                    "1614986460329492480&&&3",
                ]
            },
            "officialRank": {
                "all": {
                    "swufe": "A",
                    "cufe": "AA",
                },
                "select": {
                    "cufe": "AA",
                }
            }
        }
    }
    """

    /// The documentation's error example (also what the live service answers to a wrong key).
    static let documentedError = #"{"code": 40002, "msg": "Key错误", "data": null}"#

    /// Field names from the documentation's appendix; the value texts are assumed (the documentation shows none).
    static func answer(_ all: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["code": 200, "msg": "SUCCESS", "data": ["officialRank": ["all": all, "select": [:]]]])
    }

    static var natureRanks: [String: Any] { [
        "sciUp": "综合性期刊1区", "sciUpTop": "综合性期刊TOP", "sciBase": "综合性期刊1区", "sciUpSmall": "综合性期刊1区",
        "sci": "Q1", "sciif": "48.5", "sciif5": 54.4, "jci": "9.75", "eii": "EI检索",
    ] }

    @Test func parsesTheDocumentedExample() {
        guard case .found(let ranks) = EasyScholarClient.parse(Data(Self.documentedSuccess.utf8), status: 200) else {
            Issue.record("expected ranks")
            return
        }
        #expect(ranks == ["swufe": "A", "cufe": "AA"])
    }

    @Test func wrongKeyIsReported() {
        #expect(EasyScholarClient.parse(Data(Self.documentedError.utf8), status: 200) == .invalidKey("Key错误"))
    }

    @Test func unlistedJournalsAndOtherFailures() {
        #expect(EasyScholarClient.parse(Self.answer([:]), status: 200) == .notIndexed)
        #expect(EasyScholarClient.parse(Data(#"{"code":200,"msg":"SUCCESS","data":null}"#.utf8), status: 200) == .notIndexed)
        #expect(EasyScholarClient.parse(Data("<html>".utf8), status: 502) == .failed("HTTP 502"))
        #expect(EasyScholarClient.parse(Data(), status: 429) == .rateLimited("HTTP 429"))
        #expect(EasyScholarClient.parse(Data(#"{"code":40003,"msg":"请求过于频繁"}"#.utf8), status: 200) == .rateLimited("请求过于频繁"))
        #expect(EasyScholarClient.parse(Data(#"{"code":500,"msg":"系统错误"}"#.utf8), status: 200) == .failed("系统错误（500）"))
    }

    @Test func readsRanksLeniently() {
        guard case .found(let ranks) = EasyScholarClient.parse(Self.answer(Self.natureRanks), status: 200) else {
            Issue.record("expected ranks")
            return
        }
        #expect(ranks["sciif5"] == "54.4")
        let metrics = JournalMetrics(ranks: ranks)
        #expect(metrics.casZone == 1)
        #expect(metrics.casTop)
        #expect(metrics.casCategory == "综合性期刊")
        #expect(metrics.jcrQuartile == 1)
        #expect(metrics.impactFactor == 48.5)
        #expect(metrics.impactFactor5Year == 54.4)
        #expect(metrics.isEI)
        // In the language the tests run in (Chinese source, or its English translation).
        let badges = metrics.badges.map(\.text)
        #expect(badges == ["中科院 1 区 Top", "JCR Q1", "IF 48.5", "5 年 IF 54.4", "EI"] || badges == ["CAS Zone 1 Top", "JCR Q1", "IF 48.5", "5-yr IF 54.4", "EI"])
        #expect(metrics.badges.first?.emphasized == true)
        #expect(["1 区 Top", "Zone 1 Top"].contains(metrics.rankText ?? ""))
    }

    @Test func encodesNamesLikeEncodeURIComponent() {
        let url = EasyScholarClient.url(journal: "Science & Engineering+ (A/B)", secretKey: "k e y")
        #expect(url.absoluteString == "https://www.easyscholar.cc/open/getPublicationRank?secretKey=k%20e%20y&publicationName=Science%20%26%20Engineering%2B%20(A%2FB)")
    }

    // MARK: Queue

    final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        func withLock<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
    }

    final class Recorder: Sendable {
        let requests = Locked<[(name: String, time: ContinuousClock.Instant)]>([])
        var names: [String] { requests.withLock { $0.map(\.name) } }
    }

    static func client(_ recorder: Recorder, answer: @escaping @Sendable (String) throws -> Data) -> EasyScholarClient {
        EasyScholarClient(http: MockHTTPClient { url in
            let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "publicationName" }?.value ?? ""
            recorder.requests.withLock { $0.append((name, .now)) }
            return (try answer(name), 200)
        })
    }

    @Test func fetchesEachJournalOnceAndCachesTheAnswers() async throws {
        let library = try Library.temporary()
        let recorder = Recorder()
        let service = JournalMetricsService(library: library, client: Self.client(recorder) { name in
            name == "Nature" ? Self.answer(Self.natureRanks) : Self.answer([:])
        }, interval: .milliseconds(80))
        await service.setKey("secret")
        await service.enqueue(["Nature", "nature ", "Unknown Journal of Things", "NATURE"])
        await service.idle()
        #expect(recorder.names == ["Nature", "Unknown Journal of Things"])
        let times = recorder.requests.withLock { $0.map(\.time) }
        #expect(times[1] - times[0] >= .milliseconds(75))
        #expect(try library.journalMetrics(named: "nature")?.impactFactor == 48.5)
        #expect(try library.journalMetrics(named: "Unknown Journal of Things")?.isIndexed == false)

        // Cached and fresh: not stale any more.
        var item = Item(kind: .regular, title: "A")
        item.source = "Nature"
        var snapshot = try library.snapshot()
        snapshot.items[item.id] = item
        #expect(JournalMetricsService.staleJournals(in: snapshot).isEmpty)
        snapshot.journalMetrics[JournalMetrics.key(for: "Nature")]?.fetchedAt = Date().addingTimeInterval(-31 * 24 * 3600)
        #expect(JournalMetricsService.staleJournals(in: snapshot) == ["Nature"])

        // A forced refresh asks again.
        await service.enqueue(["Nature"], force: true)
        await service.idle()
        #expect(recorder.names.count == 3)
    }

    @Test func aRefusedKeyStopsTheQueue() async throws {
        let library = try Library.temporary()
        let recorder = Recorder()
        let statuses = Locked<[JournalMetricsService.Status]>([])
        let service = JournalMetricsService(library: library, client: Self.client(recorder) { _ in Data(Self.documentedError.utf8) },
                                            interval: .milliseconds(10), onStatus: { status in statuses.withLock { $0.append(status) } })
        await service.setKey("wrong")
        await service.enqueue(["A", "B", "C"])
        await service.idle()
        #expect(recorder.names == ["A"])
        #expect(await service.status.problem == .invalidKey("Key错误"))
        await service.enqueue(["D"])
        await service.idle()
        #expect(recorder.names == ["A"])
        // A new key starts over.
        await service.setKey("another")
        await service.enqueue(["D"])
        await service.idle()
        #expect(recorder.names == ["A", "D"])
        #expect(statuses.withLock { $0.contains { $0.pending > 0 } })
    }

    @Test func networkTroublePausesAndFailuresAreNotCached() async throws {
        let library = try Library.temporary()
        let recorder = Recorder()
        let service = JournalMetricsService(library: library, client: Self.client(recorder) { _ in throw URLError(.notConnectedToInternet) },
                                            interval: .milliseconds(10))
        await service.setKey("secret")
        await service.enqueue(["A", "B"])
        await service.idle()
        #expect(recorder.names == ["A"])
        if case .network = await service.status.problem {} else { Issue.record("expected a network problem") }
        #expect(try library.journalMetrics(named: "A") == nil)
        await service.enqueue(["B"])
        await service.idle()
        #expect(recorder.names == ["A"])
        // The user's refresh still goes through.
        await service.enqueue(["B"], force: true)
        await service.idle()
        #expect(recorder.names == ["A", "B"])
    }

    @Test func noKeyNoRequests() async throws {
        let recorder = Recorder()
        let service = JournalMetricsService(library: try Library.temporary(), client: Self.client(recorder) { _ in Self.answer([:]) })
        await service.enqueue(["A"])
        await service.idle()
        #expect(recorder.names.isEmpty)
    }
}
