import Foundation
import PDFKit
import Testing
@testable import FolioCore

@Suite struct TagTests {
    @Test func tagNamesAreValidatedAndUnique() throws {
        let lib = try Library.temporary()
        #expect(throws: LibraryError.emptyName) { try lib.createTag(name: " ", colorHex: "#FF0000") }
        let tag = try lib.createTag(name: "Mamba", colorHex: "#FF0000")
        #expect(throws: LibraryError.duplicateTagName("MAMBA")) { try lib.createTag(name: "MAMBA", colorHex: "#00FF00") }
        try lib.updateTag(tag.id, name: "Mamba 模型", colorHex: "#007AFF")
        #expect(try lib.snapshot().tagsById[tag.id]?.colorHex == "#007AFF")
    }

    @Test func tagsApplyInBatchAndDeleteEverywhere() throws {
        let lib = try Library.temporary()
        let a = try lib.importItem("A")
        let b = try lib.importItem("B")
        let tag = try lib.createTag(name: "必读", colorHex: "#FF3B30")
        try lib.setTag(tag.id, onItems: [a, b], enabled: true)
        #expect(Set(try lib.rows(.tag(tag.id))) == [a, b])
        #expect(try lib.itemCount(withTag: tag.id) == 2)
        try lib.setTag(tag.id, onItems: [b], enabled: false)
        #expect(try lib.rows(.tag(tag.id)) == [a])
        try lib.deleteTag(tag.id)
        #expect(try lib.snapshot().itemTags[a] == nil)
    }
}

@Suite struct ViewResolverTests {
    @Test func builtInViews() throws {
        let lib = try Library.temporary()
        let g = try lib.createGroup(name: "G")
        let filed = try lib.importItem("Filed", toGroup: g.id)
        let loose = try lib.importOne(try Fixture.pdf(lines: ["loose file"]))
        let gone = try lib.importItem("Gone")
        try lib.trashItems([gone])
        #expect(Set(try lib.rows(.all)) == [filed, loose])
        #expect(try lib.rows(.unfiled) == [loose])
        #expect(try lib.rows(.trash) == [gone])
    }

    @Test func parentGroupIncludesSubgroupItemsWhenEnabled() throws {
        let lib = try Library.temporary()
        let parent = try lib.createGroup(name: "P")
        let child = try lib.createGroup(name: "C", parentId: parent.id)
        let own = try lib.importItem("Own", toGroup: parent.id)
        let nested = try lib.importItem("Nested", toGroup: child.id)
        #expect(Set(try lib.rows(.group(parent.id))) == [own, nested])
        #expect(try lib.rows(.group(parent.id), includeSubgroups: false) == [own])
        let counts = SidebarCounts.compute(try lib.snapshot(), includeSubgroupItems: true)
        #expect(counts[.group(parent.id)] == 2)
        #expect(counts[.all] == 2)
    }

    @Test func searchRequiresAllTokensAndMatchesTagsAndFiles() throws {
        let lib = try Library.temporary()
        let unet = try lib.importItem("UNet++ nested architecture")
        _ = try lib.importItem("Night-time scene parsing")
        let tag = try lib.createTag(name: "segmentation", colorHex: "#34C759")
        try lib.setTag(tag.id, onItems: [unet], enabled: true)
        #expect(try lib.rows(.all, search: "unet nested") == [unet])
        #expect(try lib.rows(.all, search: "unet night").isEmpty)
        #expect(try lib.rows(.all, search: "SEGMENTATION") == [unet])
        #expect(try lib.rows(.all, search: "zhang_2026_unet") == [unet], "matches the stored file name")
    }

