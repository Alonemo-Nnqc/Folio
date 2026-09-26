import Foundation
import Testing
@testable import FolioCore

@Suite struct ImportTests {
    @Test func importsDistinctFilesAsStandaloneItems() throws {
        let lib = try Library.temporary()
        let a = try Fixture.pdf(named: "a.pdf", lines: ["Paper A"])
        let b = try Fixture.pdf(named: "b.pdf", lines: ["Paper B"])
        let outcomes = try lib.importFiles([a, b])
        #expect(outcomes.count == 2)
        let s = try lib.snapshot()
        #expect(s.items.count == 2)
        for item in s.items.values {
            #expect(item.kind == .standalone)
            #expect(item.metadataState == .pending)
            #expect(item.defaultFileId == s.filesByItem[item.id]?.first)
        }
        #expect(FileManager.default.fileExists(atPath: a.path), "original file must stay in place")
    }

    @Test func sameContentIsDuplicate() throws {
        let lib = try Library.temporary()
        let a = try Fixture.pdf(named: "a.pdf", lines: ["Paper A"])
        let id = try lib.importOne(a)
        let copy = FileManager.default.temporaryDirectory.appending(path: "copy-\(UUID().uuidString).pdf")
        try FileManager.default.copyItem(at: a, to: copy)
        #expect(try lib.importFiles([copy]) == [.duplicateFile(existingItemId: id, addedToGroup: false)])
    }

    @Test func duplicateImportedIntoGroupJoinsTheGroup() throws {
        let lib = try Library.temporary()
        let a = try Fixture.pdf(lines: ["Paper A"])
        let id = try lib.importOne(a)
        let group = try lib.createGroup(name: "G")
        #expect(try lib.importFiles([a], toGroup: group.id) == [.duplicateFile(existingItemId: id, addedToGroup: true)])
        #expect(try lib.rows(.group(group.id)) == [id])
    }

    @Test func duplicateInTrashIsReported() throws {
        let lib = try Library.temporary()
        let a = try Fixture.pdf(lines: ["Paper A"])
        let id = try lib.importOne(a)
        try lib.trashItems([id])
        #expect(try lib.importFiles([a]) == [.duplicateInTrash(existingItemId: id)])
    }

    @Test func nonPDFNeedsNoMetadata() throws {
        let lib = try Library.temporary()
        let note = try Fixture.textFile(named: "notes.txt", contents: "hello")
        let id = try lib.importOne(note)
        #expect(try lib.item(id)?.metadataState == MetadataState.none)
    }

    @Test func importedFileIsCopiedIntoFilesFolder() throws {
        let lib = try Library.temporary()
        let id = try lib.importOne(try Fixture.pdf(named: "My Paper.pdf", lines: ["X"]))
        let file = try #require(try lib.files(ofItem: id).first)
        #expect(file.relativePath == "Files/My Paper.pdf")
        #expect(FileManager.default.fileExists(atPath: lib.fileURL(for: file).path))
    }
}

@Suite struct MetadataApplicationTests {
    @Test func standaloneBecomesItemAndFileIsRenamed() throws {
        let lib = try Library.temporary()
        let id = try lib.importOne(try Fixture.pdf(named: "2604.27326v1.pdf", lines: ["Spectral"]))
        let outcome = try lib.applyMetadata(Fixture.metadata("Spectral Dynamic Attention"), toStandalone: id, autoRename: true)
        #expect(outcome == .created(itemId: id))
        let item = try #require(try lib.item(id))
        #expect(item.kind == .regular)
        #expect(item.metadataState == .resolved)
        #expect(item.citationKey == "zhang2026")
        #expect(item.readStatus == .unread)
        let file = try #require(try lib.files(ofItem: id).first)
        #expect(item.defaultFileId == file.id)
        #expect(file.relativePath == "Files/Zhang_2026_Spectral Dynamic Attention.pdf")
    }

