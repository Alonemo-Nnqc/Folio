import CoreGraphics
import Foundation

/// Writes a PDF again with the content of some pages replaced (EDIT-01): everything else — the other pages, every
/// annotation, the outline, named destinations, forms, metadata, page labels — is copied object by object, with page
/// references pointing at the new pages.
///
/// The pages are reserved first, so content built for a replacement (rewritten forms, fonts) can be copied with the
/// same `copier` and shares its objects with the rest of the file.
final class DocumentRewriter {
    let source: CGPDFDocument
    let writer = PDFWriter()
    let copier: PDFCopier
    private let pagesNode: Int
    /// Output page objects, in page order.
    private var pageObjects: [Int] = []
    private var replacements: [Int: Replacement] = [:]
    /// Copiers for other documents (text set by Core Text), by document.
    private var foreignCopiers: [ObjectIdentifier: (CGPDFDocument, PDFCopier)] = [:]

    struct Replacement {
        var content: Data
        var resources: [String: PDFValue]
        /// Where the page's links (by `PageLinks` index) went: one annotation per place, none when their words are gone.
        var linkPlaces: [Int: [CGRect]] = [:]
    }

    init(source: CGPDFDocument) {
        self.source = source
        copier = PDFCopier(writer: writer)
        pagesNode = writer.reserve()
        let count = source.numberOfPages
        guard count > 0 else { return }
        for number in 1...count {
            let object = writer.reserve()
            pageObjects.append(object)
            if let dict = source.page(at: number)?.dictionary { copier.pageMap[PDFCopier.key(dict)] = object }
        }
    }

    /// Page `number` (1-based) draws `content` with `resources` instead of what it drew.
    func replace(page number: Int, with replacement: Replacement) {
        replacements[number] = replacement
    }

    /// A form XObject showing page `number` of another document (text drawn by Core Graphics), its fonts' ToUnicode
    /// maps leading to ideographs rather than radicals.
    func foreignPageForm(_ document: CGPDFDocument, page number: Int) -> Int? {
        let key = ObjectIdentifier(document)
        let foreign = foreignCopiers[key]?.1 ?? PDFCopier(writer: writer)
        foreign.transform = ToUnicodeFix.apply
        foreignCopiers[key] = (document, foreign)
        guard let page = document.page(at: number), let dict = page.dictionary else { return nil }
        var content = PDFDictionary.contents(of: dict)
        content.insert(contentsOf: Array("q\n".utf8), at: 0)
        content.append(contentsOf: Array("\nQ\n".utf8))
        let resources = PDFDictionary.resources(of: dict).map { foreign.entries(of: $0) } ?? [:]
        return writer.addStream(dict: [
            "Type": .name("XObject"), "Subtype": .name("Form"), "BBox": .rect(page.getBoxRect(.mediaBox)), "Resources": .dict(resources),
        ], data: content)
    }

    /// The complete file.
    func finish() -> Data {
        for (k, object) in pageObjects.enumerated() { writePage(k + 1, as: object) }
        writer.set(pagesNode, .dict(["Type": .name("Pages"), "Kids": .array(pageObjects.map { .ref($0) }), "Count": .int(pageObjects.count)]))
        var catalog = source.catalog.map { copier.entries(of: $0, skipping: ["Pages"]) } ?? [:]
        catalog["Type"] = .name("Catalog")
        catalog["Pages"] = .ref(pagesNode)
        let root = writer.add(.dict(catalog))
        var info: Int?
        if let dict = source.info, case .ref(let number) = copier.copy(dictionary: dict) { info = number }
        var id: [Data]?
        if let array = source.fileIdentifier, CGPDFArrayGetCount(array) == 2 {
            id = (0..<2).compactMap { index in
                var string: CGPDFStringRef?
                return CGPDFArrayGetString(array, index, &string) ? string.map(PDFCopier.data(of:)) : nil
            }
        }
        return writer.finish(root: root, info: info, id: id)
    }

    private func writePage(_ number: Int, as object: Int) {
        guard let page = source.page(at: number), let dict = page.dictionary else {
            writer.set(object, .dict(["Type": .name("Page"), "Parent": .ref(pagesNode), "MediaBox": .rect(CGRect(x: 0, y: 0, width: 612, height: 792))]))
            return
        }
        // What a page inherits from the page tree is written on the page itself: the tree is new.
        var entries = copier.entries(of: dict, skipping: ["Type", "Parent", "Contents", "Resources", "Annots", "MediaBox", "CropBox", "Rotate"])
        entries["Type"] = .name("Page")
        entries["Parent"] = .ref(pagesNode)
        for key in ["MediaBox", "CropBox", "Rotate"] {
            if let value = PDFDictionary.inherited(dict, key) { entries[key] = copier.copy(value) }
        }
        if entries["MediaBox"] == nil { entries["MediaBox"] = .rect(page.getBoxRect(.mediaBox)) }
        if let replacement = replacements[number] {
            entries["Contents"] = .ref(writer.addStream(dict: [:], data: replacement.content))
            entries["Resources"] = .dict(replacement.resources)
        } else {
            if let contents = PDFDictionary.object(dict, "Contents") { entries["Contents"] = copier.copy(contents) }
            if let resources = PDFDictionary.inherited(dict, "Resources") { entries["Resources"] = copier.copy(resources) }
        }
        let annotations = annotations(of: dict, linkPlaces: replacements[number]?.linkPlaces ?? [:])
        if !annotations.isEmpty { entries["Annots"] = .array(annotations) }
        writer.set(object, .dict(entries))
    }

    /// The page's annotations, copied; links whose words moved go where `linkPlaces` says.
    private func annotations(of page: CGPDFDictionaryRef, linkPlaces: [Int: [CGRect]]) -> [PDFValue] {
        guard let annots = PDFDictionary.array(page, "Annots") else { return [] }
        var result: [PDFValue] = []
        var link = 0
        for index in 0..<CGPDFArrayGetCount(annots) {
            var annot: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(annots, index, &annot), let annot else { continue }
            if PDFDictionary.name(annot, "Subtype") == "Link" {
                defer { link += 1 }
                if let places = linkPlaces[link] {
                    var entries = copier.entries(of: annot, skipping: ["QuadPoints"])
                    for rect in places {
                        entries["Rect"] = .rect(rect)
                        result.append(.ref(writer.add(.dict(entries))))
                    }
                    continue
                }
            }
            result.append(copier.copy(dictionary: annot))
        }
        return result
    }
}
