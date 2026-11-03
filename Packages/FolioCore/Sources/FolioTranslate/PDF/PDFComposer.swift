import CoreGraphics
import Foundation

/// Builds a new PDF out of pages of an existing one: each output page draws form XObjects made from source pages
/// (edited or not) and from other documents' pages, plus its own content. Links, named destinations and the
/// outline of the source are carried over, pointing at the output pages.
final class PDFComposer {
    let source: CGPDFDocument
    let writer = PDFWriter()
    let copier: PDFCopier
    private let pagesNode: Int
    private var kids: [Int] = []
    /// Output page objects reserved in advance, so links can point at pages not written yet.
    private var reserved: [Int: Int] = [:]
    /// Copiers for other documents (overlays), by document.
    private var foreignCopiers: [ObjectIdentifier: (CGPDFDocument, PDFCopier)] = [:]
    /// Unedited page forms, shared by every page that shows the original.
    private var plainForms: [Int: Int] = [:]

    init(source: CGPDFDocument) {
        self.source = source
        copier = PDFCopier(writer: writer)
        pagesNode = writer.reserve()
    }

    struct PageGeometry {
        var mediaBox: CGRect
        var cropBox: CGRect
        var rotation: Int
    }

    func geometry(ofSourcePage number: Int) -> PageGeometry? {
        guard let page = source.page(at: number) else { return nil }
        let media = page.getBoxRect(.mediaBox)
        var crop = page.getBoxRect(.cropBox).intersection(media)
        if crop.isNull || crop.width < 1 { crop = media }
        return PageGeometry(mediaBox: media, cropBox: crop, rotation: Int(page.rotationAngle))
    }

    /// Reserves the output page that links to source page `number` (1-based) will point at.
    func reserveOutputPage(forSourcePage number: Int) -> Int {
        if let existing = reserved[number] { return existing }
        let object = writer.reserve()
        reserved[number] = object
        if let dict = source.page(at: number)?.dictionary { copier.pageMap[PDFCopier.key(dict)] = object }
        return object
    }

    /// A form XObject showing source page `number` (1-based), rewritten with `edits` when there are any.
    func pageForm(_ number: Int, interpreter: ContentInterpreter? = nil, edits: [OpLocation: EditAction] = [:],
                  namePrefix: String = "FolioE") -> Int? {
        if edits.isEmpty, let cached = plainForms[number] { return cached }
        guard let page = source.page(at: number), let dict = page.dictionary else { return nil }
        let media = page.getBoxRect(.mediaBox)
        var content: Data
        var resources: [String: PDFValue]
        if edits.isEmpty || interpreter == nil {
            content = PDFDictionary.contents(of: dict)
            resources = PDFDictionary.resources(of: dict).map { copier.entries(of: $0) } ?? [:]
        } else {
            let editor = ContentEditor(streams: interpreter!.streams, edits: edits, copier: copier, namePrefix: namePrefix)
            (content, resources) = editor.pageContent()
        }
        var form: [String: PDFValue] = [
            "Type": .name("XObject"), "Subtype": .name("Form"), "BBox": .rect(media), "Resources": .dict(resources),
        ]
        if let group = PDFDictionary.object(dict, "Group") { form["Group"] = copier.copy(group) }
        // Some content streams leave the graphics state unbalanced; keep that inside the form.
        content.insert(contentsOf: Array("q\n".utf8), at: 0)
        content.append(contentsOf: Array("\nQ\n".utf8))
        let object = writer.addStream(dict: form, data: content)
        if edits.isEmpty { plainForms[number] = object }
        return object
    }

    /// A form XObject showing page `number` of another document (for example text drawn by Core Graphics).
    func foreignPageForm(_ document: CGPDFDocument, page number: Int) -> Int? {
        let key = ObjectIdentifier(document)
        let foreign = foreignCopiers[key]?.1 ?? PDFCopier(writer: writer)
        foreignCopiers[key] = (document, foreign)
        guard let page = document.page(at: number), let dict = page.dictionary else { return nil }
        let media = page.getBoxRect(.mediaBox)
        var content = PDFDictionary.contents(of: dict)
        content.insert(contentsOf: Array("q\n".utf8), at: 0)
        content.append(contentsOf: Array("\nQ\n".utf8))
        let resources = PDFDictionary.resources(of: dict).map { foreign.entries(of: $0) } ?? [:]
        return writer.addStream(dict: [
            "Type": .name("XObject"), "Subtype": .name("Form"), "BBox": .rect(media), "Resources": .dict(resources),
        ], data: content)
    }

