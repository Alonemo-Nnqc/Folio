import FolioCore
import Foundation
import Testing

/// SIDE-12, SIDE-17, DND-02/03, TRASH-10.
@MainActor
@Suite struct SidebarDragRulesTests {
    let urls = [URL(filePath: "/tmp/a.pdf")]

    @Test func groupsNestUpToFourLevelsWithTheirSubgroups() {
        // A leaf can go under a group on any of the first three levels.
        #expect(SidebarDragRules.decide(.group(id: "b", height: 1), .group(id: "a", ancestors: []))
                == .nestGroup(id: "b", parentId: "a"))
        #expect(SidebarDragRules.decide(.group(id: "x", height: 1), .group(id: "c", ancestors: ["a", "b"]))
                == .nestGroup(id: "x", parentId: "c"))
        #expect(SidebarDragRules.decide(.group(id: "x", height: 1), .group(id: "d", ancestors: ["a", "b", "c"])) == .reject,
                "a fourth-level group has no subgroups")
        // A group with subgroups counts its whole subtree.
        #expect(SidebarDragRules.decide(.group(id: "x", height: 3), .group(id: "a", ancestors: []))
                == .nestGroup(id: "x", parentId: "a"))
        #expect(SidebarDragRules.decide(.group(id: "x", height: 3), .group(id: "b", ancestors: ["a"])) == .reject)
        #expect(SidebarDragRules.decide(.group(id: "x", height: 2), .group(id: "b", ancestors: ["a"]))
                == .nestGroup(id: "x", parentId: "b"))
        #expect(SidebarDragRules.decide(.group(id: "x", height: 4), .group(id: "a", ancestors: [])) == .reject)
    }

    @Test func groupsNeverMoveIntoThemselvesOrTheirDescendants() {
        #expect(SidebarDragRules.decide(.group(id: "a", height: 1), .group(id: "a", ancestors: [])) == .reject)
        #expect(SidebarDragRules.decide(.group(id: "a", height: 2), .group(id: "c", ancestors: ["a"])) == .reject)
        #expect(SidebarDragRules.decide(.group(id: "a", height: 3), .childGap(parentId: "c", ancestors: ["a", "b"], index: 0))
                == .reject)
        #expect(SidebarDragRules.decide(.group(id: "a", height: 1), .childGap(parentId: "a", ancestors: [], index: 0)) == .reject)
    }

    @Test func groupsReorderAndChangeLevel() {
        #expect(SidebarDragRules.decide(.group(id: "a", height: 4), .topLevelGap(index: 2))
                == .moveGroup(id: "a", parentId: nil, index: 2))
        #expect(SidebarDragRules.decide(.group(id: "c", height: 1), .childGap(parentId: "a", ancestors: [], index: 0))
                == .moveGroup(id: "c", parentId: "a", index: 0))
        #expect(SidebarDragRules.decide(.group(id: "b", height: 2), .childGap(parentId: "a", ancestors: [], index: 0))
                == .moveGroup(id: "b", parentId: "a", index: 0))
        // Promote a fourth-level group to the second level, or between third-level siblings.
        #expect(SidebarDragRules.decide(.group(id: "d", height: 1), .childGap(parentId: "b", ancestors: ["a"], index: 1))
                == .moveGroup(id: "d", parentId: "b", index: 1))
        #expect(SidebarDragRules.decide(.group(id: "d", height: 1), .childGap(parentId: "c", ancestors: ["a", "b"], index: 1))
                == .moveGroup(id: "d", parentId: "c", index: 1))
        #expect(SidebarDragRules.decide(.group(id: "b", height: 2), .childGap(parentId: "c", ancestors: ["x", "y"], index: 0))
                == .reject, "would reach a fifth level")
    }

    @Test func groupsCannotLandOnBuiltInsOrTags() {
        for target in [SidebarDropTarget.builtin(.all), .builtin(.trash), .tag("t"), .elsewhere] {
            #expect(SidebarDragRules.decide(.group(id: "a", height: 1), target) == .reject)
        }
    }

    @Test func itemsJoinOtherGroupsButNotTheirOwn() {
        #expect(SidebarDragRules.decide(.items(ids: ["1"], from: .all), .group(id: "g", ancestors: []))
                == .addItems(ids: ["1"], groupId: "g"))
        #expect(SidebarDragRules.decide(.items(ids: ["1"], from: .all), .group(id: "g", ancestors: ["a", "b", "c"]))
                == .addItems(ids: ["1"], groupId: "g"), "any level accepts items")
        #expect(SidebarDragRules.decide(.items(ids: ["1"], from: .group("g")), .group(id: "g", ancestors: [])) == .reject)
        #expect(SidebarDragRules.decide(.items(ids: ["1"], from: .trash), .group(id: "g", ancestors: [])) == .reject)
    }

    @Test func itemsGoToTrashAndTags() {
        #expect(SidebarDragRules.decide(.items(ids: ["1"], from: .unfiled), .builtin(.trash)) == .trashItems(["1"]))
        #expect(SidebarDragRules.decide(.items(ids: ["1"], from: .trash), .builtin(.trash)) == .reject)
        #expect(SidebarDragRules.decide(.items(ids: ["1"], from: .all), .tag("t")) == .tagItems(ids: ["1"], tagId: "t"))
        #expect(SidebarDragRules.decide(.items(ids: ["1"], from: .all), .builtin(.all)) == .reject)
        #expect(SidebarDragRules.decide(.items(ids: ["1"], from: .all), .builtin(.unfiled)) == .reject)
        #expect(SidebarDragRules.decide(.items(ids: ["1"], from: .all), .topLevelGap(index: 0)) == .reject)
        #expect(SidebarDragRules.decide(.items(ids: ["1"], from: .all), .childGap(parentId: "a", ancestors: [], index: 0)) == .reject)
    }

    @Test func finderFilesImportIntoGroupsOrTheLibrary() {
        #expect(SidebarDragRules.decide(.files(urls), .group(id: "g", ancestors: ["a"])) == .importFiles(urls, groupId: "g"))
        #expect(SidebarDragRules.decide(.files(urls), .builtin(.all)) == .importFiles(urls, groupId: nil))
        #expect(SidebarDragRules.decide(.files(urls), .builtin(.unfiled)) == .importFiles(urls, groupId: nil))
        #expect(SidebarDragRules.decide(.files(urls), .builtin(.trash)) == .reject)
        #expect(SidebarDragRules.decide(.files(urls), .tag("t")) == .reject)
    }
}

