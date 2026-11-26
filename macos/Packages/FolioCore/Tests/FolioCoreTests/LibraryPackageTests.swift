import Foundation
import Testing
@testable import FolioCore

@Suite struct LibraryPackageTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "folio-package-tests-\(UUID().uuidString)")

    init() throws { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }

    private func pdf(_ name: String, _ text: String) throws -> URL {
        let url = folder.appending(path: name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func importFile(_ url: URL, _ library: Library) throws -> String {
        guard case .imported(let id, _) = try library.importFiles([url])[0] else { throw LibraryError.notFound }
        return id
    }

    private func export(_ library: Library, settings: Data? = nil) throws -> LibraryPackage {
        let url = folder.appending(path: "\(UUID().uuidString).foliolib")
        _ = try library.exportPackage(to: url, settings: settings, appVersion: "1.6.0")
        return try LibraryPackage(url: url)
    }

    @discardableResult
    private func bring(_ package: LibraryPackage, into library: Library) throws -> LibraryImportSummary {
        try library.importPackage(package, discard: { try FileManager.default.removeItem(at: $0) })
    }

    @Test func aWholeLibraryMovesToAnEmptyOne() throws {
        let a = try Library.temporary(), b = try Library.temporary()
        let parent = try a.createGroup(name: "深度学习"), child = try a.createGroup(name: "分割", parentId: parent.id)
        let tag = try a.createTag(name: "必读", colorHex: "#FF3B30")
        let id = try importFile(pdf("论文 é.pdf", "pdf one"), a)
        var unet = Metadata(title: "U-Net")
        unet.authors = [Author(family: "Ronneberger", given: "Olaf")]
        unet.year = 2015
        _ = try a.applyMetadata(unet, toStandalone: id, autoRename: true)
        try a.addItems([id], toGroup: child.id, includeSubgroups: false)
        try a.setTag(tag.id, onItems: [id], enabled: true)
        try a.setNote("# 笔记\n\n很好", for: id)
        let file = try a.files(ofItem: id)[0]
        try a.setFulltext(fileId: file.id, text: "skip connections")
        try a.saveReadingState(ReadingState(fileId: file.id, pageIndex: 3, pointX: 0, pointY: 0, scale: 1, autoScale: true, displayMode: 1))
        let translated = try a.addTranslatedFile(at: pdf("t.pdf", "译文"), of: file.id, kind: .mono, baseName: "译文", translatedBy: "Google")
        let doc = try a.createMarkdownDocument(title: "计划", text: "[U-Net](folio://open?item=\(id))")
        let gone = try importFile(pdf("gone.pdf", "gone"), a)
        try a.trashItems([gone])

        let package = try export(a)
        #expect(package.info.items == 2 && package.info.files == 3 && package.info.groups == 2 && package.info.tags == 1)
        #expect(package.settings == nil && package.hasLibrary)
        let summary = try bring(package, into: b)
        #expect(summary.itemsAdded == 2 && summary.filesAdded == 3 && summary.groupsCreated == 2 && summary.tagsCreated == 1 && summary.missingFiles == 0)

        let from = try a.snapshot(), to = try b.snapshot()
        #expect(to.items[gone] == nil, "the trash stays behind")
        #expect(to.items[id]?.title == "U-Net" && to.items[id]?.citationKey == from.items[id]?.citationKey)
        #expect(to.items[id]?.defaultFileId == file.id)
        #expect(to.groupsById[child.id]?.parentId == parent.id && to.itemGroups[id] == [child.id])
        #expect(to.itemTags[id] == [tag.id])
        #expect(try b.note(for: id) == "# 笔记\n\n很好")
        #expect(try b.readingState(fileId: file.id)?.pageIndex == 3)
        #expect(try b.fulltextItemIds(matching: "connections") == [id])
        #expect(to.files[file.id]?.relativePath == from.files[file.id]?.relativePath)
        #expect(to.files[translated.id]?.translationOf == file.id)
        #expect(try Data(contentsOf: b.fileURL(for: to.files[file.id]!)) == Data("pdf one".utf8))
        #expect(try b.text(ofFile: doc.fileId).contains(id))
        #expect(try b.refreshFingerprints().isEmpty, "files are as their records say")

        // Again: nothing to do.
        let again = try bring(package, into: b)
        #expect(again == LibraryImportSummary(itemsUnchanged: 2))
        #expect(try b.snapshot().files.count == 3)
    }

    @Test func theNewerStays() throws {
        let a = try Library.temporary(), b = try Library.temporary()
        let id = try importFile(pdf("p.pdf", "old"), a), other = try importFile(pdf("q.pdf", "q"), a)
        try bring(export(a), into: b)
        let file = try a.files(ofItem: id)[0]
        // Annotated and described on a; another one rated on b.
        try Data("annotated".utf8).write(to: a.fileURL(for: file))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: a.fileURL(for: file).path)
        try a.updateItem(id) { $0.title = "new title" }
        try a.setNote("from a", for: id)
        try b.updateItem(other) { $0.rating = 5 }
        let summary = try bring(export(a), into: b)
        #expect(summary.itemsUpdated == 1 && summary.itemsUnchanged == 1 && summary.filesUpdated == 1 && summary.itemsAdded == 0)
        #expect(try b.item(id)?.title == "new title" && b.item(other)?.rating == 5 && b.note(for: id) == "from a")
        #expect(try String(contentsOf: b.fileURL(for: b.files(ofItem: id)[0]), encoding: .utf8) == "annotated")
        // The way back: what is newer here is not undone.
        try b.updateItem(id) { $0.title = "newer title" }
        try bring(export(a), into: b)
        #expect(try b.item(id)?.title == "newer title")
        // Back on a.
        try bring(export(b), into: a)
        #expect(try a.item(id)?.title == "newer title" && a.item(other)?.rating == 5)
    }

    @Test func theSamePaperAddedOnBothIsOne() throws {
        let a = try Library.temporary(), b = try Library.temporary()
        let inA = try importFile(pdf("x.pdf", "same bytes"), a)
        try a.setNote("a's note", for: inA)
        let inB = try importFile(pdf("y.pdf", "same bytes"), b)
        try b.setNote("b's note", for: inB)
        let group = try a.createGroup(name: "Reading"), groupB = try b.createGroup(name: "reading")
        try a.addItems([inA], toGroup: group.id, includeSubgroups: false)
        let tagA = try a.createTag(name: "Todo", colorHex: "#FF3B30"), tagB = try b.createTag(name: "todo", colorHex: "#34C759")
        try a.setTag(tagA.id, onItems: [inA], enabled: true)
        // Regular items without files match by what they are; links follow.
        var upper = Metadata(title: "Attention Is All You Need"), lower = Metadata(title: "Attention")
        upper.doi = "10.1/x"
        lower.doi = "10.1/x"
        guard case .created(let workA) = try a.createItem(upper),
              case .created(let workB) = try b.createItem(lower) else { return }
        let doc = try a.createMarkdownDocument(title: "d", text: "folio://open?item=\(workA)&page=2")
        _ = try a.createMarkdownDocument(title: "empty a")
        _ = try b.createMarkdownDocument(title: "empty b")

        let summary = try bring(export(a), into: b)
        #expect(summary.groupsCreated == 0 && summary.tagsCreated == 0 && summary.itemsAdded == 2)
        let snapshot = try b.snapshot()
        #expect(snapshot.items[inA] == nil && snapshot.items[workA] == nil && snapshot.items[workB] != nil)
        #expect(try b.files(ofItem: inB).count == 1)
        #expect(snapshot.itemGroups[inB] == [groupB.id] && snapshot.itemTags[inB] == [tagB.id])
        #expect(try b.note(for: inB) == "b's note\n\na's note")
        #expect(try b.text(ofFile: doc.fileId) == "folio://open?item=\(workB)&page=2")
        #expect(snapshot.items.count == 5)
        #expect(try bring(export(a), into: b).itemsAdded == 0, "again adds nothing")
        #expect(try b.note(for: inB) == "b's note\n\na's note")
    }

    @Test func whatWasDeletedComesBack() throws {
        let a = try Library.temporary(), b = try Library.temporary()
        let id = try importFile(pdf("p.pdf", "p"), a)
        try bring(export(a), into: b)
        try b.trashItems([id])
        try bring(export(a), into: b)
        #expect(try b.item(id)?.isTrashed == false)
        // A file taken out of its paper on its own keeps its id in the trash: the package's is another one.
        guard case .created(let work) = try a.createItem(Metadata(title: "W")) else { return }
        _ = try a.addFiles([pdf("w.pdf", "w")], toItem: work, autoRename: false)
        try bring(export(a), into: b)
        let file = try b.files(ofItem: work)[0]
        try b.trashFiles([file.id])
        #expect(try b.files(ofItem: work).isEmpty)
        try bring(export(a), into: b)
        #expect(try b.files(ofItem: work).count == 1 && b.files(ofItem: work)[0].id != file.id)
    }

    @Test func namesTakenAndFilesMissing() throws {
        let a = try Library.temporary(), b = try Library.temporary()
        let id = try importFile(pdf("same.pdf", "a's"), a), lost = try importFile(pdf("lost.pdf", "lost"), a)
        _ = try importFile(pdf("same.pdf", "b's"), b)
        try FileManager.default.removeItem(at: a.fileURL(for: a.files(ofItem: lost)[0]))
        let url = folder.appending(path: "m.foliolib")
        #expect(try a.exportPackage(to: url, appVersion: "1").missingFiles == 1)
        let summary = try bring(LibraryPackage(url: url), into: b)
        #expect(summary.itemsAdded == 1 && summary.missingFiles == 1)
        #expect(try b.files(ofItem: id)[0].relativePath == "Files/same 2.pdf")
        #expect(try b.item(lost) == nil)
    }

    @Test func settingsAlone() throws {
        let a = try Library.temporary()
        _ = try importFile(pdf("p.pdf", "p"), a)
        let url = folder.appending(path: "s.foliolib")
        try Data("what was here".utf8).write(to: url)
        _ = try a.exportPackage(to: url, includingLibrary: false, settings: Data("{}".utf8), appVersion: "1")
        let package = try LibraryPackage(url: url)
        #expect(!package.hasLibrary && package.settings == Data("{}".utf8) && package.info.items == 0)
        #expect(try bring(package, into: a) == LibraryImportSummary())
        try Data("no zip at all, but long enough to look".utf8).write(to: url)
        #expect(throws: ZipError.self) { try LibraryPackage(url: url) }
    }

    @Test func passwordBox() throws {
        let box = try PasswordBox(Data("sk-钥匙".utf8), password: "密码 1", rounds: 1000)
        #expect(box.open(password: "密码 1") == Data("sk-钥匙".utf8))
        #expect(box.open(password: "密码 2") == nil)
        // Written by the Windows app (LibraryPackageTests.cs reads one of the macOS app).
        let shared = #"{"salt":"NCgrz9XOnhI8tUHVd1VNHw==","rounds":1000,"sealed":"jtlA7OMYexpPXH93oCaB0Y+awXwb16dv9Q4D3tBuWggy"}"#
        #expect(try JSONDecoder().decode(PasswordBox.self, from: Data(shared.utf8)).open(password: "pässword") == Data("folio".utf8))
        if ProcessInfo.processInfo.environment["FOLIO_UNPACK"] != nil {
            print("MACBOX", String(decoding: try JSONEncoder().encode(PasswordBox(Data("folio".utf8), password: "pässword", rounds: 1000)), as: UTF8.self))
        }
    }

    /// `FOLIO_PACK_LIBRARY` (a library's folder) packed as `FOLIO_PACK_TO`; `FOLIO_UNPACK` (a package, of the Windows app) read
    /// into an empty library.
    @Test func betweenPlatforms() throws {
        let environment = ProcessInfo.processInfo.environment
        if let root = environment["FOLIO_PACK_LIBRARY"], let to = environment["FOLIO_PACK_TO"] {
            print(try Library(root: URL(filePath: root)).exportPackage(to: URL(filePath: to), settings: Data(#"{"platform":"macos","values":{}}"#.utf8), appVersion: "1.6.0"))
        }
        if let path = environment["FOLIO_UNPACK"] {
            let package = try LibraryPackage(url: URL(filePath: path)), library = try Library.temporary()
            let summary = try bring(package, into: library)
            print(package.info, summary)
            #expect(summary.itemsAdded == package.info.items && summary.filesAdded == package.info.files && summary.missingFiles == 0)
            #expect(try library.refreshFingerprints().isEmpty)
        }
    }

    /// Archives other programs write (deflated) and read.
    @Test func zipIsAZip() throws {
        let text = String(repeating: "Folio 文献库 ", count: 200_000), source = try pdf("big.txt", text)
        let mine = folder.appending(path: "mine.zip"), theirs = folder.appending(path: "theirs.zip")
        let writer = try ZipWriter(url: mine)
        try writer.add(Data(), as: "空.txt")
        try writer.add(contentsOf: source, as: "Files/大.txt")
        try writer.finish()
        func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(filePath: tool)
            process.arguments = arguments
            process.currentDirectoryURL = folder
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        #expect(try run("/usr/bin/unzip", ["-tq", mine.path]) == 0)
        #expect(try run("/usr/bin/zip", ["-q", theirs.path, "big.txt"]) == 0)
        let reader = try ZipReader(url: theirs)
        #expect(try reader.data("big.txt") == Data(text.utf8))
        let own = try ZipReader(url: mine)
        #expect(try own.data("Files/大.txt") == Data(text.utf8) && own.data("空.txt").isEmpty)
        // A damaged entry is told.
        var bytes = try Data(contentsOf: mine)
        bytes[200_000] ^= 0xFF
        try bytes.write(to: mine)
        #expect(throws: ZipError.self) { try ZipReader(url: mine).data("Files/大.txt") }
    }
}
