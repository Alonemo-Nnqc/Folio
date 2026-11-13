import Foundation
import GRDB
import Testing
@testable import FolioCore

/// META-30: the journalMetrics table, names, parsing and the 分区 / 影响因子 columns.
@Suite struct JournalMetricsCacheTests {
    @Test func journalNamesNormalise() {
        #expect(JournalMetrics.key(for: "  IEEE Transactions on  Image Processing. ") == "ieee transactions on image processing")
        #expect(JournalMetrics.key(for: "Science &amp; Engineering") == "science & engineering")
        #expect(JournalMetrics.queryName(for: " Science &amp;  Engineering ") == "Science & Engineering")
    }

    @Test func onlyJournalsAndConferencesWithAVenue() {
        var item = Item(kind: .regular, title: "A")
        item.source = "Nature"
        #expect(JournalMetrics.journalName(of: item) == "Nature")
        item.source = "arXiv"
        #expect(JournalMetrics.journalName(of: item) == nil)
        item.source = "Nature"
        item.type = .book
        #expect(JournalMetrics.journalName(of: item) == nil)
        item.type = .conferencePaper
        #expect(JournalMetrics.journalName(of: item) == "Nature")
        let standalone = Item(kind: .standalone, title: "x.pdf")
        #expect(JournalMetrics.journalName(of: standalone) == nil)
    }

    @Test func parsesFreeTextRanks() {
        #expect(JournalMetrics.zone("医学2区") == 2)
        #expect(JournalMetrics.zone("3") == 3)
        #expect(JournalMetrics.zone("TOP") == nil)
        #expect(JournalMetrics.category("计算机科学 1区") == "计算机科学")
        #expect(JournalMetrics.quartile("Q3") == 3)
        #expect(JournalMetrics.number("IF: 12.75") == 12.75)
        #expect(JournalMetrics.ccfClass("CCF-B") == "B")
        #expect(JournalMetrics.ccfClass("A") == "A")
        #expect(JournalMetrics.format(12.30) == "12.3")
        #expect(JournalMetrics.format(105) == "105")
        let metrics = JournalMetrics(ranks: ["sciBase": "工程技术3区", "ccf": "CCF-A", "pku": "北大核心", "sciwarn": "高"])
        #expect(metrics.badges.map(\.kind) == [.cas(3), .ccf, .index, .warning])
        // In the language the tests run in (Chinese source, or its English translation).
        #expect(["3 区", "Zone 3"].contains(metrics.rankText ?? ""))
        #expect(JournalMetrics(ranks: ["sci": "Q2"]).rankText == "Q2")
    }

    @Test func cacheRoundTripsAndFeedsTheSnapshot() throws {
        let library = try Library.temporary()
        try library.saveJournalMetrics([("Nature", JournalMetrics(ranks: ["sciUp": "综合性期刊1区", "sciif": "48.5"])),
                                        ("Unknown", JournalMetrics(ranks: [:]))])
        #expect(try library.journalMetrics(named: "NATURE")?.impactFactor == 48.5)
        #expect(try library.journalMetrics(named: "unknown")?.isIndexed == false)
        let raw = try library.database.writer.read { try String.fetchOne($0, sql: "SELECT json FROM journalMetrics WHERE name = 'nature'") }
        #expect(raw == #"{"sciUp":"综合性期刊1区","sciif":"48.5"}"#)

        let item = try library.importReferences([(Fixture.metadata("Paper", year: 2020), nil)], toGroup: nil).created[0]
        try library.updateItem(item) { $0.source = "Nature" }
        let snapshot = try library.snapshot()
        #expect(snapshot.journalMetrics(for: snapshot.items[item]!)?.casZone == 1)

        try library.clearJournalMetrics()
        #expect(try library.snapshot().journalMetrics.isEmpty)
    }

    @Test func sortsByRankAndImpactFactor() throws {
        var s = LibrarySnapshot()
        func add(_ title: String, _ source: String?) -> Item {
            var item = Item(kind: .regular, title: title)
            item.source = source
            s.items[item.id] = item
            return item
        }
        let a = add("A", "Top One"), b = add("B", "Zone Two"), c = add("C", "Zone One"), d = add("D", nil), e = add("E", "JCR only")
        s.journalMetrics = [
            "top one": JournalMetrics(ranks: ["sciUp": "医学1区", "sciUpTop": "医学TOP", "sciif": "30"]),
            "zone two": JournalMetrics(ranks: ["sciUp": "医学2区", "sciif": "5.2"]),
            "zone one": JournalMetrics(ranks: ["sciUp": "医学1区", "sciif": "8"]),
            "jcr only": JournalMetrics(ranks: ["sci": "Q1", "sciif": "2.1"]),
        ]
        let rank = ViewResolver.rows(ViewQuery(scope: .all, sort: SortState(column: .journalRank, ascending: true)), in: s)
        #expect(rank == [a.id, c.id, b.id, e.id, d.id])
        let impact = ViewResolver.rows(ViewQuery(scope: .all, sort: SortState(column: .impactFactor, ascending: false)), in: s)
        #expect(impact == [a.id, c.id, b.id, e.id, d.id])
    }

    @Test func unknownSortColumnsReadAsCustomOrder() throws {
        let library = try Library.temporary()
        try library.database.writer.write {
            try $0.execute(sql: "INSERT INTO viewSort (scope, sortColumn, ascending) VALUES ('all', 'somethingNew', 1)")
        }
        #expect(try library.snapshot().sort(for: .all) == SortState(column: nil, ascending: true))
    }
}