    @Test func wholeLibrarySearchIgnoresCurrentGroupAndFulltextUnions() throws {
        let lib = try Library.temporary()
        let g = try lib.createGroup(name: "G")
        let inGroup = try lib.importItem("Alpha", toGroup: g.id)
        let outside = try lib.importItem("Alpha beta")
        let s = try lib.snapshot()
        var q = ViewQuery(scope: .group(g.id), searchText: "alpha")
        #expect(ViewResolver.rows(q, in: s) == [inGroup])
        q.searchWholeLibrary = true
        #expect(Set(ViewResolver.rows(q, in: s)) == [inGroup, outside])
        q = ViewQuery(scope: .all, searchText: "transformer", fulltextItemIds: [outside])
        #expect(ViewResolver.rows(q, in: s) == [outside])
    }

    @Test func columnSortPutsEmptyValuesLast() throws {
        let lib = try Library.temporary()
        let old = try lib.importItem("Old")
        let new = try lib.importItem("New")
        let none = try lib.importItem("None")
        try lib.updateItem(old) { $0.year = 2001 }
        try lib.updateItem(new) { $0.year = 2024 }
        try lib.updateItem(none) { $0.year = nil }
        let s = try lib.snapshot()
        let desc = ViewQuery(scope: .all, sort: SortState(column: .year, ascending: false))
        #expect(ViewResolver.rows(desc, in: s) == [new, old, none])
        let asc = ViewQuery(scope: .all, sort: SortState(column: .year, ascending: true))
        #expect(ViewResolver.rows(asc, in: s) == [old, new, none])
    }

    @Test func customOrderPersistsAndNewItemsComeFirst() throws {
        let lib = try Library.temporary()
        let a = try lib.importItem("A")
        let b = try lib.importItem("B")
        let c = try lib.importItem("C")
        let shown = try lib.rows(.all)
        #expect(shown == [c, b, a], "newest first by default")
        try lib.moveItems([a], inScope: .all, displayedOrder: shown, toIndex: 0)
        #expect(try lib.rows(.all) == [a, c, b])
        let d = try lib.importItem("D")
        #expect(try lib.rows(.all) == [d, a, c, b])
    }

    @Test func movingWhileColumnSortedSwitchesToCustomOrder() throws {
        let lib = try Library.temporary()
        let a = try lib.importItem("A")
        let b = try lib.importItem("B")
        try lib.setSort(SortState(column: .title, ascending: true), forScope: .all)
        let shown = try lib.rows(.all)
        #expect(shown == [a, b])
        try lib.moveItems([b], inScope: .all, displayedOrder: shown, toIndex: 0)
        #expect(try lib.snapshot().sort(for: .all) == .manual)
        #expect(try lib.rows(.all) == [b, a])
    }

    @Test func resolvesFiveThousandItemsQuickly() throws {
        var s = LibrarySnapshot()
        for i in 0..<5_000 {
            var item = Item(kind: .regular, title: "Paper number \(i) about segmentation")
            item.year = 2000 + i % 25
            s.items[item.id] = item
            s.searchText[item.id] = item.title.lowercased()
        }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            _ = ViewResolver.rows(ViewQuery(scope: .all, searchText: "segmentation 12"), in: s)
            _ = ViewResolver.rows(ViewQuery(scope: .all, sort: SortState(column: .year, ascending: false)), in: s)
        }
        #expect(elapsed < .milliseconds(500), "debug build budget; release target is 100 ms")
    }
}

@Suite struct PDFAndFulltextTests {
    @Test func extractsTextAndIndexesIt() throws {
        let lib = try Library.temporary()
        let id = try lib.importOne(try Fixture.pdf(lines: ["Vision Mamba", "state space models for dense prediction"]))
        let file = try #require(try lib.filesNeedingFulltext().first)
        let text = try #require(PDFTextExtractor.fullText(of: lib.fileURL(for: file)))
        #expect(text.contains("state space"))
        try lib.setFulltext(fileId: file.id, text: text)
        #expect(try lib.fulltextItemIds(matching: "dense predict") == [id])
        #expect(try lib.fulltextItemIds(matching: "dense banana").isEmpty)
        #expect(try lib.filesNeedingFulltext().isEmpty)
    }

