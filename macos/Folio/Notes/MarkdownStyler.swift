import AppKit

// MARK: - Attributes

extension NSAttributedString.Key {
    /// Markdown syntax (`**`, `# `, `[`, `](url)` …) that is not drawn.
    static let mdHidden = NSAttributedString.Key("FolioMarkdownHidden")
    /// Syntax characters, drawn dimmed while the caret is at them.
    static let mdMarker = NSAttributedString.Key("FolioMarkdownMarker")
    /// On a line's first character: what is drawn before its text (a `MarkdownDecoration`).
    /// A line's height and baseline (a `MarkdownMetrics`).
    static let mdMetrics = NSAttributedString.Key("FolioMarkdownMetrics")
    static let mdDecoration = NSAttributedString.Key("FolioMarkdownDecoration")
    /// The lines of a fenced code block.
    static let mdCodeBlock = NSAttributedString.Key("FolioMarkdownCodeBlock")
    /// A quoted line (value: how deep).
    static let mdQuote = NSAttributedString.Key("FolioMarkdownQuote")
    /// A thematic break (`---`) drawn as a line.
    static let mdRule = NSAttributedString.Key("FolioMarkdownRule")
    /// The lines of a table (its view shows that they are selected).
    static let mdTable = NSAttributedString.Key("FolioMarkdownTable")
    /// Code or a highlight in a line: its background has round corners.
    static let mdPill = NSAttributedString.Key("FolioMarkdownPill")
}

/// How tall a line is and where its text sits, whatever is in it: an empty item, Chinese, a heading at the very end of
/// the text all have the room they have with text in them (`MarkdownLayoutManager` lays them out by this).
final class MarkdownMetrics: NSObject {
    let before: CGFloat, ascent: CGFloat, descent: CGFloat, spacing: CGFloat, after: CGFloat

    /// `height`: from this line to the next.
    init(font: NSFont, before: CGFloat = 0, height: CGFloat, after: CGFloat) {
        self.before = before
        ascent = ceil(font.ascender)
        descent = ceil(-font.descender)
        spacing = max(round(height) - ceil(font.ascender) - ceil(-font.descender), 0)
        self.after = after
    }

    var line: CGFloat { ascent + descent }
    /// The room above the text in its line; the rest of `spacing` is below.
    var above: CGFloat { floor(spacing / 2) }
}

/// What stands before a line's text instead of its symbols.
final class MarkdownDecoration: NSObject {
    enum Mark: Equatable { case none, bullet(Int), number(String), task(Bool) }
    let mark: Mark
    /// Where the text begins, in the line.
    let textOffset: Int
    let x: CGFloat
    let font: NSFont
    /// Shown while nothing is written.
    let placeholder: String

    init(mark: Mark, textOffset: Int, x: CGFloat, font: NSFont, placeholder: String) {
        self.mark = mark; self.textOffset = textOffset; self.x = x; self.font = font; self.placeholder = placeholder
    }
}

/// The parts of a document that span lines.
struct MarkdownStructure {
    var codes: [MarkdownCode] = []
    var tables: [(range: NSRange, table: MarkdownTable)] = []
    /// What each table's view takes.
    var tableHeights: [CGFloat] = []

    init() {}
    init(_ string: NSString) {
        codes = MarkdownCode.all(in: string)
        tables = MarkdownTable.all(in: string, outside: codes)
        tableHeights = tables.map { CGFloat($0.table.rows.count) * 32 }
    }

    /// Its blocks in order: what they are and how long.
    var blocks: [(range: NSRange, isTable: Bool)] {
        (codes.map { ($0.range, false) } + tables.map { ($0.range, true) }).sorted { $0.0.location < $1.0.location }
    }

    func code(at location: Int) -> MarkdownCode? {
        codes.first { NSLocationInRange(location, $0.range) || (!$0.isClosed && location == NSMaxRange($0.range)) }
    }
    func table(at location: Int) -> Int? { tables.firstIndex { NSLocationInRange(location, $0.range) } }
}

// MARK: - Styling

/// Gives Markdown source the look of the rendered document without changing a character: the source stays the file's
/// text (copy, undo, search and saving all see Markdown), only how it is drawn changes. The symbols of a line's kind
/// (heading, list, task, quote, fence) are never drawn; those inside a line (`**`, links) while the caret is at them.
struct MarkdownStyler {
    var fontSize: CGFloat = 13
    var preferences = MarkdownPreferences.current

