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
        #expect(snapshot.items[itemId]?.title == "阅读计划", "a name given stays")
        #expect(snapshot.files[fileId]?.size == Int64(Data("# 第一周\n\n- [ ] 读 **SAM** 论文\n".utf8).count))
        #expect(try library.fulltextItemIds(matching: "SAM").contains(itemId))
    }

    @Test func unnamedDocumentsAreToldApartAndNamedByTheirHeading() throws {
        let library = try Library.temporary()
        let a = try library.createMarkdownDocument(title: "未命名文档"), b = try library.createMarkdownDocument(title: "未命名文档")
        func title(_ id: String) throws -> String? { try library.snapshot().items[id]?.title }
        func file(_ id: String) throws -> String? { try library.snapshot().files[id]?.fileName }
        #expect(try title(a.itemId) == "未命名文档" && title(b.itemId) == "未命名文档 2")
        // Nobody named it: it is called after its heading, and goes on being so.
        try library.writeText("# 第一周\n", toFile: b.fileId)
        #expect(try title(b.itemId) == "第一周" && file(b.fileId) == "第一周.md")
        #expect(try library.text(ofFile: b.fileId) == "# 第一周\n")
        try library.writeText("# 第二周\n", toFile: b.fileId)
        #expect(try title(b.itemId) == "第二周" && file(b.fileId) == "第二周.md")
        // Named by hand: the heading no longer matters.
        try library.renameMarkdownFile(b.fileId, to: "周报")
        try library.writeText("# 第三周\n", toFile: b.fileId)
        #expect(try title(b.itemId) == "周报" && file(b.fileId) == "周报.md")
    }

    @Test func aDocumentIsCalledTheSameWhereverItsNameShows() throws {
        let library = try Library.temporary()
        let paper = try library.importItem("Segment Anything")
        // A paper's attachment has the plain file name already; the new document is the first of its kind all the same.
        let attached = try library.createMarkdownAttachment(title: "未命名文档", toItem: paper)
        let document = try library.createMarkdownDocument(title: "未命名文档")
        var snapshot = try library.snapshot()
        let file = try #require(snapshot.files[document.fileId])
        #expect(file.fileName == "未命名文档 2.md" && snapshot.items[document.itemId]?.title == "未命名文档")
        #expect(snapshot.documentName(file) == "未命名文档")
        #expect(snapshot.documentName(try #require(snapshot.files[attached])) == "未命名文档")
        // Attachments of one paper are told apart, those of another start over.
        let second = try library.createMarkdownAttachment(title: "未命名文档", toItem: paper)
        let other = try library.createMarkdownAttachment(title: "未命名文档", toItem: try library.importItem("SAM 2"))
        snapshot = try library.snapshot()
        #expect(snapshot.documentName(try #require(snapshot.files[second])) == "未命名文档 2")
        #expect(snapshot.documentName(try #require(snapshot.files[other])) == "未命名文档")
        try library.renameMarkdownFile(second, to: "想法")
        #expect(snapshot.documentName(try #require(try library.snapshot().files[second])) == "想法")
        // A number free again is used again.
        let third = try library.createMarkdownDocument(title: "未命名文档")
        try library.trashItems([third.itemId])
        let fourth = try library.createMarkdownDocument(title: "未命名文档")
        #expect(try library.snapshot().items[fourth.itemId]?.title == "未命名文档 2")
    }

    @Test func unnamedDocumentsAreNamedByTheirFirstLine() throws {
        let library = try Library.temporary()
        let a = try library.createMarkdownDocument(title: "未命名文档")
        func title() throws -> String? { try library.snapshot().items[a.itemId]?.title }
        func file() throws -> String? { try library.snapshot().files[a.fileId]?.fileName }
        // While the line is being written the file keeps its name.
        try library.writeText("今天读", toFile: a.fileId)
        #expect(try title() == "今天读" && file() == "未命名文档.md")
        try library.writeText("今天读了三篇\n", toFile: a.fileId)
        #expect(try title() == "今天读了三篇" && file() == "今天读了三篇.md")
        // A heading says better what it is.
        try library.writeText("今天读了三篇\n\n# 周报\n", toFile: a.fileId)
        #expect(try title() == "周报" && file() == "周报.md")
        try library.renameMarkdownFile(a.fileId, to: "存档")
        try library.writeText("别的\n", toFile: a.fileId)
        #expect(try title() == "存档")
        #expect(Library.name(from: "---\ntitle: x\n---\n\n- [ ] 读 **SAM** 的[论文](https://a.b)\n")?.name == "读 SAM 的论文")
        #expect(Library.name(from: "```swift\nlet a = 1\n```\n> 引用\n")?.name == "引用")
        #expect(Library.name(from: "\n***\n  \n") == nil)
        #expect(Library.name(from: String(repeating: "长", count: 80) + "\n")?.name.count == 40)
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
