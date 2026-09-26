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

        // 10 real collections flatten to 9 (one 3rd-level collection merges into its parent).
        #expect(report.collections == 9)
        #expect(library.groups.count == report.collections)
        // No group's parent itself has a parent — i.e. flattened to at most two levels.
        for group in library.groups where group.parentKey != nil {
            let parent = library.groups.first { $0.key == group.parentKey }
            #expect(parent != nil)
            #expect(parent?.parentKey == nil)
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
        #expect(existing >= 85) // known fact: 93 importable (linkMode 0) files, all present on disk
        #expect(existing + missing == library.entries.flatMap(\.files).count)

        // Automatic tags are available but excluded unless explicitly requested.
        #expect(report.automaticTagsAvailable == 55)
        #expect(report.tags == 2)

        var withAutomatic = ZoteroReadOptions()
        withAutomatic.includeAutomaticTags = true
        let (_, reportWithAutomatic) = try reader.read(options: withAutomatic)
        #expect(reportWithAutomatic.tags == 57)
    }
}