    /// The text's font, in the typeface chosen.
    func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        if preferences.typeface == .mono { return .monospacedSystemFont(ofSize: size, weight: weight) }
        let system = NSFont.systemFont(ofSize: size, weight: weight)
        let design: NSFontDescriptor.SystemDesign = switch preferences.typeface { case .serif: .serif; case .rounded: .rounded; default: .default }
        guard design != .default, let descriptor = system.fontDescriptor.withDesign(design) else { return system }
        return NSFont(descriptor: descriptor, size: size) ?? system
    }

    var bodyFont: NSFont { font(fontSize) }
    var monoFont: NSFont { .monospacedSystemFont(ofSize: max(round(fontSize * preferences.codeScale * 2) / 2, 8), weight: .regular) }
    var paragraphSpacing: CGFloat { round(fontSize * preferences.paragraphSpacing) }
    /// Room for a list's mark.
    var listStep: CGFloat { round(fontSize * 1.65) }
    var quoteStep: CGFloat { round(fontSize * 1.1) }
    static let codeHeaderHeight: CGFloat = 32
    static let codeFooterHeight: CGFloat = 12
    static let codePadding: CGFloat = 14

    func headingFont(_ level: Int) -> NSFont {
        let scale: [CGFloat] = [1.7, 1.42, 1.2, 1.08, 1, 1]
        return font(max(round(fontSize * scale[min(max(level, 1), 6) - 1] * preferences.headingScale), fontSize * 0.9), level <= 2 ? .bold : .semibold)
    }

    static func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender + font.leading) }

    private func paragraph(head: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.headIndent = head
        style.firstLineHeadIndent = head
        return style
    }

    func metrics(_ font: NSFont? = nil, before: CGFloat = 0, after: CGFloat? = nil) -> MarkdownMetrics {
        MarkdownMetrics(font: font ?? bodyFont, before: before, height: fontSize * preferences.lineHeight, after: after ?? paragraphSpacing)
    }

    /// Large letters need less room between lines than text does; the room above says what the heading belongs to.
    private func headingMetrics(_ level: Int) -> MarkdownMetrics {
        let font = headingFont(level)
        let before: [CGFloat] = [1.1, 0.95, 0.8, 0.6, 0.5, 0.5]
        return MarkdownMetrics(font: font, before: round(fontSize * before[min(max(level, 1), 6) - 1]), height: font.pointSize * min(preferences.lineHeight, 1.35), after: max(round(fontSize * 0.3), round(paragraphSpacing * 0.8)))
    }

    /// A line as tall as told, whatever is in it.
    private func fixed(_ height: CGFloat, before: CGFloat = 0, after: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        style.lineBreakMode = .byClipping
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        return style
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph(), .mdMetrics: metrics()]
    }

    /// Keys this styler sets; they are cleared before a paragraph is styled again (others, such as the
    /// marked-text underline of an input method, are left alone).
    static let ownedKeys: [NSAttributedString.Key] = [
        .font, .foregroundColor, .backgroundColor, .paragraphStyle, .strikethroughStyle, .link, .underlineStyle,
        .mdHidden, .mdMarker, .mdMetrics, .mdDecoration, .mdCodeBlock, .mdQuote, .mdRule, .mdPill, .mdTable, .baselineOffset, .kern, .obliqueness,
    ]

    /// Ranges (paragraph by paragraph) of fenced code blocks: the fence lines and the lines between.
    static func codeBlocks(in string: NSString) -> [NSRange] { MarkdownCode.all(in: string).map(\.range) }

    /// Styles the paragraphs in `range` (whole paragraphs, code blocks and tables). `caret`: the selection, while the
    /// editor has the keyboard.
    func style(_ storage: NSTextStorage, range: NSRange, caret: NSRange?, structure: MarkdownStructure) {
        let string = storage.string as NSString
        guard storage.length > 0 else { return }
        let start = min(range.location, storage.length)
        var range = string.paragraphRange(for: NSRange(location: start, length: min(range.length, storage.length - start)))
        for block in structure.codes.map(\.range) + structure.tables.map(\.range) where NSIntersectionRange(block, range).length > 0 {
            range = NSUnionRange(range, block)
        }
        range = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        storage.beginEditing()
        for key in Self.ownedKeys { storage.removeAttribute(key, range: range) }
        storage.addAttributes(baseAttributes, range: range)
        var location = range.location
        while location < NSMaxRange(range) {
            if let code = structure.codes.first(where: { NSLocationInRange(location, $0.range) }) {
                styleCode(storage, code, caret: caret)
                location = NSMaxRange(code.range)
                continue
            }
            if let index = structure.table(at: location) {
                styleTable(storage, structure.tables[index].range, height: structure.tableHeights[index])
                location = NSMaxRange(structure.tables[index].range)
                continue
            }
            let line = string.paragraphRange(for: NSRange(location: location, length: 0))
            styleLine(storage, line: line, caret: caret.flatMap { touches($0, line, atEnd: NSMaxRange(line) == storage.length && (line.length == 0 || string.character(at: NSMaxRange(line) - 1) != 10)) ? $0 : nil })
            location = NSMaxRange(line)
            if line.length == 0 { break }
        }
        // Setting the font took away the one AppKit falls back to for Chinese (PingFang): it chooses again here.
        storage.fixAttributes(in: range)
        storage.endEditing()
    }

    /// The caret is on the line (the end of the line above it is not).
    private func touches(_ caret: NSRange, _ line: NSRange, atEnd: Bool) -> Bool {
        if caret.length > 0 { return caret.location >= line.location && NSMaxRange(caret) <= NSMaxRange(line) }
        return NSLocationInRange(caret.location, line) || (atEnd && caret.location == NSMaxRange(line))
    }

    private func dim(_ storage: NSTextStorage, _ range: NSRange, shown: Bool) {
        guard range.length > 0 else { return }
        storage.addAttribute(.mdMarker, value: true, range: range)
        storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
        if !shown { hide(storage, range) }
    }

    /// Takes characters out of sight without touching the glyphs AppKit makes (and the fonts it falls back to for
    /// Chinese): a hair-thin font, no colour. They take no room and add no height to their line.
    static let hiddenFont = NSFont.systemFont(ofSize: 0.01)

    func hide(_ storage: NSTextStorage, _ range: NSRange) {
        guard range.length > 0 else { return }
        storage.addAttributes([.mdHidden: true, .font: Self.hiddenFont, .foregroundColor: NSColor.clear], range: range)
    }

    // MARK: Code blocks and tables

    private func styleCode(_ storage: NSTextStorage, _ code: MarkdownCode, caret: NSRange?) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = max(round(monoFont.pointSize * min(preferences.lineHeight, 1.7) - Self.lineHeight(monoFont)), 1)
        style.headIndent = Self.codePadding
        style.firstLineHeadIndent = Self.codePadding
        style.tailIndent = -Self.codePadding
        style.defaultTabInterval = (String(repeating: " ", count: preferences.codeIndent) as NSString).size(withAttributes: [.font: monoFont]).width
        style.tabStops = []
        storage.addAttributes([.font: monoFont, .paragraphStyle: style, .mdCodeBlock: true], range: code.range)
        if code.isClosed {
            hide(storage, code.open)
            storage.addAttribute(.paragraphStyle, value: fixed(Self.codeHeaderHeight, before: 6), range: code.open)
        } else {
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: code.open)
        }
        if let close = code.close {
            hide(storage, close)
            storage.addAttribute(.paragraphStyle, value: fixed(Self.codeFooterHeight, after: round(fontSize * 0.7)), range: close)
        }
        storage.removeAttribute(.mdMetrics, range: code.range)
        let string = storage.string as NSString
        guard preferences.highlightsCode, code.text.length > 0, code.text.length < 60_000, let language = code.language(in: string).id else { return }
        for token in CodeHighlighter.shared.tokens(string.substring(with: code.text), language: language) {
            let range = NSRange(location: code.text.location + token.range.location, length: token.range.length)
            guard NSMaxRange(range) <= storage.length, let color = CodeHighlighter.color(of: token.kind) else { continue }
            storage.addAttribute(.foregroundColor, value: color, range: range)
        }
    }

    /// The table's lines take its view's height, on the first of them; nothing of them is drawn.
    private func styleTable(_ storage: NSTextStorage, _ range: NSRange, height: CGFloat) {
        hide(storage, range)
        storage.removeAttribute(.mdMetrics, range: range)
        storage.addAttributes([.paragraphStyle: fixed(0.01), .mdTable: true], range: range)
        let string = storage.string as NSString
        let first = string.paragraphRange(for: NSRange(location: range.location, length: 0))
        storage.addAttribute(.paragraphStyle, value: fixed(max(height, 1), before: 4), range: NSIntersectionRange(first, range))
        let last = string.paragraphRange(for: NSRange(location: NSMaxRange(range) - 1, length: 0))
        if last.location > first.location { storage.addAttribute(.paragraphStyle, value: fixed(0.01, after: round(fontSize * 0.5)), range: NSIntersectionRange(last, range)) }
    }

    // MARK: Lines

    private func styleLine(_ storage: NSTextStorage, line: NSRange, caret: NSRange?) {
        let string = storage.string as NSString
        let found = MarkdownLine(in: string, at: line.location)
        let content = found.content
        let body = NSRange(location: found.textStart, length: max(NSMaxRange(content) - found.textStart, 0))
        if found.kind == .rule {
            dim(storage, content, shown: caret != nil)
            if caret == nil {
                storage.addAttribute(.mdRule, value: true, range: line)
            }
            return
        }
        hide(storage, found.prefix)
        var font = bodyFont, head = CGFloat(found.quoteDepth) * quoteStep, mark = MarkdownDecoration.Mark.none, placeholder = ""
        var metrics = self.metrics()
        if found.quoteDepth > 0 {
            storage.addAttribute(.mdQuote, value: found.quoteDepth, range: line)
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: body)
            placeholder = String(localized: "引用块")
        }
        switch found.kind {
        case .heading(let level):
            font = headingFont(level)
            metrics = headingMetrics(level)
            placeholder = String(localized: "标题 \(level)")
            storage.addAttribute(.font, value: font, range: NSRange(location: body.location, length: NSMaxRange(line) - body.location))
        case .bullet, .numbered, .task, .continuation:
            let level = MarkdownLine.level(of: found, in: string)
            head += CGFloat(level + 1) * listStep
            if case .bullet = found.kind { mark = .bullet(level); placeholder = String(localized: "列表") }
            if case .numbered = found.kind { mark = .number(string.substring(with: found.marker)); placeholder = String(localized: "列表") }
            if case .task(let done) = found.kind {
                mark = .task(done)
                placeholder = String(localized: "待办事项")
                if done, body.length > 0 {
                    storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: body)
                    if preferences.strikesDone { storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: body) }
                }
            }
            // The lines of a list keep together.
            metrics = self.metrics(after: round(paragraphSpacing * 0.5))
        default: break
        }
        storage.addAttributes([.paragraphStyle: paragraph(head: head), .mdMetrics: metrics], range: line)
        if found.prefix.length > 0 {
            let decoration = MarkdownDecoration(mark: mark, textOffset: found.prefix.length, x: head, font: font,
                                                placeholder: found.isEmpty && caret != nil && preferences.showsPlaceholders ? placeholder : "")
            storage.addAttribute(.mdDecoration, value: decoration, range: NSRange(location: line.location, length: 1))
        }
        styleInline(storage, range: body, caret: caret)
    }

    private static let code = try! NSRegularExpression(pattern: #"(`+)(?!`)(.+?)(?<!`)\1(?!`)"#)
    private static let image = try! NSRegularExpression(pattern: #"(!\[)([^\]\n]*)(\]\(([^)\s]+)(?:[ \t]+"[^"\n]*")?\))"#)
    private static let link = try! NSRegularExpression(pattern: #"(?<!!)(\[)([^\]\n]+)(\]\(([^)\s]+)(?:[ \t]+"[^"\n]*")?\))"#)
    private static let autolink = try! NSRegularExpression(pattern: #"(<)?(https?://[^\s<>()]+[^\s<>().,;:!?'"\]])(>)?"#)
    private static let boldItalic = try! NSRegularExpression(pattern: #"(\*\*\*)(?=[^\s*])(.+?)(?<=[^\s*])\1(?!\*)"#)
    private static let bold = try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    /// With stars inside words too (Chinese has no spaces around them); underscores only around words (snake_case).
    private static let italic = try! NSRegularExpression(pattern: #"(?<!\*)(\*)(?=[^\s*])([^*\n]+?)(?<=[^\s*])\1(?!\*)"#)
    private static let italicUnderscore = try! NSRegularExpression(pattern: #"(?<![_\p{L}\p{N}])(_)(?=[^\s_])(.+?)(?<=[^\s_])\1(?![_\p{L}\p{N}])"#)
    private static let strike = try! NSRegularExpression(pattern: #"(~~)(?=\S)(.+?)(?<=\S)\1"#)
    private static let mark = try! NSRegularExpression(pattern: #"(==)(?=\S)(.+?)(?<=\S)\1"#)

    static let codeColor = NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(srgbRed: 1, green: 0.55, blue: 0.62, alpha: 1) : NSColor(srgbRed: 0.76, green: 0.15, blue: 0.3, alpha: 1) }

    /// The symbols inside a line are drawn while the caret is at what they mark.
    func styleInline(_ storage: NSTextStorage, range: NSRange, caret: NSRange?) {
        guard range.length > 0 else { return }
        let string = storage.string
        var taken: [NSRange] = []
        func free(_ r: NSRange) -> Bool { !taken.contains { NSIntersectionRange($0, r).length > 0 } }
        func shown(_ r: NSRange) -> Bool { caret.map { $0.location <= NSMaxRange(r) && NSMaxRange($0) >= r.location } ?? false }

        for match in Self.code.matches(in: string, range: range) where free(match.range) {
            let ticks = match.range(at: 1).length
            dim(storage, NSRange(location: match.range.location, length: ticks), shown: shown(match.range))
            dim(storage, NSRange(location: NSMaxRange(match.range) - ticks, length: ticks), shown: shown(match.range))
            storage.addAttributes([.font: monoFont, .backgroundColor: NSColor(white: 0.5, alpha: 0.15), .mdPill: true,
                                   .foregroundColor: Self.codeColor], range: match.range(at: 2))
            taken.append(match.range)
        }
        for regex in [Self.image, Self.link] {
            for match in regex.matches(in: string, range: range) where free(match.range) {
                dim(storage, match.range(at: 1), shown: shown(match.range))
                dim(storage, match.range(at: 3), shown: shown(match.range))
                storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: match.range(at: 2))
                if !shown(match.range), let url = URL(string: (string as NSString).substring(with: match.range(at: 4))) {
                    storage.addAttribute(.link, value: url, range: match.range(at: 2))
                }
                taken.append(match.range)
            }
        }
        for match in Self.autolink.matches(in: string, range: range) where free(match.range) {
            if match.range(at: 1).location != NSNotFound { dim(storage, match.range(at: 1), shown: shown(match.range)) }
            if match.range(at: 3).location != NSNotFound { dim(storage, match.range(at: 3), shown: shown(match.range)) }
            storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: match.range(at: 2))
            if !shown(match.range), let url = URL(string: (string as NSString).substring(with: match.range(at: 2))) {
                storage.addAttribute(.link, value: url, range: match.range(at: 2))
            }
            taken.append(match.range)
        }
        func emphasize(_ regex: NSRegularExpression, _ apply: (NSRange) -> Void) {
            for match in regex.matches(in: string, range: range) where free(match.range(at: 1)) && free(NSRange(location: NSMaxRange(match.range) - match.range(at: 1).length, length: match.range(at: 1).length)) {
                let marker = match.range(at: 1).length
                dim(storage, NSRange(location: match.range.location, length: marker), shown: shown(match.range))
                dim(storage, NSRange(location: NSMaxRange(match.range) - marker, length: marker), shown: shown(match.range))
                apply(match.range(at: 2))
            }
        }
        for match in Self.boldItalic.matches(in: string, range: range) where free(match.range(at: 1)) {
            dim(storage, match.range(at: 1), shown: shown(match.range))
            dim(storage, NSRange(location: NSMaxRange(match.range) - 3, length: 3), shown: shown(match.range))
            convert(storage, match.range(at: 2), trait: .boldFontMask)
            convert(storage, match.range(at: 2), trait: .italicFontMask)
            taken += [match.range(at: 1), NSRange(location: NSMaxRange(match.range) - 3, length: 3)]
        }
        emphasize(Self.bold) { inner in self.convert(storage, inner, trait: .boldFontMask) }
        emphasize(Self.italic) { inner in self.convert(storage, inner, trait: .italicFontMask) }
        emphasize(Self.italicUnderscore) { inner in self.convert(storage, inner, trait: .italicFontMask) }
        emphasize(Self.strike) { inner in storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: inner) }
        emphasize(Self.mark) { inner in storage.addAttributes([.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.35), .mdPill: true], range: inner) }
    }

    private func convert(_ storage: NSTextStorage, _ range: NSRange, trait: NSFontTraitMask) {
        storage.enumerateAttribute(.font, in: range) { value, sub, _ in
            guard let font = value as? NSFont, font.pointSize > 1 else { return }
            var converted = NSFontManager.shared.convert(font, toHaveTrait: trait)
            // The system font has no italic of its own for CJK; an oblique stands in.
            if trait == .italicFontMask, !converted.fontDescriptor.symbolicTraits.contains(.italic) {
                let matrix = AffineTransform(m11: 1, m12: 0, m21: 0.2, m22: 1, tX: 0, tY: 0)
                converted = NSFont(descriptor: font.fontDescriptor.withMatrix(matrix), size: font.pointSize) ?? font
            }
            storage.addAttribute(.font, value: converted, range: sub)
            // Chinese is drawn in the font AppKit falls back to, which has no italic: slanted instead.
            guard trait == .italicFontMask else { return }
            let string = storage.string as NSString
            string.enumerateSubstrings(in: sub, options: .byComposedCharacterSequences) { character, range, _, _ in
                guard let scalar = character?.unicodeScalars.first, (0x2E80...0x9FFF).contains(scalar.value) || (0xAC00...0xD7AF).contains(scalar.value) else { return }
                storage.addAttribute(.obliqueness, value: 0.2, range: range)
            }
        }
    }
}

// MARK: - Layout and drawing

/// Paints what Markdown means but the text does not show: bullets, numbers, task boxes, the bars of a quote, the box
/// of a code block, the line of a rule.
final class MarkdownLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    nonisolated override init() {
        super.init()
        nonisolated(unsafe) let manager = self
        MainActor.assumeIsolated {
            manager.allowsNonContiguousLayout = false
            manager.delegate = manager
        }
    }

    /// Every line as tall, and its text as low in it, as its metrics say.
    nonisolated func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                                   lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                                   in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        nonisolated(unsafe) let rect = lineFragmentRect, used = lineFragmentUsedRect, baseline = baselineOffset
        nonisolated(unsafe) let manager = self
        return MainActor.assumeIsolated {
            guard let storage = manager.textStorage else { return false }
            let characters = manager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            guard characters.location < storage.length, let metrics = storage.attribute(.mdMetrics, at: characters.location, effectiveRange: nil) as? MarkdownMetrics else { return false }
            let line = (storage.string as NSString).paragraphRange(for: NSRange(location: characters.location, length: 0))
            let before = characters.location == line.location && line.location > 0 ? metrics.before : 0
            let after = NSMaxRange(characters) >= NSMaxRange(line) ? metrics.after : 0
            rect.pointee.size.height = before + metrics.line + metrics.spacing + after
            used.pointee.origin.y = rect.pointee.minY + before + metrics.above
            used.pointee.size.height = metrics.line
            baseline.pointee = before + metrics.above + metrics.ascent
            return true
        }
    }

    /// The empty line after a final line break.
    var lastLine: MarkdownMetrics?

    nonisolated override func setExtraLineFragmentRect(_ fragmentRect: NSRect, usedRect: NSRect, textContainer container: NSTextContainer) {
        nonisolated(unsafe) let manager = self
        let last = MainActor.assumeIsolated { manager.lastLine.map { ($0.line, $0.spacing + $0.after, $0.above) } }
        guard let last, fragmentRect.height > 0 else { return super.setExtraLineFragmentRect(fragmentRect, usedRect: usedRect, textContainer: container) }
        var fragment = fragmentRect, used = usedRect
        fragment.size.height = last.0 + last.1
        used.origin.y = fragment.minY + last.2
        used.size.height = last.0
        super.setExtraLineFragmentRect(fragment, usedRect: used, textContainer: container)
    }

    nonisolated required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    /// Where the box of each task is drawn, for clicks (container coordinates).
    private(set) var taskBoxes: [(rect: CGRect, location: Int)] = []
    var fontSize: CGFloat = 13
    /// The code blocks of the text.
    var codes: [NSRange] = []
    /// The task the pointer is on.
    var hoveredTask: Int?

    nonisolated override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        nonisolated(unsafe) let manager = self
        MainActor.assumeIsolated { manager.drawBoxes(forGlyphRange: glyphsToShow, at: origin) }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        MainActor.assumeIsolated { manager.drawDecorations(forGlyphRange: glyphsToShow, at: origin) }
    }

    nonisolated override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: NSColor) {
        // A table shows itself that it is selected.
        if let storage = textStorage, charRange.location < storage.length, storage.attribute(NSAttributedString.Key("FolioMarkdownTable"), at: charRange.location, effectiveRange: nil) != nil { return }
        let key = NSAttributedString.Key("FolioMarkdownPill")
        let pill = textStorage.map { charRange.location < $0.length && $0.attribute(key, at: charRange.location, effectiveRange: nil) != nil } ?? false
        // The selection is drawn through here too.
        guard pill, color.alphaComponent < 0.5 else { return super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color) }
        color.setFill()
        for index in 0..<rectCount { NSBezierPath(roundedRect: rectArray[index].insetBy(dx: -1, dy: 0.5), xRadius: 3.5, yRadius: 3.5).fill() }
    }

    private func lineRects(_ range: NSRange) -> [CGRect] {
        var rects: [CGRect] = []
        enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: range, actualCharacterRange: nil)) { rect, _, _, _, _ in rects.append(rect) }
        return rects
    }

    /// The box of the code block whose characters are `range` (container coordinates).
    func codeBox(_ range: NSRange) -> CGRect? {
        guard let storage = textStorage, let container = textContainers.first, range.length > 0, NSMaxRange(range) <= storage.length else { return nil }
        let rects = lineRects(range)
        guard let first = rects.first, let last = rects.last else { return nil }
        func style(_ at: Int) -> NSParagraphStyle? { storage.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle }
        let top = first.minY + (first.minY > 0 ? style(range.location)?.paragraphSpacingBefore ?? 0 : 0)
        let bottom = last.maxY - (style(NSMaxRange(range) - 1)?.paragraphSpacing ?? 0)
        let padding = container.lineFragmentPadding
        return CGRect(x: padding, y: top, width: container.size.width - padding * 2, height: max(bottom - top, 0))
    }

    /// Under the selection: the boxes of code blocks.
    private func drawBoxes(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        for range in codes where NSMaxRange(range) <= storage.length && (NSIntersectionRange(range, characters).length > 0 || NSLocationInRange(characters.location, range)) {
            guard let box = codeBox(range)?.offsetBy(dx: origin.x, dy: origin.y) else { continue }
            let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            NSColor.labelColor.withAlphaComponent(0.045).setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func drawDecorations(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, let container = textContainers.first, storage.length > 0 else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let padding = container.lineFragmentPadding
        let width = container.size.width - padding * 2
        let string = storage.string as NSString

        // The bars of quotes: one through lines that follow each other.
        var bars: [[CGRect]] = [], ends: [Int] = []
        let lines = string.paragraphRange(for: characters)
        storage.enumerateAttribute(.mdQuote, in: lines) { value, range, _ in
            let whole = string.paragraphRange(for: range)
            guard let depth = value as? Int, let bar = quoteBar(of: whole) else { return }
            for level in 0..<depth {
                while bars.count <= level { bars.append([]); ends.append(-1) }
                let shifted = bar.offsetBy(dx: origin.x + padding + CGFloat(level) * round(fontSize * 1.1) + 2, dy: origin.y)
                // The space between two quoted lines is the bar's too.
                if let above = bars[level].last, ends[level] == whole.location { bars[level][bars[level].count - 1] = above.union(shifted) } else { bars[level].append(shifted) }
                ends[level] = NSMaxRange(whole)
            }
        }
        for (level, rects) in bars.enumerated() {
            NSColor.controlAccentColor.withAlphaComponent(level == 0 ? 0.55 : 0.3).setFill()
            rects.forEach { NSBezierPath(roundedRect: $0, xRadius: 1.5, yRadius: 1.5).fill() }
        }
        storage.enumerateAttribute(.mdRule, in: characters) { value, range, _ in
            guard value != nil, let rect = lineRects(range).first else { return }
            NSColor.separatorColor.setFill()
            let metrics = storage.attribute(.mdMetrics, at: range.location, effectiveRange: nil) as? MarkdownMetrics
            let middle = metrics.map { $0.above + $0.line / 2 } ?? fontSize * 0.6
            CGRect(x: origin.x + padding, y: origin.y + rect.minY + round(middle), width: width, height: 1).fill()
        }
        taskBoxes.removeAll { NSLocationInRange($0.location, characters) || $0.location >= storage.length }
        storage.enumerateAttribute(.mdDecoration, in: characters) { value, range, _ in
            guard let decoration = value as? MarkdownDecoration else { return }
            draw(decoration, at: range.location, origin: origin, padding: padding)
        }
    }

    /// For tests: where a line's mark and bar are drawn.
    func decorationFrames(near location: Int, origin: NSPoint) -> (baseline: CGFloat?, bar: CGRect?)? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let line = (storage.string as NSString).paragraphRange(for: NSRange(location: min(location, storage.length), length: 0))
        guard line.length > 0 else { return nil }
        let decoration = storage.attribute(.mdDecoration, at: line.location, effectiveRange: nil) as? MarkdownDecoration
        return (decoration.map { origin.y + baseline(of: $0, at: line.location) }, quoteBar(of: line)?.offsetBy(dx: origin.x, dy: origin.y))
    }

    /// The height of a quoted line's bar (container coordinates): its rows, without the space between paragraphs.
    private func quoteBar(of line: NSRange) -> CGRect? {
        guard let storage = textStorage, line.length > 0, storage.attribute(.mdQuote, at: line.location, effectiveRange: nil) != nil,
              let first = storage.attribute(.mdMetrics, at: line.location, effectiveRange: nil) as? MarkdownMetrics,
              let last = storage.attribute(.mdMetrics, at: NSMaxRange(line) - 1, effectiveRange: nil) as? MarkdownMetrics else { return nil }
        let rects = lineRects(line)
        guard let top = rects.first, let bottom = rects.last else { return nil }
        let start = top.minY + (line.location > 0 ? first.before : 0)
        return CGRect(x: 0, y: start, width: 3, height: max(bottom.maxY - last.after - start, 4))
    }

    /// The baseline of a line's first row (container coordinates).
    private func baseline(of decoration: MarkdownDecoration, at location: Int) -> CGFloat {
        guard let metrics = textStorage?.attribute(.mdMetrics, at: location, effectiveRange: nil) as? MarkdownMetrics else { return 0 }
        let fragment = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: location), effectiveRange: nil)
        return fragment.minY + (location > 0 ? metrics.before : 0) + metrics.above + metrics.ascent
    }

    private func isEmpty(lineAt location: Int, after offset: Int) -> Bool {
        guard let string = textStorage?.string as NSString? else { return false }
        let line = string.paragraphRange(for: NSRange(location: location, length: 0))
        var end = NSMaxRange(line)
        while end > line.location, [10, 13].contains(string.character(at: end - 1)) { end -= 1 }
        return location + offset >= end
    }

    private func draw(_ decoration: MarkdownDecoration, at location: Int, origin: NSPoint, padding: CGFloat) {
        let font = decoration.font
        let x = origin.x + padding + decoration.x
        let y = origin.y + baseline(of: decoration, at: location)
        // Not over what is being written, composed with an input method included: styling follows only when it is committed.
        if !decoration.placeholder.isEmpty, isEmpty(lineAt: location, after: decoration.textOffset) {
            (decoration.placeholder as NSString).draw(at: NSPoint(x: x, y: y - font.ascender), withAttributes: [.font: font, .foregroundColor: NSColor.placeholderTextColor])
        }
        let middle = y - font.xHeight / 2
        switch decoration.mark {
        case .none: break
        case .bullet(let level):
            let size = round(font.pointSize * 0.36 * 2) / 2
            let dot = CGRect(x: x - round(font.pointSize * 0.85) - size / 2, y: middle - size / 2, width: size, height: size)
            NSColor.secondaryLabelColor.set()
            switch level % 3 {
            case 0: NSBezierPath(ovalIn: dot).fill()
            case 1:
                let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.25, dy: 0.25))
                ring.lineWidth = 1.1
                ring.stroke()
            default: NSBezierPath(rect: dot.insetBy(dx: 0.5, dy: 0.5)).fill()
            }
        case .number(let number):
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
            let size = (number as NSString).size(withAttributes: attributes)
            (number as NSString).draw(at: NSPoint(x: x - size.width - round(font.pointSize * 0.42), y: y - font.ascender), withAttributes: attributes)
        case .task(let done):
            let side = round(font.pointSize * 1.08)
            let box = CGRect(x: x - side - round(font.pointSize * 0.46), y: round((middle - side / 2) * 2) / 2, width: side, height: side)
            let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.6, dy: 0.6), xRadius: 4, yRadius: 4)
            let hovered = hoveredTask == location
            if done {
                NSColor.controlAccentColor.withAlphaComponent(hovered ? 0.8 : 1).setFill()
                path.fill()
                let check = NSBezierPath()
                check.move(to: CGPoint(x: box.minX + side * 0.27, y: box.minY + side * 0.52))
                check.line(to: CGPoint(x: box.minX + side * 0.44, y: box.minY + side * 0.69))
                check.line(to: CGPoint(x: box.minX + side * 0.74, y: box.minY + side * 0.33))
                check.lineWidth = max(side * 0.11, 1.4)
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                NSColor.white.setStroke()
                check.stroke()
            } else {
                if hovered { NSColor.controlAccentColor.withAlphaComponent(0.14).setFill(); path.fill() }
                (hovered ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
                path.lineWidth = 1.3
                path.stroke()
            }
            taskBoxes.append((box.offsetBy(dx: -origin.x, dy: -origin.y), location))
        }
    }
}
