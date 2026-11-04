import Foundation
import Testing
@testable import FolioCore

@Suite struct GroupTests {
    @Test func validatesNames() throws {
        let lib = try Library.temporary()
        #expect(throws: LibraryError.emptyName) { try lib.createGroup(name: "  ") }
        try lib.createGroup(name: "Night")
        #expect(throws: LibraryError.duplicateGroupName("night")) { try lib.createGroup(name: "night") }
    }

    @Test func limitsDepthToTwoLevels() throws {
        let lib = try Library.temporary()
        let parent = try lib.createGroup(name: "P")
        let child = try lib.createGroup(name: "C", parentId: parent.id)
        #expect(throws: LibraryError.groupDepthExceeded) { try lib.createGroup(name: "GC", parentId: child.id) }

        let other = try lib.createGroup(name: "O")
        #expect(try lib.canMoveGroup(parent.id, toParent: other.id) == false, "group with children cannot nest")
        #expect(try lib.canMoveGroup(other.id, toParent: child.id) == false, "cannot move under a subgroup")
        #expect(try lib.canMoveGroup(other.id, toParent: parent.id))
        #expect(try lib.canMoveGroup(parent.id, toParent: parent.id) == false)
    }

    @Test func movesNestsPromotesAndReorders() throws {
        let lib = try Library.temporary()
        let a = try lib.createGroup(name: "A")
        let b = try lib.createGroup(name: "B")
        let c = try lib.createGroup(name: "C")
        try lib.moveGroup(c.id, toParent: nil, index: 0)
        #expect(try lib.snapshot().topLevelGroups == [c.id, a.id, b.id])

        try lib.moveGroup(b.id, toParent: a.id, index: 0)
        var s = try lib.snapshot()
        #expect(s.topLevelGroups == [c.id, a.id])
        #expect(s.childGroups[a.id] == [b.id])

        try lib.moveGroup(b.id, toParent: nil, index: 1)
        s = try lib.snapshot()
        #expect(s.topLevelGroups == [c.id, b.id, a.id])
        #expect(s.childGroups[a.id] == nil)
    }

    @Test func deletingGroupKeepsItemsUnlessAsked() throws {
        let lib = try Library.temporary()
        let parent = try lib.createGroup(name: "P")
        let child = try lib.createGroup(name: "C", parentId: parent.id)
        let kept = try lib.importItem("Kept", toGroup: child.id)
        try lib.deleteGroup(parent.id, trashItems: false)
        let s = try lib.snapshot()
        #expect(s.groupsById.isEmpty)
        #expect(try lib.rows(.unfiled) == [kept])

        let g = try lib.createGroup(name: "G")
        let trashed = try lib.importItem("Trashed", toGroup: g.id)
        try lib.deleteGroup(g.id, trashItems: true)
        #expect(try lib.rows(.trash) == [trashed])
    }

    @Test func addingTwiceReportsAlreadyPresent() throws {
        let lib = try Library.temporary()
        let parent = try lib.createGroup(name: "P")
        let child = try lib.createGroup(name: "C", parentId: parent.id)
        let id = try lib.importItem("X", toGroup: child.id)
        #expect(try lib.addItems([id], toGroup: child.id, includeSubgroups: true).alreadyPresent == [id])
        #expect(try lib.addItems([id], toGroup: parent.id, includeSubgroups: true).alreadyPresent == [id],
                "visible through the subgroup")
        #expect(try lib.addItems([id], toGroup: parent.id, includeSubgroups: false).added == [id])
    }

    @Test func removeFromGroupKeepsItemInLibrary() throws {
        let lib = try Library.temporary()
        let g = try lib.createGroup(name: "G")
        let id = try lib.importItem("X", toGroup: g.id)
        try lib.removeItems([id], fromGroup: g.id, includeSubgroups: true)
        #expect(try lib.rows(.group(g.id)).isEmpty)
        #expect(try lib.rows(.unfiled) == [id])
        #expect(try lib.rows(.trash).isEmpty)
    }
}

@Suite struct TrashTests {
    @Test func restoreReturnsToAllOriginalGroups() throws {
        let lib = try Library.temporary()
        let a = try lib.createGroup(name: "A")
        let b = try lib.createGroup(name: "B")
        let id = try lib.importItem("X", toGroup: a.id)
        try lib.addItems([id], toGroup: b.id, includeSubgroups: true)
        try lib.trashItems([id])
        #expect(try lib.rows(.all).isEmpty)
        #expect(try lib.rows(.group(a.id)).isEmpty)
        try lib.restoreItems([id])
        #expect(try lib.rows(.group(a.id)) == [id])
        #expect(try lib.rows(.group(b.id)) == [id])
    }

    @Test func restoreWithDeletedGroupLandsInUnfiled() throws {
        let lib = try Library.temporary()
        let g = try lib.createGroup(name: "G")
        let id = try lib.importItem("X", toGroup: g.id)
        try lib.trashItems([id])
        try lib.deleteGroup(g.id, trashItems: false)
        try lib.restoreItems([id])
        #expect(try lib.rows(.unfiled) == [id])
    }

    @Test func trashedFileRestoresToItsItem() throws {
        let lib = try Library.temporary()
        let id = try lib.importItem("Paper")
        _ = try lib.addFiles([try Fixture.pdf(named: "b.pdf", lines: ["B"])], toItem: id, autoRename: false)
        let files = try lib.files(ofItem: id)
        try lib.trashFiles([files[0].id])

        let item = try #require(try lib.item(id))
        #expect(item.defaultFileId == files[1].id, "default moves to the earliest remaining file")
        let trashRows = try lib.rows(.trash)
        #expect(trashRows.count == 1)
        let detached = try #require(try lib.item(trashRows[0]))
        #expect(detached.originItemId == id)

        try lib.restoreItems([detached.id])
        #expect(try lib.item(detached.id) == nil)
        #expect(try lib.files(ofItem: id).count == 2)
        #expect(try lib.item(id)?.defaultFileId == files[1].id, "restoring does not reclaim the default role")
    }

    @Test func trashedFileBecomesStandaloneWhenItemIsGone() throws {
        let lib = try Library.temporary()
        let id = try lib.importItem("Paper")
        _ = try lib.addFiles([try Fixture.pdf(named: "b.pdf", lines: ["B"])], toItem: id, autoRename: false)
        let file = try lib.files(ofItem: id)[1]
        try lib.trashFiles([file.id])
        let detached = try #require(try lib.rows(.trash).first)
        try lib.trashItems([id])
        try lib.purgeItems([id])
        try lib.restoreItems([detached])
        let restored = try #require(try lib.item(detached))
        #expect(restored.kind == .standalone)
        #expect(!restored.isTrashed)
        #expect(try lib.rows(.unfiled) == [detached])
    }

    @Test func purgeDeletesStoredFiles() throws {
        let lib = try Library.temporary()
        let id = try lib.importItem("Paper")
        let url = lib.fileURL(for: try #require(try lib.files(ofItem: id).first))
        try lib.trashItems([id])
        try lib.emptyTrash()
        #expect(try lib.item(id) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func purgeOlderThanOnlyRemovesExpired() throws {
        let lib = try Library.temporary()
        let old = try lib.importItem("Old")
        let recent = try lib.importItem("Recent")
        try lib.trashItems([old, recent])
        try lib.updateItem(old) { $0.trashedAt = Date().addingTimeInterval(-31 * 86_400) }
        try lib.purgeTrash(olderThan: Date().addingTimeInterval(-30 * 86_400))
        #expect(try lib.item(old) == nil)
        #expect(try lib.item(recent) != nil)
    }
}
