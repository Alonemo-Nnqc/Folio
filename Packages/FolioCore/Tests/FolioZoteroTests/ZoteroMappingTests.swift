import Foundation
import Testing
import FolioCore
@testable import FolioZotero

@Suite struct ZoteroDateTests {
    @Test func parsesFullDate() {
        let parsed = ZoteroDate.parseFieldValue("2024-12-11 2024-12-11")
        #expect(parsed.year == 2024)
        #expect(parsed.normalized == "2024-12-11")
    }

    @Test func parsesYearMonthOnly() {
        let parsed = ZoteroDate.parseFieldValue("2024-09-00 09/2024")
        #expect(parsed.year == 2024)
        #expect(parsed.normalized == "2024-09")
    }

    @Test func parsesYearOnly() {
        let parsed = ZoteroDate.parseFieldValue("2021-00-00 2021")
        #expect(parsed.year == 2021)
        #expect(parsed.normalized == "2021")
    }

    @Test func fallsBackToBareYearInFreeformText() {
        let parsed = ZoteroDate.parseFieldValue("circa 1998")
        #expect(parsed.year == 1998)
        #expect(parsed.normalized == "1998")
    }

    @Test func parsesUTCTimestamp() {
        let date = ZoteroDate.parseTimestamp("2026-02-13 15:40:12")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        #expect(comps.year == 2026 && comps.month == 2 && comps.day == 13)
        #expect(comps.hour == 15 && comps.minute == 40 && comps.second == 12)
    }
}

@Suite struct ZoteroFieldMappingTests {
    @Test func sourceFallsBackThroughChain() {
        #expect(ZoteroFieldMapping.source(fields: ["publicationTitle": "Nature"], type: .journalArticle) == "Nature")
        #expect(ZoteroFieldMapping.source(fields: ["proceedingsTitle": "CVPR"], type: .conferencePaper) == "CVPR")
        #expect(ZoteroFieldMapping.source(fields: ["conferenceName": "CVPR 2026"], type: .conferencePaper) == "CVPR 2026")
        #expect(ZoteroFieldMapping.source(fields: ["repository": "arXiv"], type: .preprint) == "arXiv")
        #expect(ZoteroFieldMapping.source(fields: ["websiteTitle": "GitHub"], type: .webpage) == "GitHub")
    }

    @Test func sourceFallsBackToPublisherOnlyForBooks() {
        #expect(ZoteroFieldMapping.source(fields: ["publisher": "Springer"], type: .book) == "Springer")
        #expect(ZoteroFieldMapping.source(fields: ["publisher": "Springer"], type: .bookChapter) == nil)
    }

    @Test func doiStripsResolverPrefixAndLowercases() {
        #expect(ZoteroFieldMapping.doi(from: "https://doi.org/10.1145/ABC") == "10.1145/abc")
        #expect(ZoteroFieldMapping.doi(from: "10.1145/ABC") == "10.1145/abc")
        #expect(ZoteroFieldMapping.doi(from: nil) == nil)
    }

    @Test func arxivIdFromArchiveID() {
        let id = ZoteroFieldMapping.arxivID(archiveID: "arXiv:2604.27326", extra: nil, url: nil)
        #expect(id == "2604.27326")
    }

    @Test func arxivIdFromExtraWithCategorySuffix() {
        let id = ZoteroFieldMapping.arxivID(archiveID: nil, extra: "arXiv:2412.08345 [eess]", url: nil)
        #expect(id == "2412.08345")
    }

    @Test func arxivIdFromURLStripsVersion() {
        let id = ZoteroFieldMapping.arxivID(archiveID: nil, extra: nil, url: "https://arxiv.org/abs/2312.04265v2")
        #expect(id == "2312.04265")
    }

    @Test func arxivIdOldFormat() {
        let id = ZoteroFieldMapping.arxivID(archiveID: nil, extra: "hep-th/9901001", url: nil)
        #expect(id == "hep-th/9901001")
    }

    @Test func typeMappingCoversAllListedZoteroTypes() {
        #expect(ZoteroItemTypeMapping.map("journalArticle") == .journalArticle)
        #expect(ZoteroItemTypeMapping.map("conferencePaper") == .conferencePaper)
        #expect(ZoteroItemTypeMapping.map("preprint") == .preprint)
        #expect(ZoteroItemTypeMapping.map("book") == .book)
        #expect(ZoteroItemTypeMapping.map("bookSection") == .bookChapter)
        #expect(ZoteroItemTypeMapping.map("thesis") == .thesis)
        #expect(ZoteroItemTypeMapping.map("report") == .report)
        #expect(ZoteroItemTypeMapping.map("webpage") == .webpage)
        #expect(ZoteroItemTypeMapping.map("dataset") == .dataset)
        #expect(ZoteroItemTypeMapping.map("film") == .other)
    }
}

@Suite struct ZoteroCreatorMappingTests {
    @Test func ordersByOrderIndexAndSplitsFieldMode0() {
        let creators = [
            RawCreator(orderIndex: 1, firstName: "Bao", lastName: "Zhang", fieldMode: 0),
            RawCreator(orderIndex: 0, firstName: "Fan", lastName: "Gao", fieldMode: 0),
        ]
        let authors = ZoteroCreatorMapping.authors(from: creators)
        #expect(authors.map(\.family) == ["Gao", "Zhang"])
        #expect(authors.map(\.given) == ["Fan", "Bao"])
    }