/// SIDE-17: the sidebar tree mirrors every level of the group hierarchy.
@MainActor
@Suite struct SidebarTreeTests {
    @Test func buildsAllFourLevelsAndNoticesDeepStructuralChanges() {
        var s = LibrarySnapshot()
        for (id, parent) in [("a", nil), ("b", "a"), ("c", "b"), ("d", "c")] as [(String, String?)] {
            s.groupsById[id] = LibraryGroup(id: id, parentId: parent, name: id.uppercased(), position: 0)
            if let parent { s.childGroups[parent, default: []].append(id) } else { s.topLevelGroups.append(id) }
        }
        let tree = SidebarTree()
        #expect(tree.rebuild(from: s))
        let d = tree.node(for: .group("c"))?.children.first
        #expect(d?.groupId == "d")
        #expect(tree.node(for: .group("a"))?.children.first?.children.first?.children.first === d)
        #expect(!tree.rebuild(from: s), "same structure")

        // Moving the fourth level up one level is a structural change even though the top level is unchanged.
        s.childGroups["c"] = nil
        s.childGroups["b"] = ["c", "d"]
        s.groupsById["d"]?.parentId = "b"
        #expect(tree.rebuild(from: s))
        #expect(tree.node(for: .group("b"))?.children.map(\.groupId) == ["c", "d"])
    }
}