    @Test func autoRenameOffKeepsName() throws {
        let lib = try Library.temporary()
        let id = try lib.importOne(try Fixture.pdf(named: "keep.pdf", lines: ["K"]))
        _ = try lib.applyMetadata(Fixture.metadata("Title"), toStandalone: id, autoRename: false)
        #expect(try lib.files(ofItem: id).first?.relativePath == "Files/keep.pdf")
    }

    @Test func sameDOIIsDuplicateAndNothingChanges() throws {
        let lib = try Library.temporary()
        let existing = try lib.importItem("Paper", doi: "10.1/x")
        let id = try lib.importOne(try Fixture.pdf(lines: ["Other bytes"]))
        let outcome = try lib.applyMetadata(Fixture.metadata("Paper (published)", doi: "10.1/X"), toStandalone: id, autoRename: true)
        #expect(outcome == .duplicateItem(existingItemId: existing))
        #expect(try lib.item(id)?.kind == .standalone)
    }

    @Test func mergeAttachesFileAndTransfersGroups() throws {
        let lib = try Library.temporary()
        let group = try lib.createGroup(name: "Reading")
        let existing = try lib.importItem("Paper", doi: "10.1/x")
        let id = try lib.importOne(try Fixture.pdf(lines: ["Other"]), toGroup: group.id)
        try lib.mergeStandalone(id, intoItem: existing, autoRename: true)
        #expect(try lib.item(id) == nil)
        #expect(try lib.files(ofItem: existing).count == 2)
        #expect(try lib.rows(.group(group.id)) == [existing])
    }

    @Test func discardRemovesItemAndFile() throws {
        let lib = try Library.temporary()
        let id = try lib.importOne(try Fixture.pdf(lines: ["X"]))
        let url = lib.fileURL(for: try #require(try lib.files(ofItem: id).first))
        try lib.discardStandalone(id)
        #expect(try lib.item(id) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func createItemDetectsDuplicates() throws {
        let lib = try Library.temporary()
        guard case .created(let id) = try lib.createItem(Fixture.metadata("A", doi: "10.2/a")) else {
            Issue.record("expected creation"); return
        }
        #expect(try lib.createItem(Fixture.metadata("A again", doi: "10.2/A")) == .duplicate(existingItemId: id))
        #expect(try lib.snapshot().filesByItem[id] == nil)
    }

    @Test func addFilesAppendsAndRejectsDuplicates() throws {
        let lib = try Library.temporary()
        let id = try lib.importItem("Paper")
        let supplement = try Fixture.pdf(named: "supp.pdf", lines: ["Supplement"])
        let first = try lib.addFiles([supplement], toItem: id, autoRename: true)
        guard case .added = first.first else { Issue.record("expected add"); return }
        #expect(try lib.addFiles([supplement], toItem: id, autoRename: true) == [.duplicate(existingItemId: id)])
        let files = try lib.files(ofItem: id)
        #expect(files.count == 2)
        #expect(files[1].relativePath == "Files/Zhang_2026_Paper 2.pdf")
        #expect(try lib.item(id)?.defaultFileId == files[0].id)
    }

    @Test func setDefaultFileSwitches() throws {
        let lib = try Library.temporary()
        let id = try lib.importItem("Paper")
        _ = try lib.addFiles([try Fixture.pdf(named: "b.pdf", lines: ["B"])], toItem: id, autoRename: false)
        let second = try lib.files(ofItem: id)[1]
        try lib.setDefaultFile(second.id)
        #expect(try lib.item(id)?.defaultFileId == second.id)
    }

    @Test func updateMetadataKeepsUserFields() throws {
        let lib = try Library.temporary()
        let id = try lib.importItem("Old")
        try lib.updateItem(id) { $0.rating = 4; $0.readStatus = .read }
        try lib.updateMetadata(id, Fixture.metadata("New Title"), autoRename: true)
        let item = try #require(try lib.item(id))
        #expect(item.title == "New Title")
        #expect(item.rating == 4)
        #expect(item.readStatus == .read)
        #expect(try lib.files(ofItem: id).first?.relativePath == "Files/Zhang_2026_New Title.pdf")
    }
}
