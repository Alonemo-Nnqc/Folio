import CoreGraphics
import CoreText
import Foundation
import PDFKit

/// A block of text on a page that the PDF editor offers (EDIT-01): a paragraph, heading, caption, table cell …
/// Geometry is in the page's user space (PDF points, origin at the bottom left), as PDFKit's page space.
public struct PDFTextBlock: Sendable, Hashable, Identifiable {
    /// A formula, citation or small picture inside the text: kept as drawn. It stands in `text` as `{vN}` (1-based)
    /// and goes wherever the new text puts that placeholder.
    public struct Inline: Sendable, Hashable {
        /// Where it is drawn on the page.
        public var rect: CGRect
        public var baseline: Double
        /// What it reads as.
        public var text: String
    }

    public struct Color: Sendable, Hashable {
        public var red: Double, green: Double, blue: Double
    }

    public enum Alignment: String, Sendable { case left, center, right, justified }

    /// 0-based page index.
    public var page: Int
    /// The block's place in the page's layout.
    public var index: Int
    public var id: String { "\(page)-\(index)" }
    public var rect: CGRect
    /// The rectangle of each line.
    public var lines: [CGRect]
    /// The text, lines joined (hyphenated words put together), with `{vN}` for each inline.
    public var text: String
    public var inlines: [Inline]
    /// Em size of most of its characters.
    public var fontSize: Double
    /// Baseline to baseline.
    public var lineHeight: Double
    public var firstBaseline: Double
    public var color: Color
    public var isBold: Bool
    public var isItalic: Bool
    public var isSerif: Bool
    public var alignment: Alignment
    public var firstLineIndent: Double
    /// Whether it can be replaced; when not, `reason` says why (formulas, Type 3 fonts …).
    public var isEditable: Bool
    public var reason: String?
}

public enum PDFTextEditError: LocalizedError, Equatable {
    case unreadable
    case encrypted
    /// The block is not where it was (the file changed).
    case blockChanged
    case notEditable(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable: String(localized: "无法读取这个 PDF", bundle: .module)
        case .encrypted: String(localized: "这个 PDF 已加密，无法编辑文字", bundle: .module)
        case .blockChanged: String(localized: "这段文字已经变化，请重新选择", bundle: .module)
        case .notEditable(let reason): reason
        }
    }
}

/// Edits the existing text of a PDF (EDIT-01), block by block, on the engine of the translator: the layout analysis
/// finds the blocks; replacing one takes its glyphs out of the content streams one by one (other text and graphics on
/// the page stay exactly where they were), sets the new text with Core Text in the block's space — its size, colour
/// and line spacing, smaller only when it does not fit — with fonts embedded as subsets, so it can be selected and
/// found, and writes the whole file again. Formulas and citations inside the text are kept as drawn and move with the
/// placeholders standing for them.
///
/// One instance reads one version of a file; after a replacement, open the new data with a new instance.
public final class PDFTextEditor: @unchecked Sendable {
    private let data: Data
    private let cg: CGPDFDocument
    private let document: PDFDocument
    private let lock = NSLock()
    private var pages: [Int: (layout: PageLayout, interpreter: ContentInterpreter)] = [:]
    private var bodySize: Double?

    public init(data: Data) throws {
        guard let provider = CGDataProvider(data: data as CFData), let cg = CGPDFDocument(provider), let document = PDFDocument(data: data) else {
            throw PDFTextEditError.unreadable
        }
        guard !cg.isEncrypted else { throw PDFTextEditError.encrypted }
        self.data = data
        self.cg = cg
        self.document = document
    }

    public var pageCount: Int { cg.numberOfPages }

    // MARK: Blocks

    /// The text blocks of page `index` (0-based), editable or not, in reading order.
    public func blocks(onPage index: Int) -> [PDFTextBlock] {
        guard let entry = analysed(index) else { return [] }
        return entry.layout.blocks.indices.compactMap { describe(entry.layout, block: $0, interpreter: entry.interpreter, page: index) }
    }