    @Test func readsHighlightAnnotations() throws {
        let url = try Fixture.pdf(lines: ["Highlighted Title", "some body text here"])
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let selection = try #require(page.selection(for: CGRect(x: 50, y: 730, width: 400, height: 30)))
        let bounds = selection.bounds(for: page)
        let highlight = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
        highlight.color = .yellow
        highlight.contents = "important"
        page.addAnnotation(highlight)
        #expect(document.write(to: url))

        let annotations = AnnotationReader.annotations(in: url)
        #expect(annotations.count == 1)
        #expect(annotations.first?.kind == .highlight)
        #expect(annotations.first?.comment == "important")
        #expect(annotations.first?.quotedText.contains("Highlighted") == true)
        #expect(annotations.first?.page == 1)
    }

    @Test func detectsFilesChangedOnDisk() throws {
        let lib = try Library.temporary()
        let id = try lib.importOne(try Fixture.pdf(lines: ["Original"]))
        var file = try #require(try lib.files(ofItem: id).first)
        try lib.setFulltext(fileId: file.id, text: "Original")
        #expect(try lib.refreshFingerprints().isEmpty)
        try Data("changed contents".utf8).write(to: lib.fileURL(for: file))
        #expect(try lib.refreshFingerprints() == [file.id])
        file = try #require(try lib.files(ofItem: id).first)
        #expect(file.fulltextState == .pending)
        #expect(file.sha256 != file.originalSha256)
    }
}

@Suite struct BulkImportTests {
    @Test func importsGroupsTagsItemsAndSkipsDuplicates() throws {
        let lib = try Library.temporary()
        let dir = try Fixture.directory()
        let pdf = try Fixture.pdf(named: "z.pdf", lines: ["Zotero paper"], in: dir)
        var meta = Fixture.metadata("Zotero Paper", doi: "10.9/z")
        meta.type = .conferencePaper
        let prepared = PreparedLibrary(
            groups: [PreparedGroup(key: "P", name: "Parent", position: 0),
                     PreparedGroup(key: "C", name: "Child", parentKey: "P", position: 0)],
            tags: [PreparedTag(name: "Colored", colorHex: "#FF2D55")],
            entries: [
                PreparedEntry(kind: .regular(meta), files: [PreparedFile(sourceURL: pdf, originalName: "z.pdf", dateAdded: Date())],
                              groupKeys: ["C"], tagNames: ["Colored", "plain"], dateAdded: Date(timeIntervalSince1970: 1_000),
                              dateModified: Date(timeIntervalSince1970: 2_000)),
                PreparedEntry(kind: .regular(meta), files: [], dateAdded: Date(), dateModified: Date()),
                PreparedEntry(kind: .regular(Fixture.metadata("No file")),
                              files: [PreparedFile(sourceURL: dir.appending(path: "missing.pdf"), originalName: "m.pdf", dateAdded: Date())],
                              dateAdded: Date(), dateModified: Date()),
            ])
        let summary = try lib.importPrepared(prepared)
        #expect(summary.itemsImported == 2)
        #expect(summary.duplicatesSkipped == 1)
        #expect(summary.missingFiles == 1)
        #expect(summary.groupsCreated == 2)
        #expect(summary.tagsCreated == 2)

        let s = try lib.snapshot()
        let child = try #require(s.groupsById.values.first { $0.name == "Child" })
        #expect(s.groupsById[child.parentId ?? ""]?.name == "Parent")
        let item = try #require(s.items.values.first { $0.title == "Zotero Paper" })
        #expect(item.dateAdded == Date(timeIntervalSince1970: 1_000))
        #expect(s.itemGroups[item.id] == [child.id])
        #expect(Set(s.tags(of: item.id).map(\.name)) == ["Colored", "plain"])
        #expect(s.tags.first { $0.name == "plain" }?.colorHex == "#8E8E93")
        #expect(s.files(of: item.id).first?.relativePath == "Files/Zhang_2026_Zotero Paper.pdf")

        let again = try lib.importPrepared(prepared)
        #expect(again.itemsImported == 0)
        #expect(again.groupsCreated == 0)
        #expect(again.tagsCreated == 0)
    }
}
