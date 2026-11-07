import FolioCore
import Foundation
import Testing

/// SIDE-12, DND-02/03, TRASH-10.
@MainActor
@Suite struct SidebarDragRulesTests {
    let urls = [URL(filePath: "/tmp/a.pdf")]

    @Test func groupsNestOnlyUnderTopLevelGroupsAndOnlyWithoutChildren() {
        #expect(SidebarDragRules.decide(.group(id: "b", hasChildren: false), .group(id: "a", isTopLevel: true))
                == .nestGroup(id: "b", parentId: "a"))
        #expect(SidebarDragRules.decide(.group(id: "b", hasChildren: true), .group(id: "a", isTopLevel: true)) == .reject)
        #expect(SidebarDragRules.decide(.group(id: "b", hasChildren: false), .group(id: "c", isTopLevel: false)) == .reject)
        #expect(SidebarDragRules.decide(.group(id: "a", hasChildren: false), .group(id: "a", isTopLevel: true)) == .reject)
    }

    @Test func groupsReorderAndPromote() {
        #expect(SidebarDragRules.decide(.group(id: "a", hasChildren: true), .topLevelGap(index: 2))
                == .moveGroup(id: "a", parentId: nil, index: 2))
        #expect(SidebarDragRules.decide(.group(id: "c", hasChildren: false), .childGap(parentId: "a", index: 0))
                == .moveGroup(id: "c", parentId: "a", index: 0))
        #expect(SidebarDragRules.decide(.group(id: "b", hasChildren: true), .childGap(parentId: "a", index: 0)) == .reject)
    }

    @Test func groupsCannotLandOnBuiltInsOrTags() {
        for target in [SidebarDropTarget.builtin(.all), .builtin(.trash), .tag("t"), .elsewhere] {
            #expect(SidebarDragRules.decide(.group(id: "a", hasChildren: false), target) == .reject)
        }
    }

    @Test func itemsJoinOtherGroupsButNotTheirOwn() {
        #expect(SidebarDragRules.decide(.items(ids: ["1"], from: .all), .group(id: "g", isTopLevel: true))
                == .addItems(ids: ["1"], groupId: "g"))
        #expect(SidebarDragRules.decide(.items(ids: ["1"], from: .group("g")), .group(id: "g", isTopLevel: true)) == .reject)
        #expect(SidebarDragRules.decide(.items(ids: ["1"], from: .trash), .group(id: "g", isTopLevel: true)) == .reject)
    }

    @Test func itemsGoToTrashAndTags() {
        #expect(SidebarDragRules.decide(.items(ids: ["1"], from: .unfiled), .builtin(.trash)) == .trashItems(["1"]))
        #expect(SidebarDragRules.decide(.items(ids: ["1"], from: .trash), .builtin(.trash)) == .reject)
        #expect(SidebarDragRules.decide(.items(ids: ["1"], from: .all), .tag("t")) == .tagItems(ids: ["1"], tagId: "t"))
        #expect(SidebarDragRules.decide(.items(ids: ["1"], from: .all), .builtin(.all)) == .reject)
        #expect(SidebarDragRules.decide(.items(ids: ["1"], from: .all), .builtin(.unfiled)) == .reject)
        #expect(SidebarDragRules.decide(.items(ids: ["1"], from: .all), .topLevelGap(index: 0)) == .reject)
    }

    @Test func finderFilesImportIntoGroupsOrTheLibrary() {
        #expect(SidebarDragRules.decide(.files(urls), .group(id: "g", isTopLevel: false)) == .importFiles(urls, groupId: "g"))
        #expect(SidebarDragRules.decide(.files(urls), .builtin(.all)) == .importFiles(urls, groupId: nil))
        #expect(SidebarDragRules.decide(.files(urls), .builtin(.unfiled)) == .importFiles(urls, groupId: nil))
        #expect(SidebarDragRules.decide(.files(urls), .builtin(.trash)) == .reject)
        #expect(SidebarDragRules.decide(.files(urls), .tag("t")) == .reject)
    }
}
