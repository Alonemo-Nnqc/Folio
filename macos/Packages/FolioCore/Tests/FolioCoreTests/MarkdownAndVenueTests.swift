import Foundation
import Testing
@testable import FolioCore

@Suite struct MarkdownDocumentTests {
    @Test func standaloneDocumentIsCreatedEditedAndSearched() throws {
        let library = try Library.temporary()
        let (itemId, fileId) = try library.createMarkdownDocument(title: "阅读计划")
        let first = try library.createMarkdownDocument(title: "阅读计划")
        #expect(first.itemId != itemId, "two documents with the same text are two documents")
        var snapshot = try library.snapshot()
        let file = try #require(snapshot.files[fileId])
        #expect(file.isMarkdown)
        #expect(snapshot.items[itemId]?.kind == .standalone)
        #expect(snapshot.items[itemId]?.defaultFileId == fileId)
        #expect(try library.text(ofFile: fileId) == "", "a new document is a blank file")
        #expect(snapshot.items[itemId]?.title == "阅读计划")

        try library.writeText("# 第一周\n\n- [ ] 读 **SAM** 论文\n", toFile: fileId)
        #expect(try library.text(ofFile: fileId).contains("SAM"))
        snapshot = try library.snapshot()
        #expect(snapshot.items[itemId]?.title == "第一周", "the title follows the first heading")
        #expect(snapshot.files[fileId]?.size == Int64(Data("# 第一周\n\n- [ ] 读 **SAM** 论文\n".utf8).count))
        #expect(try library.fulltextItemIds(matching: "SAM").contains(itemId))
    }

    @Test func attachmentKeepsThePapersTitle() throws {
        let library = try Library.temporary()
        let paper = try library.importItem("Segment Anything")
        let fileId = try library.createMarkdownAttachment(title: "精读笔记", toItem: paper)
        try library.writeText("# 精读\n内容", toFile: fileId)
        let snapshot = try library.snapshot()
        #expect(snapshot.files[fileId]?.itemId == paper)
        #expect(snapshot.items[paper]?.title == "Segment Anything")
        #expect(Library.firstHeading(of: "text\n## Two\n") == "Two")
    }
}

@Suite struct VenueCatalogTests {
    @Test func wellKnownVenuesGetTheirShortNames() {
        func short(_ source: String?, doi: String? = nil) -> String? { VenueCatalog.venue(source: source, doi: doi)?.abbreviation }
        #expect(short("2023 IEEE/CVF International Conference on Computer Vision (ICCV)") == "ICCV")
        #expect(short("Proceedings of the IEEE/CVF Conference on Computer Vision and Pattern Recognition") == "CVPR")
        #expect(short("2024 IEEE/CVF Conference on Computer Vision and Pattern Recognition Workshops (CVPRW)") == "CVPRW")
        #expect(short("Advances in Neural Information Processing Systems") == "NeurIPS")
        #expect(short("IEEE Transactions on Pattern Analysis and Machine Intelligence") == "TPAMI")
        #expect(short("European Conference on Computer Vision") == "ECCV")
        #expect(short("Medical Image Analysis") == "MedIA")
        #expect(short("arXiv") == "arXiv")
        #expect(short("Nature") == "Nature")
        #expect(short(nil, doi: "10.1109/CVPR52729.2023.00987") == "CVPR")
        #expect(short("Proceedings of the 31st Conference on Brain Informatics (BI 2026)") == "BI")
        #expect(short("Journal of Applied Remote Sensing and Earth Observation Science") == "JARSEOS")
        #expect(short("Array") == "Array")
        #expect(VenueCatalog.venue(source: "CVPR", doi: nil)?.ccf == "A")
        #expect(VenueCatalog.venue(source: "Pattern Recognition Letters", doi: nil)?.abbreviation == "PRL")
    }
}
