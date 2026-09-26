import Foundation
import Testing
import FolioCore
@testable import FolioZotero

/// End-to-end tests driving `ZoteroReader` against a minimal, SQL-built Zotero database —
/// covering every scenario called out in the Task 2C spec.
@Suite struct ZoteroReaderTests {
    @Test func flattensThreeLevelCollectionAndSkipsNonRegularAndTrashedItems() throws {
        let fixture = try ZoteroFixtureDB()

        // Collections: 论文辅导 (top) > 2025年 (mid) > B (deep, not exported).
        try fixture.addCollection(id: 1, key: "TOP1", name: "论文辅导")
        try fixture.addCollection(id: 2, key: "MID1", name: "2025年", parent: 1)
        try fixture.addCollection(id: 3, key: "DEEP1", name: "B", parent: 2)

        // A kept regular item, filed directly in the deep (level-3) collection.
        try fixture.addItem(id: 10, type: ZoteroFixtureDB.journalArticleType)
        try fixture.addField(item: 10, name: "title", value: "Kept Paper")
        try fixture.addToCollection(item: 10, collection: 3)

        // A trashed regular item — must not appear, and must count as trashed (not "kept").
        try fixture.addItem(id: 11, type: ZoteroFixtureDB.journalArticleType)
        try fixture.addField(item: 11, name: "title", value: "Trashed Paper")
        try fixture.trash(item: 11)

        // A note and an annotation — always skipped, and counted under their own reason.
        try fixture.addItem(id: 12, type: ZoteroFixtureDB.noteType)
        try fixture.addItem(id: 13, type: ZoteroFixtureDB.annotationType)

        let reader = try ZoteroReader(dataDirectory: fixture.directory)
        let (library, report) = try reader.read(options: ZoteroReadOptions())

        #expect(report.regularItems == 1)
        #expect(report.skippedTrashed == 1)
        #expect(report.skippedNotes == 1)
        #expect(report.skippedAnnotations == 1)

        // Only the two exportable levels become groups; "B" is merged into its level-2 ancestor.
        #expect(library.groups.count == 2)
        #expect(report.collections == 2)
        let top = library.groups.first { $0.key == "TOP1" }
        let mid = library.groups.first { $0.key == "MID1" }
        #expect(top?.parentKey == nil)
        #expect(mid?.parentKey == "TOP1")
        #expect(!library.groups.contains { $0.key == "DEEP1" })

        let kept = library.entries.first { if case .regular(let m) = $0.kind { return m.title == "Kept Paper" } else { return false } }
        #expect(kept?.groupKeys == ["MID1"])
    }

    @Test func linkedFileAndConnectorDownloadedAttachmentsAreKeptOnlyHTMLSnapshotIsSkipped() throws {
        let fixture = try ZoteroFixtureDB()
        try fixture.addItem(id: 20, type: ZoteroFixtureDB.journalArticleType)
        try fixture.addField(item: 20, name: "title", value: "Item With Attachments")

        // linkMode 2: linked file with an absolute path — kept.
        try fixture.addAttachment(id: 21, parent: 20, linkMode: ZoteroFixtureDB.linkedFileLinkMode, path: "/Users/me/Papers/linked.pdf")
        // linkMode 1, contentType text/html: an actual web snapshot — skipped.
        try fixture.addAttachment(id: 22, parent: 20, linkMode: ZoteroFixtureDB.snapshotLinkMode, path: "storage:snapshot.html", contentType: "text/html")
        // linkMode 3: linked URL — skipped.
        try fixture.addAttachment(id: 23, parent: 20, linkMode: ZoteroFixtureDB.linkedURLLinkMode, path: nil)
        // linkMode 1, contentType application/pdf: the browser connector downloaded this PDF
        // the same way it downloads snapshots — must be kept like an imported file.
        try fixture.addAttachment(id: 24, parent: 20, linkMode: ZoteroFixtureDB.snapshotLinkMode, path: "storage:downloaded.pdf", contentType: "application/pdf")

        let reader = try ZoteroReader(dataDirectory: fixture.directory)
        let (library, report) = try reader.read(options: ZoteroReadOptions())

        #expect(report.skippedSnapshots == 1)
        #expect(report.skippedLinks == 1)
        let entry = library.entries.first!
        #expect(entry.files.count == 2)
        #expect(entry.files.contains { $0.sourceURL.path == "/Users/me/Papers/linked.pdf" })
        #expect(entry.files.contains { $0.originalName == "downloaded.pdf" })
    }

    @Test func standaloneAttachmentBecomesStandaloneEntry() throws {
        let fixture = try ZoteroFixtureDB()
        try fixture.addAttachment(id: 30, parent: nil, linkMode: ZoteroFixtureDB.importedFileLinkMode, path: "storage:notes.pdf", key: "STAND1")

        let reader = try ZoteroReader(dataDirectory: fixture.directory)
        let (library, report) = try reader.read(options: ZoteroReadOptions())

        #expect(report.standaloneFiles == 1)
        #expect(report.regularItems == 0)
        #expect(library.entries.count == 1)
        guard case .standalone = library.entries[0].kind else {
            Issue.record("expected a standalone entry")
            return
        }
        #expect(library.entries[0].files.first?.originalName == "notes.pdf")
    }

