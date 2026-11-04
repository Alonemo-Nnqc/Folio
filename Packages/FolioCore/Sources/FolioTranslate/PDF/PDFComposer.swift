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

    init(source: CGPDFDocument, streamCache: StreamDataCache? = nil) {
        self.source = source
        copier = PDFCopier(writer: writer)
        copier.streamCache = streamCache
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

    /// Link annotations of source page `number`, moved by `offset` (for pages placed beside another). `placement`
    /// says where links went whose words moved: one annotation per place, none when their words are gone.
    func links(ofSourcePage number: Int, offset: CGPoint = .zero, placement: [Int: [CGRect]] = [:]) -> [PDFValue] {
        guard let dict = source.page(at: number)?.dictionary else { return [] }
        var result: [PDFValue] = []
        for (index, annot) in PageLinks.annotations(of: dict).enumerated() where reachable(annot) {
            var entries = copier.entries(of: annot, skipping: ["P", "Parent", "StructParent", "Popup"])
            if let places = placement[index] {
                entries["QuadPoints"] = nil
                for rect in places {
                    entries["Rect"] = .rect(rect.offsetBy(dx: offset.x, dy: offset.y))
                    result.append(.ref(writer.add(.dict(entries))))
                }
                continue
            }
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

    /// Whether the link leads somewhere in the output: when only some pages are written, a link to a page left out
    /// goes nowhere.
    private func reachable(_ annot: CGPDFDictionaryRef) -> Bool {
        guard reserved.count < source.numberOfPages else { return true }
        var target = PDFDictionary.object(annot, "Dest")
        if target == nil, let action = PDFDictionary.dict(annot, "A") {
            guard PDFDictionary.name(action, "S") == "GoTo" else { return true }
            target = PDFDictionary.object(action, "D")
        }
        guard let target, let page = PDFDestinations.page(of: target, catalog: source.catalog) else { return true }
        return copier.pageMap[PDFCopier.key(page)] != nil
    }

    /// Adds a page drawing `content` with the named form XObjects. `object` is a number from
    /// `reserveOutputPage`, or nil for a new one.
    @discardableResult
    func addPage(object: Int? = nil, mediaBox: CGRect, cropBox: CGRect? = nil, rotation: Int = 0, content: Data,
                 xobjects: [String: Int], fonts: [String: PDFValue] = [:], annotations: [PDFValue] = []) -> Int {
        let page = object ?? writer.reserve()
        let contents = writer.addStream(dict: [:], data: content)
        var resources: [String: PDFValue] = ["XObject": .dict(xobjects.mapValues { .ref($0) })]
        if !fonts.isEmpty { resources["Font"] = .dict(fonts) }
        var dict: [String: PDFValue] = [
            "Type": .name("Page"), "Parent": .ref(pagesNode), "MediaBox": .rect(mediaBox), "Contents": .ref(contents),
            "Resources": .dict(resources),
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

/// Finds the page a destination is on.
enum PDFDestinations {
    /// The page dictionary of a destination: an array, or a name or string looked up in the catalog.
    static func page(of destination: CGPDFObjectRef, catalog: CGPDFDictionaryRef?) -> CGPDFDictionaryRef? {
        switch CGPDFObjectGetType(destination) {
        case .array:
            var array: CGPDFArrayRef?
            guard CGPDFObjectGetValue(destination, .array, &array), let array else { return nil }
            return page(ofArray: array)
        case .dictionary:
            var dict: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(destination, .dictionary, &dict), let dict, let array = PDFDictionary.array(dict, "D") else { return nil }
            return page(ofArray: array)
        case .name:
            var name: UnsafePointer<CChar>?
            guard CGPDFObjectGetValue(destination, .name, &name), let name, let catalog else { return nil }
            return named(Data(String(cString: name).utf8), catalog: catalog)
        case .string:
            var string: CGPDFStringRef?
            guard CGPDFObjectGetValue(destination, .string, &string), let string, let catalog else { return nil }
            return named(PDFCopier.data(of: string), catalog: catalog)
        default:
            return nil
        }
    }

    private static func page(ofArray array: CGPDFArrayRef) -> CGPDFDictionaryRef? {
        var page: CGPDFDictionaryRef?
        return CGPDFArrayGetDictionary(array, 0, &page) ? page : nil
    }

    private static func named(_ name: Data, catalog: CGPDFDictionaryRef) -> CGPDFDictionaryRef? {
        if let dests = PDFDictionary.dict(catalog, "Dests"), let text = String(data: name, encoding: .utf8),
           let object = PDFDictionary.object(dests, text), let found = page(of: object, catalog: nil) { return found }
        guard let names = PDFDictionary.dict(catalog, "Names"), let tree = PDFDictionary.dict(names, "Dests") else { return nil }
        return lookup(name, in: tree, depth: 0)
    }

    /// Looks `name` up in a name tree.
    private static func lookup(_ name: Data, in node: CGPDFDictionaryRef, depth: Int) -> CGPDFDictionaryRef? {
        guard depth < 32 else { return nil }
        if let names = PDFDictionary.array(node, "Names") {
            for k in stride(from: 0, to: CGPDFArrayGetCount(names) - 1, by: 2) {
                var key: CGPDFStringRef?, value: CGPDFObjectRef?
                guard CGPDFArrayGetString(names, k, &key), let key, PDFCopier.data(of: key) == name,
                      CGPDFArrayGetObject(names, k + 1, &value), let value else { continue }
                return page(of: value, catalog: nil)
            }
        }
        if let kids = PDFDictionary.array(node, "Kids") {
            for k in 0..<CGPDFArrayGetCount(kids) {
                var kid: CGPDFDictionaryRef?
                if CGPDFArrayGetDictionary(kids, k, &kid), let kid, let found = lookup(name, in: kid, depth: depth + 1) { return found }
            }
        }
        return nil
    }
}
