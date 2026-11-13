import Foundation
import Testing
import FolioCore
@testable import FolioZotero

/// Runs `probe()` and `read(options:)` against a real (copied) Zotero library.
/// Gated behind `FOLIO_LIVE=1` so it never runs in normal CI/dev loops.
/// Point `FOLIO_ZOTERO_DIR` at a copy of a Zotero data directory (default: `/tmp/folio-zotero-copy`).
@Suite struct ZoteroLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FOLIO_LIVE"] == "1"))
    func readsRealZoteroLibrary() throws {
        let path = ProcessInfo.processInfo.environment["FOLIO_ZOTERO_DIR"] ?? "/tmp/folio-zotero-copy"
        let directory = URL(fileURLWithPath: path)
        let reader = try ZoteroReader(dataDirectory: directory)

        let probeReport = try reader.probe()
        print("Zotero probe report: \(probeReport)")

        let (library, report) = try reader.read(options: ZoteroReadOptions())
        print("Zotero read report: \(report)")
        print("groups=\(library.groups.count) tags=\(library.tags.count) entries=\(library.entries.count)")

        // ~70 regular candidate items in the real library, minus 1 trashed -> ~70; leave slack.
        #expect(report.regularItems >= 60)
        #expect(library.entries.count == report.regularItems + report.standaloneFiles)

        // The 10 real collections are at most three levels deep, so all of them become groups.
        #expect(report.collections == 10)
        #expect(library.groups.count == report.collections)
        // Every group's parent was exported, and no chain is deeper than four levels.
        for group in library.groups {
            var level = 1
            var parentKey = group.parentKey
            while let key = parentKey {
                let parent = library.groups.first { $0.key == key }
                #expect(parent != nil)
                level += 1
                parentKey = parent?.parentKey
            }
            #expect(level <= LibraryGroup.maximumDepth)
        }

        // Every prepared file either exists on disk, or is at least accounted for (never a
        // nonsense/blank URL) — actual "missing file" bookkeeping happens downstream in
        // Library.importPrepared, this just verifies every sourceURL is a resolvable path.
        var existing = 0
        var missing = 0
        for entry in library.entries {
            for file in entry.files {
                #expect(!file.sourceURL.path.isEmpty)
                if FileManager.default.fileExists(atPath: file.sourceURL.path) {
                    existing += 1
                } else {
                    missing += 1
                }
            }
        }
        print("files existing=\(existing) missing=\(missing)")
        // Known facts: 93 linkMode-0 files (all present) + 29 linkMode-1 attachments whose
        // contentType isn't text/html (the connector downloaded these the same way it takes
        // snapshots, but they're real PDFs, not snapshots) = 122 kept files that exist, plus
        // 2 more linkMode-1 rows with an empty contentType/path that resolve to nothing.
        #expect(existing == 122)
        #expect(missing == 2)
        #expect(existing + missing == library.entries.flatMap(\.files).count)

        // Only real web snapshots (contentType text/html) are skipped; the linked URL stays skipped too.
        #expect(report.skippedSnapshots == 16)
        #expect(report.skippedLinks == 1)
        #expect(report.skippedTrashed == 1)

        // Automatic tags are available but excluded unless explicitly requested.
        #expect(report.automaticTagsAvailable == 55)
        #expect(report.tags == 2)

        var withAutomatic = ZoteroReadOptions()
        withAutomatic.includeAutomaticTags = true
        let (_, reportWithAutomatic) = try reader.read(options: withAutomatic)
        #expect(reportWithAutomatic.tags == 57)
    }
}
