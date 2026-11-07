import FolioCore
import Testing

/// DND-01 / DND-04: what the item list does with a drop.
@MainActor
@Suite struct ListDropRulesTests {
    @Test func finderFilesAreImported() {
        #expect(ListDropRules.decide(hasFolioItems: false, fromThisList: false, fileCount: 2, isSearching: false, scope: .all) == .importFiles)
        #expect(ListDropRules.decide(hasFolioItems: false, fromThisList: false, fileCount: 1, isSearching: true, scope: .group("g")) == .importFiles,
                "searching does not block imports")
        #expect(ListDropRules.decide(hasFolioItems: false, fromThisList: false, fileCount: 1, isSearching: false, scope: .tag("t")) == .importFiles)
    }

    @Test func nothingIsImportedIntoTheTrash() {
        #expect(ListDropRules.decide(hasFolioItems: false, fromThisList: false, fileCount: 1, isSearching: false, scope: .trash) == .reject)
    }

    @Test func dragsWithoutFilesAreRejected() {
        #expect(ListDropRules.decide(hasFolioItems: false, fromThisList: false, fileCount: 0, isSearching: false, scope: .all) == .reject)
    }

    @Test func rowsFromThisListReorder() {
        #expect(ListDropRules.decide(hasFolioItems: true, fromThisList: true, fileCount: 1, isSearching: false, scope: .all) == .reorder,
                "rows also carry their file URL, which must not trigger an import")
        #expect(ListDropRules.decide(hasFolioItems: true, fromThisList: true, fileCount: 1, isSearching: true, scope: .all) == .reject)
        #expect(ListDropRules.decide(hasFolioItems: true, fromThisList: true, fileCount: 1, isSearching: false, scope: .trash) == .reject)
    }

    @Test func childFileRowsDraggedWithinTheListAreRejected() {
        #expect(ListDropRules.decide(hasFolioItems: false, fromThisList: true, fileCount: 1, isSearching: false, scope: .all) == .reject)
    }
}
