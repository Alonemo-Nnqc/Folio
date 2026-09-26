import FolioCore
import Foundation
import Testing

/// LIST-11/12, FILE-04, META-07/08, TRASH-02/04, TAG-02.
@MainActor
@Suite struct ItemMenuBuilderTests {
    let snapshot: LibrarySnapshot
    let groups: [(group: LibraryGroup, depth: Int)]
    let regular: Item, standalone: Item, other: Item
    let fileA: FileRecord, fileB: FileRecord

    init() {
        var s = LibrarySnapshot()
        var regular = Item(kind: .regular, title: "Paper")
        let a = FileRecord(itemId: regular.id, relativePath: "Files/a.pdf", originalName: "a.pdf", size: 1, sha256: "a", modifiedAt: Date())
        let b = FileRecord(itemId: regular.id, relativePath: "Files/b.pdf", originalName: "b.pdf", size: 1, sha256: "b", modifiedAt: Date())
        regular.defaultFileId = a.id
        var standalone = Item(kind: .standalone, title: "loose.pdf")
        let loose = FileRecord(itemId: standalone.id, relativePath: "Files/loose.pdf", originalName: "loose.pdf", size: 1, sha256: "c", modifiedAt: Date())
        standalone.defaultFileId = loose.id
        standalone.metadataState = .failed
        let other = Item(kind: .regular, title: "Other")
        for item in [regular, standalone, other] { s.items[item.id] = item }
        for file in [a, b, loose] {
            s.files[file.id] = file
            s.filesByItem[file.itemId, default: []].append(file.id)
        }
        let parent = LibraryGroup(name: "Parent", position: 0)
        let child = LibraryGroup(parentId: parent.id, name: "Child", position: 0)
        s.groupsById = [parent.id: parent, child.id: child]
        s.topLevelGroups = [parent.id]
        s.childGroups = [parent.id: [child.id]]
        s.groupItems = [child.id: [regular.id]]
        let tag = Tag(name: "必读", colorHex: "#FF3B30", position: 0)
        s.tags = [tag]
        s.tagsById = [tag.id: tag]
        s.itemTags = [regular.id: [tag.id]]
        snapshot = s
        groups = [(parent, 0), (child, 1)]
        self.regular = regular
        self.standalone = standalone
        self.other = other
        fileA = a
        fileB = b
    }

    func titles(_ entries: [ItemMenuEntry]) -> [String] { entries.compactMap(\.title) }

    func submenu(_ title: String, in entries: [ItemMenuEntry]) -> [ItemMenuEntry] {
        for case let .submenu(name, _, children) in entries where name == title { return children }
        return []
    }

    @Test func trashOffersOnlyRestoreAndPurge() {
        let entries = ItemMenuBuilder.entries(for: ItemMenuContext(scope: .trash, itemIds: [regular.id]), snapshot: snapshot, groups: groups)
        #expect(titles(entries) == ["恢复", "彻底删除"])
    }

    @Test func fileRowsCanBecomeTheDefault() {
        let onDefault = ItemMenuBuilder.entries(for: ItemMenuContext(scope: .all, itemIds: [], fileId: fileA.id), snapshot: snapshot, groups: groups)
        #expect(onDefault.contains(.action(title: "设为默认打开文件", symbol: "star", command: .setDefaultFile(fileA.id), enabled: false, checked: true)))
        let onOther = ItemMenuBuilder.entries(for: ItemMenuContext(scope: .all, itemIds: [], fileId: fileB.id), snapshot: snapshot, groups: groups)
        #expect(onOther.contains(.action(title: "设为默认打开文件", symbol: "star", command: .setDefaultFile(fileB.id))))
        #expect(titles(onOther).contains("删除"))
    }

    @Test func itemMenuInUserGroupHasRemoveAndDelete() {
        let childId = groups[1].group.id
        let entries = ItemMenuBuilder.entries(for: ItemMenuContext(scope: .group(childId), itemIds: [regular.id]), snapshot: snapshot, groups: groups)
        let names = titles(entries)
        for expected in ["打开", "快速查看", "添加到", "标签", "阅读状态", "评分", "复制引用", "添加文件…", "重新检索元数据", "在 Finder 中显示", "从当前分组移除", "删除"] {
            #expect(names.contains(expected), "missing \(expected)")
        }
        let addTo = submenu("添加到", in: entries)
        #expect(titles(addTo) == ["Parent"], "the current group is not offered")
    }

    @Test func builtInViewsHaveNoRemoveFromGroup() {
        let entries = ItemMenuBuilder.entries(for: ItemMenuContext(scope: .all, itemIds: [regular.id]), snapshot: snapshot, groups: groups)
        #expect(!titles(entries).contains("从当前分组移除"))
        let addTo = submenu("添加到", in: entries)
        #expect(addTo.contains(.action(title: "Child", symbol: "folder", command: .addToGroup(groups[1].group.id), checked: true, indent: 1)),
                "existing membership is ticked and subgroups are indented")
    }

    @Test func standaloneFilesOfferRetrievalFallbacks() {
        let names = titles(ItemMenuBuilder.entries(for: ItemMenuContext(scope: .all, itemIds: [standalone.id]), snapshot: snapshot, groups: groups))
        #expect(names.contains("重新检索元数据"))
        #expect(names.contains("手动匹配…"))
        #expect(!names.contains("复制引用"))
        #expect(!names.contains("阅读状态"))
    }

    @Test func multipleSelectionHidesSingleItemActions() {
        let names = titles(ItemMenuBuilder.entries(for: ItemMenuContext(scope: .all, itemIds: [regular.id, other.id]), snapshot: snapshot, groups: groups))
        #expect(!names.contains("添加文件…"))
        #expect(names.contains("删除"))
    }

    @Test func tagSubmenuTicksAppliedTagsAndOffersNewTag() {
        let entries = ItemMenuBuilder.entries(for: ItemMenuContext(scope: .all, itemIds: [regular.id]), snapshot: snapshot, groups: groups)
        let tags = submenu("标签", in: entries)
        #expect(tags.contains(.action(title: "必读", symbol: nil, command: .toggleTag(snapshot.tags[0].id), checked: true)))
        #expect(titles(tags).last == "新建标签…")
    }
}
