import Foundation
import Testing
@testable import FolioCore

@Suite struct NotesAndReadingTests {
    @Test func notesAreSavedSearchedAndRemovedWhenEmpty() throws {
        let library = try Library.temporary()
        let id = try library.importItem("Spectral Attention")
        try library.setNote("# 想法\n对比 **SCSA** 模块", for: id)
        #expect(try library.note(for: id) == "# 想法\n对比 **SCSA** 模块")
        var snapshot = try library.snapshot()
        #expect(snapshot.notedItems == [id])
        #expect(try library.rows(.all, search: "scsa") == [id])

        try library.setNote("   \n", for: id)
        snapshot = try library.snapshot()
        #expect(snapshot.notedItems.isEmpty)
        #expect(try library.note(for: id) == "")
    }

    @Test func noteFollowsItemThroughTrashAndPurge() throws {
        let library = try Library.temporary()
        let id = try library.importItem("Paper")
        try library.setNote("keep me", for: id)
        try library.trashItems([id])
        try library.restoreItems([id])
        #expect(try library.note(for: id) == "keep me")
        try library.trashItems([id])
        try library.purgeItems([id])
        #expect(try library.database.writer.read { try Note.fetchCount($0) } == 0)
    }

    @Test func mergingStandaloneAppendsItsNote() throws {
        let library = try Library.temporary()
        let target = try library.importItem("Target")
        try library.setNote("target note", for: target)
        let standalone = try library.importOne(try Fixture.pdf(lines: ["Another copy", UUID().uuidString]))
        try library.setNote("standalone note", for: standalone)
        try library.mergeStandalone(standalone, intoItem: target, autoRename: false)
        #expect(try library.note(for: target) == "target note\n\nstandalone note")
    }

    @Test func noteOnMissingItemThrows() throws {
        let library = try Library.temporary()
        #expect(throws: LibraryError.self) { try library.setNote("x", for: "nope") }
    }

    @Test func readingStateRoundTripsWithoutTouchingSnapshot() throws {
        let library = try Library.temporary()
        let id = try library.importItem("Paper")
        let fileId = try #require(try library.files(ofItem: id).first?.id)
        let before = try library.snapshot()
        let state = ReadingState(fileId: fileId, pageIndex: 3, pointX: 10, pointY: 700, scale: 1.25, autoScale: false,
                                 displayMode: 1)
        try library.saveReadingState(state)
        var updated = state
        updated.pageIndex = 4
        try library.saveReadingState(updated)
        #expect(try library.readingState(fileId: fileId)?.pageIndex == 4)
        #expect(try library.snapshot() == before)
        // Unknown files are ignored rather than failing.
        try library.saveReadingState(ReadingState(fileId: "missing", pageIndex: 0, pointX: 0, pointY: 0, scale: 1,
                                                  autoScale: true, displayMode: 1))
        #expect(try library.readingState(fileId: "missing") == nil)
    }

    @Test func translatedFileJoinsItsItem() throws {
        let library = try Library.temporary()
        let id = try library.importItem("Paper")
        let source = try #require(try library.files(ofItem: id).first)
        let output = try Fixture.pdf(named: "out.pdf", lines: ["论文", UUID().uuidString])
        let file = try library.addTranslatedFile(at: output, of: source.id, kind: .mono, baseName: "Paper（中文译文）")
        #expect(file.itemId == id)
        #expect(file.translationOf == source.id)
        #expect(file.translationKind == .mono)
        #expect(file.fileName == "Paper（中文译文）.pdf")
        let snapshot = try library.snapshot()
        #expect(snapshot.filesByItem[id] == [source.id, file.id])
        #expect(snapshot.items[id]?.defaultFileId == source.id)
    }

    @Test func translationOfStandaloneBecomesStandalone() throws {
        let library = try Library.temporary()
        let group = try library.createGroup(name: "G", parentId: nil)
        let id = try library.importOne(try Fixture.pdf(lines: ["Untitled scan", UUID().uuidString]), toGroup: group.id)
        let source = try #require(try library.files(ofItem: id).first)
        let output = try Fixture.pdf(named: "out.pdf", lines: ["译文", UUID().uuidString])
        let file = try library.addTranslatedFile(at: output, of: source.id, kind: .dual, baseName: "scan（双语对照）")
        #expect(file.itemId != id)
        let snapshot = try library.snapshot()
        #expect(snapshot.items[file.itemId]?.kind == .standalone)
        #expect(snapshot.groupItems[group.id]?.contains(file.itemId) == true)
    }
}

@Suite struct GroupColorTests {
    @Test func groupColourIsStoredAndCleared() throws {
        let library = try Library.temporary()
        let group = try library.createGroup(name: "夜间场景")
        #expect(group.colorHex == nil)
        try library.setGroupColor(group.id, colorHex: "#34C759")
        #expect(try library.snapshot().groupsById[group.id]?.colorHex == "#34C759")
        try library.setGroupColor(group.id, colorHex: nil)
        #expect(try library.snapshot().groupsById[group.id]?.colorHex == nil)
        #expect(throws: LibraryError.self) { try library.setGroupColor("missing", colorHex: "#000000") }
    }
}

@Suite struct ReferenceImportTests {
    @Test func importsKeepsKeysAndSkipsDuplicates() throws {
        let library = try Library.temporary()
        let group = try library.createGroup(name: "综述")
        var a = Metadata(title: "A Survey of Things")
        a.authors = [Author(family: "Li", given: "Wei")]
        a.year = 2024
        a.doi = "10.1/abc"
        let first = try library.importReferences([(a, "li2024survey")], toGroup: group.id)
        #expect(first.created.count == 1)
        #expect(try library.item(first.created[0])?.citationKey == "li2024survey")
        let again = try library.importReferences([(a, "li2024survey")])
        #expect(again.created.isEmpty)
        #expect(again.duplicates == first.created)
        #expect(try library.rows(.group(group.id)) == first.created)
    }
}