    @Test func defaultFileOrderingPrefersNonComparePDF() throws {
        let fixture = try ZoteroFixtureDB()
        try fixture.addItem(id: 40, type: ZoteroFixtureDB.journalArticleType)
        try fixture.addField(item: 40, name: "title", value: "Bilingual Paper")
        // The compare (bilingual) PDF was added first, but the original must still sort first.
        try fixture.addAttachment(id: 41, parent: 40, linkMode: 0, path: "storage:Paper.compare.pdf", dateAdded: "2026-01-01 00:00:00")
        try fixture.addAttachment(id: 42, parent: 40, linkMode: 0, path: "storage:Paper.pdf", dateAdded: "2026-01-02 00:00:00")

        let reader = try ZoteroReader(dataDirectory: fixture.directory)
        let (library, _) = try reader.read(options: ZoteroReadOptions())

        let entry = library.entries.first!
        #expect(entry.files.map(\.originalName) == ["Paper.pdf", "Paper.compare.pdf"])
    }

    @Test func appliesTagColorsAndAutomaticTagToggle() throws {
        let fixture = try ZoteroFixtureDB()
        try fixture.addItem(id: 50, type: ZoteroFixtureDB.journalArticleType)
        try fixture.addField(item: 50, name: "title", value: "Tagged Paper")
        try fixture.addTag(item: 50, name: "Important", type: 0)
        try fixture.addTag(item: 50, name: "cs.CV", type: 1)
        try fixture.setTagColors(##"[{"name":"Important","color":"#FF3B30"}]"##)

        let reader = try ZoteroReader(dataDirectory: fixture.directory)

        let (libraryDefault, reportDefault) = try reader.read(options: ZoteroReadOptions())
        #expect(reportDefault.tags == 1)
        #expect(reportDefault.automaticTagsAvailable == 1)
        let importantTag = libraryDefault.tags.first { $0.name == "Important" }
        #expect(importantTag?.colorHex == "#FF3B30")
        #expect(libraryDefault.entries.first?.tagNames == ["Important"])

        var withAutomatic = ZoteroReadOptions()
        withAutomatic.includeAutomaticTags = true
        let (libraryAuto, reportAuto) = try reader.read(options: withAutomatic)
        #expect(reportAuto.tags == 2)
        let autoTag = libraryAuto.tags.first { $0.name == "cs.CV" }
        #expect(autoTag?.colorHex == ZoteroTagColorParsing.defaultColorHex)
    }

    @Test func fieldMappingCoversFallbackYearCreatorsAndArxiv() throws {
        let fixture = try ZoteroFixtureDB()

        // Conference paper: source falls back to conferenceName; year/date from multipart date;
        // two creators ordered by orderIndex.
        try fixture.addItem(id: 60, type: ZoteroFixtureDB.conferencePaperType)
        try fixture.addField(item: 60, name: "title", value: "Conference Work")
        try fixture.addField(item: 60, name: "conferenceName", value: "CVPR 2026")
        try fixture.addField(item: 60, name: "date", value: "2026-06-00 6/2026")
        try fixture.addCreator(item: 60, order: 1, family: "Zhang", given: "Bao")
        try fixture.addCreator(item: 60, order: 0, family: "Gao", given: "Fan")

        // Preprint: arXiv id from archiveID; organisation creator via fieldMode = 1.
        try fixture.addItem(id: 61, type: ZoteroFixtureDB.preprintType)
        try fixture.addField(item: 61, name: "title", value: "Preprint Work")
        try fixture.addField(item: 61, name: "repository", value: "arXiv")
        try fixture.addField(item: 61, name: "archiveID", value: "arXiv:2604.27326")
        try fixture.addCreator(item: 61, order: 0, family: "OpenAI Consortium", given: "", fieldMode: 1)

        let reader = try ZoteroReader(dataDirectory: fixture.directory)
        let (library, _) = try reader.read(options: ZoteroReadOptions())

        func metadata(_ id: String) -> Metadata {
            let entry = library.entries.first { if case .regular(let m) = $0.kind { return m.title == id } else { return false } }!
            guard case .regular(let m) = entry.kind else { fatalError() }
            return m
        }

        let conference = metadata("Conference Work")
        #expect(conference.type == .conferencePaper)
        #expect(conference.source == "CVPR 2026")
        #expect(conference.year == 2026)
        #expect(conference.date == "2026-06")
        #expect(conference.authors.map(\.family) == ["Gao", "Zhang"])
        #expect(conference.authors.map(\.given) == ["Fan", "Bao"])

        let preprint = metadata("Preprint Work")
        #expect(preprint.type == .preprint)
        #expect(preprint.source == "arXiv")
        #expect(preprint.arxivId == "2604.27326")
        #expect(preprint.authors == [Author(family: "OpenAI Consortium", given: "")])
    }
}