    @Test func fieldMode1UsesLastNameAsFullOrganisationName() {
        let creators = [RawCreator(orderIndex: 0, firstName: "", lastName: "World Health Organization", fieldMode: 1)]
        let authors = ZoteroCreatorMapping.authors(from: creators)
        #expect(authors == [Author(family: "World Health Organization", given: "")])
    }
}

@Suite struct ZoteroCollectionFlatteningTests {
    @Test func flattensThirdLevelIntoSecondLevelAncestor() {
        let collections = [
            RawCollection(id: 1, key: "TOP1", name: "Alpha", parentID: nil),
            RawCollection(id: 2, key: "MID1", name: "Beta", parentID: 1),
            RawCollection(id: 3, key: "DEEP1", name: "Gamma", parentID: 2),
        ]
        let result = ZoteroCollectionFlattening.flatten(collections)
        #expect(result.groups.count == 2)
        #expect(result.groups.contains { $0.key == "TOP1" && $0.parentKey == nil })
        #expect(result.groups.contains { $0.key == "MID1" && $0.parentKey == "TOP1" })
        #expect(!result.groups.contains { $0.key == "DEEP1" })
        // Items directly in the depth-3 collection are attributed to its depth-2 ancestor.
        #expect(result.exportKeyByCollectionID[3] == "MID1")
        #expect(result.exportKeyByCollectionID[2] == "MID1")
        #expect(result.exportKeyByCollectionID[1] == "TOP1")
    }

    @Test func ordersSiblingsByLocalizedName() {
        let collections = [
            RawCollection(id: 1, key: "B", name: "Banana", parentID: nil),
            RawCollection(id: 2, key: "A", name: "Apple", parentID: nil),
        ]
        let result = ZoteroCollectionFlattening.flatten(collections)
        let apple = result.groups.first { $0.key == "A" }!
        let banana = result.groups.first { $0.key == "B" }!
        #expect(apple.position < banana.position)
    }
}

@Suite struct ZoteroAttachmentResolverTests {
    @Test func resolvesStorageAttachmentUnderKeyDirectory() {
        let dataDir = URL(fileURLWithPath: "/tmp/zotero-data")
        let url = ZoteroAttachmentResolver.resolveURL(dataDirectory: dataDir, key: "ABCD1234", path: "storage:paper.pdf", baseAttachmentPath: nil)
        #expect(url.path == "/tmp/zotero-data/storage/ABCD1234/paper.pdf")
    }

    @Test func resolvesAbsoluteLinkedPathDirectly() {
        let url = ZoteroAttachmentResolver.resolveURL(dataDirectory: URL(fileURLWithPath: "/tmp/zotero-data"), key: "X", path: "/Users/me/Papers/linked.pdf", baseAttachmentPath: nil)
        #expect(url.path == "/Users/me/Papers/linked.pdf")
    }

    @Test func resolvesAttachmentsRelativePathAgainstBase() {
        let url = ZoteroAttachmentResolver.resolveURL(dataDirectory: URL(fileURLWithPath: "/tmp/zotero-data"), key: "X", path: "attachments:sub/file.pdf", baseAttachmentPath: "/Users/me/Base")
        #expect(url.path == "/Users/me/Base/sub/file.pdf")
    }

    @Test func nonComparePDFOrdersBeforeCompareRegardlessOfDate() {
        let earlierCompare = PreparedFile(sourceURL: URL(fileURLWithPath: "/a.compare.pdf"), originalName: "a.compare.pdf", dateAdded: Date(timeIntervalSince1970: 0))
        let laterOriginal = PreparedFile(sourceURL: URL(fileURLWithPath: "/a.pdf"), originalName: "a.pdf", dateAdded: Date(timeIntervalSince1970: 1000))
        let ordered = ZoteroAttachmentResolver.order([earlierCompare, laterOriginal])
        #expect(ordered.first?.originalName == "a.pdf")
    }

    @Test func fallsBackToEarliestDateAddedWhenNoCompareVariant() {
        let later = PreparedFile(sourceURL: URL(fileURLWithPath: "/b.pdf"), originalName: "b.pdf", dateAdded: Date(timeIntervalSince1970: 1000))
        let earlier = PreparedFile(sourceURL: URL(fileURLWithPath: "/a.pdf"), originalName: "a.pdf", dateAdded: Date(timeIntervalSince1970: 0))
        let ordered = ZoteroAttachmentResolver.order([later, earlier])
        #expect(ordered.first?.originalName == "a.pdf")
    }

    @Test func htmlSnapshotDetectionUsesContentTypeFirst() {
        #expect(ZoteroAttachmentResolver.isHTMLSnapshot(contentType: "text/html", path: "storage:page.pdf"))
        #expect(!ZoteroAttachmentResolver.isHTMLSnapshot(contentType: "application/pdf", path: "storage:page.html"))
    }

    @Test func htmlSnapshotDetectionFallsBackToExtensionWhenContentTypeMissing() {
        #expect(ZoteroAttachmentResolver.isHTMLSnapshot(contentType: nil, path: "storage:page.html"))
        #expect(ZoteroAttachmentResolver.isHTMLSnapshot(contentType: "", path: "storage:page.htm"))
        #expect(!ZoteroAttachmentResolver.isHTMLSnapshot(contentType: nil, path: "storage:paper.pdf"))
        #expect(!ZoteroAttachmentResolver.isHTMLSnapshot(contentType: nil, path: nil))
    }
}
