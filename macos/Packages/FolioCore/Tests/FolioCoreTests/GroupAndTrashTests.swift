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

    @Test func limitsDepthToFourLevels() throws {
        let lib = try Library.temporary()
        let l1 = try lib.createGroup(name: "L1")
        let l2 = try lib.createGroup(name: "L2", parentId: l1.id)
        let l3 = try lib.createGroup(name: "L3", parentId: l2.id)
        let l4 = try lib.createGroup(name: "L4", parentId: l3.id)
        #expect(throws: LibraryError.groupDepthExceeded) { try lib.createGroup(name: "L5", parentId: l4.id) }
        let s = try lib.snapshot()
        #expect(s.groupDepth(l4.id) == 4)
        #expect(s.groupAncestors(l4.id) == [l1.id, l2.id, l3.id])
        #expect(s.groupPath(l4.id) == ["L1", "L2", "L3", "L4"])
        #expect(s.groupSubtreeHeight(l1.id) == 4)
        #expect(s.canAddSubgroup(to: l3.id))
        #expect(!s.canAddSubgroup(to: l4.id))
        #expect(s.groupsInOrder.map(\.depth) == [0, 1, 2, 3])
    }

    @Test func movingKeepsTheWholeSubtreeWithinFourLevels() throws {
        let lib = try Library.temporary()
        let a = try lib.createGroup(name: "A")
        let a2 = try lib.createGroup(name: "A2", parentId: a.id)
        let a3 = try lib.createGroup(name: "A3", parentId: a2.id)
        let b = try lib.createGroup(name: "B")
        let b2 = try lib.createGroup(name: "B2", parentId: b.id)
        let leaf = try lib.createGroup(name: "Leaf")

        // A spans three levels: it fits under a top-level group, not under a second-level one.
        #expect(try lib.canMoveGroup(a.id, toParent: b.id))
        #expect(try lib.canMoveGroup(a.id, toParent: b2.id) == false)
        #expect(try lib.canMoveGroup(leaf.id, toParent: a3.id), "a leaf may become the fourth level")
        #expect(try lib.canMoveGroup(b.id, toParent: a3.id) == false, "B with B2 would reach level 5")
        #expect(try lib.canMoveGroup(b.id, toParent: a2.id), "B with B2 fills levels 3 and 4")
        #expect(try lib.canMoveGroup(b.id, toParent: a.id))
        // Never into itself or its own descendants.
        #expect(try lib.canMoveGroup(a.id, toParent: a.id) == false)
        #expect(try lib.canMoveGroup(a.id, toParent: a3.id) == false)
        #expect(try lib.canMoveGroup(a2.id, toParent: nil))
        #expect(throws: LibraryError.groupDepthExceeded) { try lib.moveGroup(a.id, toParent: b2.id, index: 0) }

        let s = try lib.snapshot()
        #expect(s.canMoveGroup(a.id, toParent: b.id))
        #expect(!s.canMoveGroup(a.id, toParent: b2.id))
        #expect(!s.canMoveGroup(a.id, toParent: a3.id))
        #expect(s.canMoveGroup(leaf.id, toParent: a3.id))

        try lib.moveGroup(a.id, toParent: b.id, index: 0)
        let moved = try lib.snapshot()
        #expect(moved.groupDepth(a3.id) == 4)
        #expect(moved.childGroups[b.id] == [a.id, b2.id])
        // Promoting a subgroup to the top level carries its subtree along.
        try lib.moveGroup(a2.id, toParent: nil, index: 0)
        let promoted = try lib.snapshot()
        #expect(promoted.topLevelGroups.first == a2.id)
        #expect(promoted.groupDepth(a3.id) == 2)
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

    @Test func deletingGroupRemovesAllDescendants() throws {
        let lib = try Library.temporary()
        let l1 = try lib.createGroup(name: "L1")
        let l2 = try lib.createGroup(name: "L2", parentId: l1.id)
        let l3 = try lib.createGroup(name: "L3", parentId: l2.id)
        let l4 = try lib.createGroup(name: "L4", parentId: l3.id)
        let other = try lib.createGroup(name: "Other")
        let deep = try lib.importItem("Deep", toGroup: l4.id)
        let middle = try lib.importItem("Middle", toGroup: l2.id)
        try lib.deleteGroup(l2.id, trashItems: true)
        let s = try lib.snapshot()
        #expect(Set(s.groupsById.keys) == [l1.id, other.id])
        #expect(Set(try lib.rows(.trash)) == [deep, middle])
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

    @Test func membershipLooksThroughEveryLevel() throws {
        let lib = try Library.temporary()
        let l1 = try lib.createGroup(name: "L1")
        let l2 = try lib.createGroup(name: "L2", parentId: l1.id)
        let l3 = try lib.createGroup(name: "L3", parentId: l2.id)
        let l4 = try lib.createGroup(name: "L4", parentId: l3.id)
        let id = try lib.importItem("X", toGroup: l4.id)
        #expect(try lib.addItems([id], toGroup: l1.id, includeSubgroups: true).alreadyPresent == [id])
        try lib.removeItems([id], fromGroup: l2.id, includeSubgroups: true)
        #expect(try lib.rows(.group(l4.id)).isEmpty)
        #expect(try lib.rows(.unfiled) == [id])
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

@Suite struct FolderImportTests {
    private func folder(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "folio-folder-\(UUID())/论文")
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return root
    }

    @Test func foldersBecomeGroups() throws {
        let library = try Library.temporary()
        let url = try folder(["a.pdf": "a", "笔记.md": "# n", "x.txt": "no", "SAM/b.pdf": "b", "SAM/v2/c.pdf": "c", "空/说明.txt": "no", ".隐藏/d.pdf": "d"])
        let found = try #require(ImportFolder.scan(url))
        #expect(found.fileCount == 4 && found.children.map(\.name) == ["SAM"])
        let first = try library.createGroup(name: "第一"), last = try library.createGroup(name: "最后")
        let result = try library.importFolder(found, index: 1)
        let snapshot = try library.snapshot()
        let top = try #require(result.groupId)
        #expect(snapshot.topLevelGroups == [first.id, top, last.id])
        #expect(snapshot.groupsById[top]?.name == "论文")
        let sam = try #require(snapshot.childGroups[top]?.first), v2 = try #require(snapshot.childGroups[sam]?.first)
        #expect(snapshot.groupsById[sam]?.name == "SAM" && snapshot.groupsById[v2]?.name == "v2")
        #expect(result.outcomes.count == 4)
        #expect(snapshot.items.values.contains { $0.title == "笔记" }, "a Markdown file has no extension in its title")
        // Once more: the same groups, nothing twice.
        let again = try library.importFolder(found)
        #expect(again.groupId == top)
        #expect(again.outcomes.allSatisfy { if case .duplicateFile = $0 { true } else { false } })
        #expect(try library.snapshot().groupsById.count == 5)
    }

    @Test func groupsGoNoDeeperThanTheyMay() throws {
        let library = try Library.temporary()
        let found = try #require(ImportFolder.scan(try folder(["1/2/3/4/5/x.pdf": "x", "1/2/y.pdf": "y"])))
        let parent = try library.createGroup(name: "上级")
        _ = try library.importFolder(found, parentId: parent.id)
        let snapshot = try library.snapshot()
        #expect(snapshot.groupsById.count == 4)
        #expect(snapshot.groupsById.values.map(\.name).sorted() == ["1", "2", "上级", "论文"].sorted())
        let deepest = try #require(snapshot.groupsById.values.first { $0.name == "2" })
        #expect(snapshot.groupDepth(deepest.id) == LibraryGroup.maximumDepth)
        // On a group of the last level: its files, no group.
        let more = try #require(ImportFolder.scan(try folder(["z.pdf": "z"])))
        let result = try library.importFolder(more, parentId: deepest.id)
        #expect(result.groupId == nil && result.outcomes.count == 1)
    }
}