    private func analysed(_ index: Int) -> (layout: PageLayout, interpreter: ContentInterpreter)? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = pages[index] { return cached }
        guard let cgPage = cg.page(at: index + 1), let page = document.page(at: index) else { return nil }
        let interpreter = ContentInterpreter()
        interpreter.run(page: cgPage)
        let chars = PageText.characters(of: page, interpreter: interpreter)
        var analyzer = LayoutAnalyzer()
        analyzer.bodySize = documentBodySize()
        let layout = analyzer.analyzePage(number: index + 1, cgPage: cgPage, interpreter: interpreter, chars: chars)
        pages[index] = (layout, interpreter)
        return (layout, interpreter)
    }

    /// The size most text of the document is set in (headings and captions are told apart from it), from its first pages.
    private func documentBodySize() -> Double {
        if let bodySize { return bodySize }
        var counts: [Double: Int] = [:]
        for number in 1...max(1, min(cg.numberOfPages, 8)) {
            guard let page = cg.page(at: number) else { continue }
            let interpreter = ContentInterpreter()
            interpreter.run(page: page)
            for glyph in interpreter.glyphs where glyph.isVisible && glyph.isHorizontal && glyph.size > 0.5 && glyph.size < 400 {
                counts[(glyph.size * 2).rounded() / 2, default: 0] += 1
            }
        }
        let size = counts.max { $0.value < $1.value }?.key ?? 10
        bodySize = size
        return size
    }

    private func describe(_ layout: PageLayout, block index: Int, interpreter: ContentInterpreter, page: Int) -> PDFTextBlock? {
        let block = layout.blocks[index]
        guard !block.lines.isEmpty else { return nil }
        var parts = Self.parts(of: block)
        // Text set by Core Graphics or Skia may read back as radicals for some ideographs (see `ToUnicodeFix`).
        parts.text = ToUnicodeFix.fixed(parts.text)
        let inlines = parts.formulas.map { formula -> PDFTextBlock.Inline in
            let glyphs = Set(formula.glyphs + formula.continuation.flatMap(\.glyphs))
            let text = block.lines.flatMap(\.chars).filter { !$0.isSpace && !$0.glyphs.isEmpty && glyphs.isSuperset(of: $0.glyphs) }.map(\.text).joined()
            let rect = formula.ink.isNull ? formula.rect : formula.rect.union(formula.ink)
            return PDFTextBlock.Inline(rect: rect, baseline: formula.baseline, text: ToUnicodeFix.fixed(text))
        }
        let reason = Self.problem(with: block, text: parts.text, interpreter: interpreter)
        let alignment: PDFTextBlock.Alignment = switch block.kind {
        case .paragraph, .caption: block.isCentered ? .center : (block.lines.count > 1 ? .justified : .left)
        case .tableCell:
            switch block.cellAlignment {
            case .left?: .left
            case .right?: .right
            default: .center
            }
        default: block.isCentered ? .center : .left
        }
        let color = block.color
        return PDFTextBlock(page: page, index: index, rect: block.rect, lines: block.lines.map(\.rect), text: parts.text, inlines: inlines,
                            fontSize: block.size, lineHeight: block.pitch, firstBaseline: block.lines[0].baseline,
                            color: .init(red: color.r, green: color.g, blue: color.b), isBold: block.font.isBold,
                            isItalic: block.font.isItalic, isSerif: block.font.isSerif || block.font.name.isEmpty, alignment: alignment,
                            firstLineIndent: block.kind == .paragraph ? block.firstLineIndent : 0, isEditable: reason == nil, reason: reason)
    }

    /// The block's text with its formulas as placeholders; a bold heading run into its first line is part of the text
    /// (`lead`), set in bold again when the new text still starts with it.
    static func parts(of block: LayoutBlock) -> (text: String, formulas: [FormulaSpan], lead: String?) {
        let (body, formulas, lead) = SegmentBuilder.text(of: block)
        guard let lead, !lead.text.isEmpty else { return (body, formulas, nil) }
        let shift = lead.formulas.count
        let shifted = Placeholders.replace(in: body) { TextSegment.placeholder($0 + shift) }
        return (lead.text + " " + shifted, lead.formulas + formulas, lead.text)
    }

    /// Why a block cannot be replaced safely, or nil.
    static func problem(with block: LayoutBlock, text: String, interpreter: ContentInterpreter) -> String? {
        switch block.kind {
        case .formula: return String(localized: "公式不能编辑", bundle: .module)
        case .figure: return String(localized: "图中的文字不能编辑", bundle: .module)
        case .rotated: return String(localized: "旋转的文字不能编辑", bundle: .module)
        case .code: return String(localized: "代码和算法不能编辑", bundle: .module)
        default: break
        }
        if block.lines.contains(where: \.isRotated) { return String(localized: "旋转的文字不能编辑", bundle: .module) }
        var type3: [Int: Bool] = [:]
        for index in block.lines.flatMap({ $0.chars.flatMap(\.glyphs) }) where index < interpreter.glyphs.count {
            let glyph = interpreter.glyphs[index]
            if glyph.renderMode >= 4 { return String(localized: "这段文字用作裁剪路径，不能编辑", bundle: .module) }
            guard glyph.font >= 0, glyph.font < interpreter.fonts.count else { continue }
            let isType3 = type3[glyph.font] ?? (PDFDictionary.name(interpreter.fonts[glyph.font].dict, "Subtype") == "Type3")
            type3[glyph.font] = isType3
            if isType3 { return String(localized: "这段文字使用 Type 3 字体，无法安全编辑", bundle: .module) }
        }
        let words = text.replacingOccurrences(of: #"\{v\d+\}"#, with: "", options: .regularExpression)
        if !words.contains(where: { $0.isLetter || $0.isNumber }) { return String(localized: "公式不能编辑", bundle: .module) }
        return nil
    }

    // MARK: Replacing

    /// The file with `block`'s text replaced by `text` (`{vN}` placeholders put the block's inlines back; empty text
    /// takes the block away).
    public func replace(_ block: PDFTextBlock, with text: String) throws -> Data {
        guard let entry = analysed(block.page), entry.layout.blocks.indices.contains(block.index),
              let current = describe(entry.layout, block: block.index, interpreter: entry.interpreter, page: block.page),
              current.text == block.text, current.rect == block.rect else { throw PDFTextEditError.blockChanged }
        if let reason = current.reason { throw PDFTextEditError.notEditable(reason) }
        return render(entry.layout, interpreter: entry.interpreter, block: block.index, text: text)
    }

    private func render(_ layout: PageLayout, interpreter: ContentInterpreter, block index: Int, text raw: String) -> Data {
        let source = layout.blocks[index]
        let parts = Self.parts(of: source)
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if let lead = parts.lead.map(ToUnicodeFix.fixed), text.hasPrefix(lead) {
            text = Typesetter.leadStart + lead + Typesetter.leadEnd + text.dropFirst(lead.count)
        }
        let formulas = parts.formulas
        let isEmpty = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // 1. The new text, set in the block's space on a page of its own.
        let typesetter = Typesetter(language: Self.language(of: raw), keepsText: true)
        var result: Typesetter.Result?
        var fontSize = source.size
        let overlayData = NSMutableData()
        if !isEmpty, let consumer = CGDataConsumer(data: overlayData as CFMutableData) {
            var media = layout.mediaBox
            if let context = CGContext(consumer: consumer, mediaBox: &media, nil) {
                let frame = TranslationRenderer.frame(for: index, in: layout)
                let plan = typesetter.plan(text, block: source, formulas: formulas, frame: frame)
                // The original's line spacing, closer only when the text needs it to fit.
                let set = typesetter.finish(plan, pitch: source.pitch * plan.scale, formulas: formulas)
                context.beginPDFPage(nil)
                typesetter.draw(set, in: context)
                context.endPDFPage()
                context.closePDF()
                result = set
                fontSize = plan.fontSize
            }
        }
        let overlay = result == nil ? nil : CGDataProvider(data: overlayData as CFData).flatMap { CGPDFDocument($0) }

        // 2. The block's glyphs out of the page; everything else stays.
        var kept: Set<Int> = []
        for (k, other) in layout.blocks.enumerated() where k != index {
            for line in other.lines { for c in line.chars { kept.formUnion(c.glyphs) } }
        }
        var removal = PageRemoval(kept: kept)
        removal.add(source)
        let removed = Set(interpreter.glyphs.indices.filter { removal.removes(interpreter.glyphs[$0], index: $0) })
        var edits = TranslationRenderer.glyphEdits(interpreter: interpreter, removing: removed)
        let transplants = result?.transplants ?? []
        let (rules, chips) = TranslationRenderer.graphicEdits(interpreter: interpreter, rects: removal.rects, transplants: transplants, edits: &edits)

        // 3. The page again: its content without the block, the new text, the formulas where the new text put them.
        let rewriter = DocumentRewriter(source: cg)
        let token = Self.token()
        let editor = ContentEditor(streams: interpreter.streams, edits: edits, copier: rewriter.copier, namePrefix: "FolioE\(token)n")
        var (body, resources) = editor.pageContent()
        var content = Data("q\n".utf8)
        content.append(body)
        content.append(contentsOf: Array("\nQ\n".utf8))
        var xobjects: [String: Int] = [:]
        var fonts: [String: PDFValue] = [:]
        if let overlay, let form = rewriter.foreignPageForm(overlay, page: 1) {
            let name = "FolioT\(token)"
            xobjects[name] = form
            content.append(contentsOf: Array("q /\(name) Do Q\n".utf8))
        }
        let claimed = removal.glyphs.union(transplants.flatMap(\.formula.glyphs))
        let orphans = removed.subtracting(claimed).filter { interpreter.glyphs[$0].isVisible }
        let drawn = TranslationRenderer.formulaContent(transplants, orphans: orphans, droppedRules: rules, chips: chips, interpreter: interpreter,
                                                       copier: rewriter.copier, prefix: "Folio\(token)", xobjects: &xobjects, fonts: &fonts)
        content.append(contentsOf: Array(drawn.content.utf8))
        let pageResources = interpreter.streams[[]]?.resources
        merge(&resources, key: "XObject", adding: xobjects.mapValues { .ref($0) }, source: pageResources, copier: rewriter.copier)
        merge(&resources, key: "Font", adding: fonts, source: pageResources, copier: rewriter.copier)

        // 4. Links on the block's words follow them.
        var places: [Int: [CGRect]] = [:]
        for line in source.lines { for c in line.chars { if let link = c.link { places[link] = [] } } }
        if let result {
            for transplant in result.transplants {
                for span in transplant.formula.links {
                    places[span.link, default: []].append(span.rect.applying(transplant.transform).insetBy(dx: -0.5, dy: 0))
                }
            }
            let held = Set(formulas.flatMap(\.allLinks).map(\.link))
            for link in Set(source.lines.flatMap { $0.chars.compactMap(\.link) }).subtracting(held) {
                places[link] = LinkText.places(of: link, in: source, lines: result.lines, fontSize: fontSize)
            }
        }
        rewriter.replace(page: layout.number, with: .init(content: content, resources: resources, linkPlaces: places))
        return rewriter.finish()
    }

    /// `resources[key]` with `extra` entries added (the copied entry may be a reference to the dictionary).
    private func merge(_ resources: inout [String: PDFValue], key: String, adding extra: [String: PDFValue],
                       source: CGPDFDictionaryRef?, copier: PDFCopier) {
        guard !extra.isEmpty else { return }
        var entries: [String: PDFValue] = [:]
        if case .dict(let existing)? = resources[key] {
            entries = existing
        } else if let source, let dict = PDFDictionary.dict(source, key) {
            entries = copier.entries(of: dict)
        }
        entries.merge(extra) { _, new in new }
        resources[key] = .dict(entries)
    }

    /// A short random tag for the names this edit adds to the page's resources, so they never clash with the names of
    /// earlier edits.
    private static func token() -> String {
        let letters = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return String((0..<5).map { _ in letters.randomElement()! })
    }

    /// The language to set `text` in: its script decides the fonts and how lines are justified.
    static func language(of text: String) -> String {
        var han = 0, kana = 0, hangul = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF: kana += 1
            case 0xAC00...0xD7AF, 0x1100...0x11FF: hangul += 1
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF: han += 1
            default: break
            }
        }
        if kana > 0 { return "ja" }
        if hangul > han { return "ko" }
        if han > 0 { return "zh-Hans" }
        return "en"
    }
}