    /// Link annotations of source page `number`, moved by `offset` (for pages placed beside another).
    func links(ofSourcePage number: Int, offset: CGPoint = .zero) -> [PDFValue] {
        guard let dict = source.page(at: number)?.dictionary, let annots = PDFDictionary.array(dict, "Annots") else { return [] }
        var result: [PDFValue] = []
        for index in 0..<CGPDFArrayGetCount(annots) {
            var annot: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(annots, index, &annot), let annot,
                  PDFDictionary.name(annot, "Subtype") == "Link" else { continue }
            var entries = copier.entries(of: annot, skipping: ["P", "Parent", "StructParent", "Popup"])
            if offset != .zero {
                if let rect = PDFDictionary.rect(annot, "Rect") { entries["Rect"] = .rect(rect.offsetBy(dx: offset.x, dy: offset.y)) }
                if let quads = PDFDictionary.array(annot, "QuadPoints") {
                    let moved = PDFDictionary.numbers(quads).enumerated().map { i, v in v + (i % 2 == 0 ? offset.x : offset.y) }
                    entries["QuadPoints"] = .array(moved.map { .real($0) })
                }
            }
            result.append(.ref(writer.add(.dict(entries))))
        }
        return result
    }

    /// Adds a page drawing `content` with the named form XObjects. `object` is a number from
    /// `reserveOutputPage`, or nil for a new one.
    @discardableResult
    func addPage(object: Int? = nil, mediaBox: CGRect, cropBox: CGRect? = nil, rotation: Int = 0, content: Data,
                 xobjects: [String: Int], annotations: [PDFValue] = []) -> Int {
        let page = object ?? writer.reserve()
        let contents = writer.addStream(dict: [:], data: content)
        var dict: [String: PDFValue] = [
            "Type": .name("Page"), "Parent": .ref(pagesNode), "MediaBox": .rect(mediaBox), "Contents": .ref(contents),
            "Resources": .dict(["XObject": .dict(xobjects.mapValues { .ref($0) })]),
        ]
        if let cropBox, cropBox != mediaBox { dict["CropBox"] = .rect(cropBox) }
        if rotation % 360 != 0 { dict["Rotate"] = .int(rotation) }
        if !annotations.isEmpty { dict["Annots"] = .array(annotations) }
        writer.set(page, .dict(dict))
        kids.append(page)
        return page
    }

    /// The finished file: page tree, catalog (with the source's outline and named destinations) and info.
    func finish(title: String? = nil) -> Data {
        writer.set(pagesNode, .dict(["Type": .name("Pages"), "Kids": .array(kids.map { .ref($0) }), "Count": .int(kids.count)]))
        var catalog: [String: PDFValue] = ["Type": .name("Catalog"), "Pages": .ref(pagesNode)]
        if let root = source.catalog {
            if let outlines = PDFDictionary.dict(root, "Outlines") { catalog["Outlines"] = copier.copy(dictionary: outlines) }
            if let dests = PDFDictionary.dict(root, "Dests") { catalog["Dests"] = copier.copy(dictionary: dests) }
            if let names = PDFDictionary.dict(root, "Names"), let dests = PDFDictionary.dict(names, "Dests") {
                catalog["Names"] = .dict(["Dests": copier.copy(dictionary: dests)])
            }
            if let oc = PDFDictionary.object(root, "OCProperties") { catalog["OCProperties"] = copier.copy(oc) }
            if let mode = PDFDictionary.name(root, "PageMode"), mode == "UseOutlines" { catalog["PageMode"] = .name(mode) }
        }
        let root = writer.add(.dict(catalog))
        var info: [String: PDFValue] = ["Producer": .string(Self.pdfText("Folio"))]
        if let title { info["Title"] = .string(Self.pdfText(title)) }
        let infoObject = writer.add(.dict(info))
        return writer.finish(root: root, info: infoObject)
    }

    /// A PDF text string: UTF-16BE with a byte order mark.
    static func pdfText(_ text: String) -> Data {
        var data = Data([0xFE, 0xFF])
        for unit in text.utf16 { data.append(UInt8(unit >> 8)); data.append(UInt8(unit & 0xFF)) }
        return data
    }
}
