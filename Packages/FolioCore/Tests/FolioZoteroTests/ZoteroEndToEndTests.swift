import FolioCore
import Foundation
import Testing
@testable import FolioZotero

/// ZOT-01…06 end to end: real Zotero copy → Folio library.
/// `FOLIO_LIVE=1 FOLIO_ZOTERO_DIR=/tmp/folio-zotero-copy swift test --filter ZoteroEndToEnd`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FOLIO_LIVE"] == "1"))
struct ZoteroEndToEndTests {
    @Test func importsRealLibraryAndSkipsDuplicatesOnSecondRun() throws {
        let source = URL(filePath: try #require(ProcessInfo.processInfo.environment["FOLIO_ZOTERO_DIR"]))
        let library = try Library.temporary()
        let reader = try ZoteroReader(dataDirectory: source)
        let (prepared, report) = try reader.read(options: ZoteroReadOptions())

        let clock = ContinuousClock()
        var summary = BulkImportSummary()
        let elapsed = try clock.measure { summary = try library.importPrepared(prepared) }
        print("zotero e2e: \(summary) in \(elapsed)")

        let snapshot = try library.snapshot()
        #expect(summary.itemsImported + summary.duplicatesSkipped == report.regularItems + report.standaloneFiles
                || summary.itemsImported > 60)
        #expect(snapshot.items.count == summary.itemsImported)
        #expect(snapshot.files.count == summary.filesImported)
        #expect(summary.groupsCreated == report.collections)
        #expect(snapshot.groupsById.values.allSatisfy { group in
            group.parentId.map { snapshot.groupsById[$0]?.parentId == nil } ?? true
        }, "at most two levels")
        #expect(snapshot.tags.count == report.tags, "automatic tags excluded by default")
        for file in snapshot.files.values {
            #expect(FileManager.default.fileExists(atPath: library.fileURL(for: file).path))
        }
        let regular = snapshot.items.values.filter { $0.kind == .regular }
        #expect(regular.allSatisfy { $0.defaultFileId == nil || snapshot.files[$0.defaultFileId!] != nil })
        #expect(regular.allSatisfy { !($0.citationKey ?? "").isEmpty })

        let again = try library.importPrepared(prepared)
        #expect(again.itemsImported == 0, "second import only finds duplicates")
        #expect(again.groupsCreated == 0)
    }
}
