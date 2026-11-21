import AppKit

// MARK: - Attributes

extension NSAttributedString.Key {
    /// Markdown syntax (`**`, `# `, `[`, `](url)` …) that is not drawn while its line is not being edited.
    static let mdHidden = NSAttributedString.Key("FolioMarkdownHidden")
    /// Syntax characters, drawn dimmed while their line is being edited.
    static let mdMarker = NSAttributedString.Key("FolioMarkdownMarker")
    /// A list marker (`-`, `*`, `+`) drawn as a bullet while its line is not being edited.
    static let mdBullet = NSAttributedString.Key("FolioMarkdownBullet")
    /// The lines of a fenced code block (value: the block's number, so two blocks in a row stay apart).
    static let mdCodeBlock = NSAttributedString.Key("FolioMarkdownCodeBlock")
    /// A quoted line.
    static let mdQuote = NSAttributedString.Key("FolioMarkdownQuote")
    /// A thematic break (`---`) drawn as a line.
    static let mdRule = NSAttributedString.Key("FolioMarkdownRule")
    /// The first character after a task's `- [ ] ` (value: whether it is done); the box is drawn before it.
    static let mdTask = NSAttributedString.Key("FolioMarkdownTask")
}

// MARK: - Styling

/// Gives Markdown source the look of the rendered document without changing a character: the source stays the
/// file's text (copy, undo, search and saving all see Markdown), only how it is drawn changes. On the lines being
/// edited the syntax shows, dimmed; elsewhere it is hidden and lists, tasks, quotes, code and rules are drawn.
struct MarkdownStyler {
    var fontSize: CGFloat = 13

    var bodyFont: NSFont { .systemFont(ofSize: fontSize) }
    var monoFont: NSFont { .monospacedSystemFont(ofSize: fontSize - 1, weight: .regular) }
    private var lineSpacing: CGFloat { round(fontSize * 0.28) }

    func headingFont(_ level: Int) -> NSFont {
        let scale: [CGFloat] = [1.6, 1.36, 1.18, 1.06, 1, 1]
        return .systemFont(ofSize: round(fontSize * scale[min(max(level, 1), 6) - 1]), weight: level <= 2 ? .bold : .semibold)
    }

    private func paragraph(head: CGFloat = 0, first: CGFloat? = nil, before: CGFloat = 0, after: CGFloat? = nil) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = after ?? round(fontSize * 0.35)
        style.paragraphSpacingBefore = before
        style.headIndent = head
        style.firstLineHeadIndent = first ?? head
        return style
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph()]
    }

    /// Keys this styler sets; they are cleared before a paragraph is styled again (others, such as the
    /// marked-text underline of an input method, are left alone).
    static let ownedKeys: [NSAttributedString.Key] = [
        .font, .foregroundColor, .backgroundColor, .paragraphStyle, .strikethroughStyle, .link, .underlineStyle,
        .mdHidden, .mdMarker, .mdBullet, .mdCodeBlock, .mdQuote, .mdRule, .mdTask, .baselineOffset, .kern,
    ]

    /// Ranges (paragraph by paragraph) of fenced code blocks: the fence lines and the lines between.
    static func codeBlocks(in string: NSString) -> [NSRange] {
        var blocks: [NSRange] = []
        var start: Int?
        var fence = ""
        var location = 0
        while location < string.length {
            let line = string.paragraphRange(for: NSRange(location: location, length: 0))
            let text = string.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if let open = start {
                if text.hasPrefix(fence), text.trimmingCharacters(in: CharacterSet(charactersIn: fence.prefix(1).description)).isEmpty {
                    blocks.append(NSRange(location: open, length: NSMaxRange(line) - open))
                    start = nil
                }
            } else if text.hasPrefix("```") || text.hasPrefix("~~~") {
                start = line.location
                fence = String(text.prefix { $0 == text.first })
            }
            location = NSMaxRange(line)
            if line.length == 0 { break }
        }
        if let open = start { blocks.append(NSRange(location: open, length: string.length - open)) }
        return blocks
    }

    /// Styles the paragraphs in `range` (whole paragraphs). `active`: the paragraphs being edited.
    func style(_ storage: NSTextStorage, range: NSRange, active: NSRange?, codeBlocks: [NSRange]) {
        let string = storage.string as NSString
        guard storage.length > 0 else { return }
        let range = string.paragraphRange(for: NSRange(location: min(range.location, storage.length), length: min(range.length, storage.length - min(range.location, storage.length))))
        storage.beginEditing()
        for key in Self.ownedKeys { storage.removeAttribute(key, range: range) }
        storage.addAttributes(baseAttributes, range: range)
        var location = range.location
        while location < NSMaxRange(range) {
            let line = string.paragraphRange(for: NSRange(location: location, length: 0))
            // An empty last line (the caret after the final line break) is a line of its own, not the end of the one above.
            let isActive = active.map { $0.length > 0 ? NSIntersectionRange($0, line).length > 0 : $0.location == line.location } ?? false
            if let block = codeBlocks.firstIndex(where: { NSIntersectionRange($0, line).length > 0 }) {
                styleCode(storage, line: line, block: block, blockRange: codeBlocks[block], active: isActive)
            } else {
                styleLine(storage, line: line, active: isActive)
            }
            location = NSMaxRange(line)
            if line.length == 0 { break }
        }
        // Setting the font took away the one AppKit falls back to for Chinese (PingFang): it chooses again here.
        storage.fixAttributes(in: range)
        storage.endEditing()
    }

    private func dim(_ storage: NSTextStorage, _ range: NSRange, active: Bool) {
        guard range.length > 0 else { return }
        storage.addAttribute(.mdMarker, value: true, range: range)
        storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
        if !active { hide(storage, range) }
    }

    /// Takes characters out of sight without touching the glyphs AppKit makes (and the fonts it falls back to for
    /// Chinese): a hair-thin font, no colour. They take no room and add no height to their line.
    static let hiddenFont = NSFont.systemFont(ofSize: 0.01)

    func hide(_ storage: NSTextStorage, _ range: NSRange) {
        guard range.length > 0 else { return }
        storage.addAttributes([.mdHidden: true, .font: Self.hiddenFont, .foregroundColor: NSColor.clear], range: range)
    }

    private func styleCode(_ storage: NSTextStorage, line: NSRange, block: Int, blockRange: NSRange, active: Bool) {
        let string = storage.string as NSString
        let text = string.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
        let isFence = line.location == blockRange.location || (NSMaxRange(line) == NSMaxRange(blockRange) && (text.hasPrefix("```") || text.hasPrefix("~~~")))
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.headIndent = 10
        style.firstLineHeadIndent = 10
        style.tailIndent = -10
        style.paragraphSpacing = 0
        if line.location == blockRange.location { style.paragraphSpacingBefore = 4 }
        if NSMaxRange(line) >= NSMaxRange(blockRange) { style.paragraphSpacing = round(fontSize * 0.6) }
        storage.addAttributes([.font: monoFont, .paragraphStyle: style, .mdCodeBlock: block + 1], range: line)
        if isFence {
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: line)
            if !active {
                // The fence's language stays as a small label; the backticks go.
                let body = string.substring(with: line) as NSString
                let ticks = body.range(of: #"^\s*(`{3,}|~{3,})"#, options: .regularExpression)
                storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: max(fontSize - 3, 9), weight: .medium), range: line)
                if ticks.location != NSNotFound {
                    hide(storage, NSRange(location: line.location + ticks.location, length: ticks.length))
                }
            }
        }
    }

    private static let heading = try! NSRegularExpression(pattern: #"^(#{1,6})([ \t]+|$)"#)
    private static let rule = try! NSRegularExpression(pattern: #"^ {0,3}([-*_])([ \t]*\1){2,}[ \t]*$"#)
    private static let quote = try! NSRegularExpression(pattern: #"^[ \t]*(>[ \t]?)+"#)
    private static let task = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+])[ \t]+\[([ xX])\][ \t]+"#)
    private static let bullet = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+])[ \t]+"#)
    private static let ordered = try! NSRegularExpression(pattern: #"^([ \t]*)(\d{1,9}[.)])[ \t]+"#)
    private static let table = try! NSRegularExpression(pattern: #"^[ \t]*\|.*\|[ \t]*$"#)

    private func indentWidth(_ whitespace: String) -> CGFloat {
        let columns = whitespace.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        return CGFloat(columns / 2) * round(fontSize * 1.5)
    }

    private func width(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private func styleLine(_ storage: NSTextStorage, line: NSRange, active: Bool) {
        let string = storage.string as NSString
        var content = line
        // The paragraph without its line break.
        let raw = string.substring(with: line)
        let trimmedLength = (raw.hasSuffix("\r\n") ? 2 : raw.hasSuffix("\n") || raw.hasSuffix("\r") ? 1 : 0)
        content.length -= trimmedLength
        let text = string.substring(with: content)
        let whole = NSRange(location: 0, length: (text as NSString).length)
        func abs(_ r: NSRange) -> NSRange { NSRange(location: content.location + r.location, length: r.length) }

        if let match = Self.rule.firstMatch(in: text, range: whole) {
            _ = match
            dim(storage, content, active: active)
            if !active {
                storage.addAttribute(.mdRule, value: true, range: line)
                // The characters are gone; the line keeps a body line's height for the rule to sit in.
                let style = paragraph()
                if let mutable = style.mutableCopy() as? NSMutableParagraphStyle {
                    mutable.minimumLineHeight = ceil(bodyFont.ascender - bodyFont.descender + bodyFont.leading)
                    storage.addAttribute(.paragraphStyle, value: mutable, range: line)
                }
            }
            return
        }
        if let match = Self.heading.firstMatch(in: text, range: whole) {
            let level = match.range(at: 1).length
            let font = headingFont(level)
            storage.addAttributes([.font: font, .paragraphStyle: paragraph(before: level <= 2 ? round(fontSize * 0.6) : round(fontSize * 0.3),
                                                                            after: round(fontSize * 0.4))], range: line)
            dim(storage, abs(match.range), active: active)
            styleInline(storage, range: abs(NSRange(location: match.range.length, length: whole.length - match.range.length)), active: active)
            return
        }
        var start = 0
        var lead: CGFloat = 0
        if let match = Self.quote.firstMatch(in: text, range: whole) {
            dim(storage, abs(match.range), active: active)
            storage.addAttribute(.mdQuote, value: true, range: line)
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: abs(NSRange(location: match.range.length, length: whole.length - match.range.length)))
            lead = round(fontSize * 1.1)
            start = match.range.length
        }
        let rest = NSRange(location: start, length: whole.length - start)
        if let match = Self.task.firstMatch(in: text, range: rest) {
            let base = lead + indentWidth((text as NSString).substring(with: match.range(at: 1)))
            let box = round(fontSize * 1.55)
            let done = (text as NSString).substring(with: match.range(at: 3)) != " "
            dim(storage, abs(NSRange(location: match.range.location, length: match.range.length)), active: active)
            storage.addAttribute(.paragraphStyle, value: paragraph(head: base + box, first: active ? base : base + box), range: line)
            let after = NSMaxRange(match.range)
            if !active, after <= whole.length {
                let at = abs(NSRange(location: min(after, max(whole.length - 1, 0)), length: whole.length > 0 ? 1 : 0))
                if at.length > 0 { storage.addAttribute(.mdTask, value: done, range: at) }
                else { storage.addAttribute(.mdTask, value: done, range: NSRange(location: line.location, length: min(1, line.length))) }
            }
            let body = NSRange(location: after, length: whole.length - after)
            if done, body.length > 0 {
                storage.addAttributes([.foregroundColor: NSColor.secondaryLabelColor, .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: abs(body))
            }
            styleInline(storage, range: abs(body), active: active)
            return
        }
        if let match = Self.bullet.firstMatch(in: text, range: rest) ?? Self.ordered.firstMatch(in: text, range: rest) {
            let indent = lead + indentWidth((text as NSString).substring(with: match.range(at: 1)))
            let marker = (text as NSString).substring(with: match.range(at: 2))
            let isBullet = marker.count == 1 && "-*+".contains(marker)
            let after = NSMaxRange(match.range)
            // Leading spaces are the nesting level, shown by the indent instead.
            if match.range(at: 1).length > 0 { hide(storage, abs(match.range(at: 1))) }
            if isBullet, !active {
                // "- " goes; a dot is drawn in its place (MarkdownLayoutManager), the text hanging after it.
                let box = round(fontSize * 1.3)
                storage.addAttribute(.paragraphStyle, value: paragraph(head: indent + box, first: indent + box), range: line)
                hide(storage, abs(NSRange(location: match.range(at: 2).location, length: after - match.range(at: 2).location)))
                let at = after < whole.length ? after : match.range(at: 2).location
                storage.addAttribute(.mdBullet, value: true, range: abs(NSRange(location: at, length: 1)))
            } else {
                // The marker hangs: wrapped lines start under the text, not under the marker.
                let markerWidth = width((text as NSString).substring(with: NSRange(location: match.range(at: 2).location,
                                                                                    length: after - match.range(at: 2).location)), bodyFont)
                storage.addAttribute(.paragraphStyle, value: paragraph(head: indent + markerWidth, first: indent), range: line)
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: abs(match.range(at: 2)))
            }
            styleInline(storage, range: abs(NSRange(location: after, length: whole.length - after)), active: active)
            return
        }
        if lead > 0 {
            storage.addAttribute(.paragraphStyle, value: paragraph(head: lead, first: lead), range: line)
        }
        if start == 0, Self.table.firstMatch(in: text, range: whole) != nil {
            storage.addAttribute(.font, value: monoFont, range: content)
            let pipes = try! NSRegularExpression(pattern: #"\||(?<=\|)[ \t]*:?-{3,}:?[ \t]*(?=\|)"#)
            for pipe in pipes.matches(in: text, range: whole) {
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: abs(pipe.range))
            }
            styleInline(storage, range: content, active: true)
            return
        }
        styleInline(storage, range: abs(rest), active: active)
    }

    private static let code = try! NSRegularExpression(pattern: #"(`+)(?!`)(.+?)(?<!`)\1(?!`)"#)
    private static let image = try! NSRegularExpression(pattern: #"(!\[)([^\]\n]*)(\]\(([^)\s]+)(?:[ \t]+"[^"\n]*")?\))"#)
    private static let link = try! NSRegularExpression(pattern: #"(?<!!)(\[)([^\]\n]+)(\]\(([^)\s]+)(?:[ \t]+"[^"\n]*")?\))"#)
    private static let autolink = try! NSRegularExpression(pattern: #"(<)?(https?://[^\s<>()]+[^\s<>().,;:!?'"\]])(>)?"#)
    private static let bold = try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italic = try! NSRegularExpression(pattern: #"(?<![*_\p{L}\p{N}])([*_])(?=[^\s*_])(.+?)(?<=[^\s*_])\1(?![*_\p{L}\p{N}])"#)
    private static let strike = try! NSRegularExpression(pattern: #"(~~)(?=\S)(.+?)(?<=\S)\1"#)
    private static let mark = try! NSRegularExpression(pattern: #"(==)(?=\S)(.+?)(?<=\S)\1"#)

    private func styleInline(_ storage: NSTextStorage, range: NSRange, active: Bool) {
        guard range.length > 0 else { return }
        let string = storage.string
        var taken: [NSRange] = []
        func free(_ r: NSRange) -> Bool { !taken.contains { NSIntersectionRange($0, r).length > 0 } }

        for match in Self.code.matches(in: string, range: range) where free(match.range) {
            let ticks = match.range(at: 1).length
            dim(storage, NSRange(location: match.range.location, length: ticks), active: active)
            dim(storage, NSRange(location: NSMaxRange(match.range) - ticks, length: ticks), active: active)
            storage.addAttributes([.font: monoFont, .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.12),
                                   .foregroundColor: NSColor.systemPink], range: match.range(at: 2))
            taken.append(match.range)
        }
        for regex in [Self.image, Self.link] {
            for match in regex.matches(in: string, range: range) where free(match.range) {
                dim(storage, match.range(at: 1), active: active)
                dim(storage, match.range(at: 3), active: active)
                storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: match.range(at: 2))
                if !active, let url = URL(string: (string as NSString).substring(with: match.range(at: 4))) {
                    storage.addAttribute(.link, value: url, range: match.range(at: 2))
                }
                taken.append(match.range)
            }
        }
        for match in Self.autolink.matches(in: string, range: range) where free(match.range) {
            if match.range(at: 1).location != NSNotFound { dim(storage, match.range(at: 1), active: active) }
            if match.range(at: 3).location != NSNotFound { dim(storage, match.range(at: 3), active: active) }
            storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: match.range(at: 2))
            if !active, let url = URL(string: (string as NSString).substring(with: match.range(at: 2))) {
                storage.addAttribute(.link, value: url, range: match.range(at: 2))
            }
            taken.append(match.range)
        }
        func emphasize(_ regex: NSRegularExpression, _ apply: (NSRange) -> Void) {
            for match in regex.matches(in: string, range: range) where free(match.range(at: 1)) && free(NSRange(location: NSMaxRange(match.range) - match.range(at: 1).length, length: match.range(at: 1).length)) {
                let marker = match.range(at: 1).length
                dim(storage, NSRange(location: match.range.location, length: marker), active: active)
                dim(storage, NSRange(location: NSMaxRange(match.range) - marker, length: marker), active: active)
                apply(match.range(at: 2))
            }
        }
        emphasize(Self.bold) { inner in self.convert(storage, inner, trait: .boldFontMask) }
        emphasize(Self.italic) { inner in self.convert(storage, inner, trait: .italicFontMask) }
        emphasize(Self.strike) { inner in storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: inner) }
        emphasize(Self.mark) { inner in storage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35), range: inner) }
    }

    private func convert(_ storage: NSTextStorage, _ range: NSRange, trait: NSFontTraitMask) {
        storage.enumerateAttribute(.font, in: range) { value, sub, _ in
            guard let font = value as? NSFont else { return }
            var converted = NSFontManager.shared.convert(font, toHaveTrait: trait)
            // The system font has no italic of its own for CJK; an oblique stands in.
            if trait == .italicFontMask, !converted.fontDescriptor.symbolicTraits.contains(.italic) {
                let matrix = AffineTransform(m11: 1, m12: 0, m21: 0.2, m22: 1, tX: 0, tY: 0)
                converted = NSFont(descriptor: font.fontDescriptor.withMatrix(matrix), size: font.pointSize) ?? font
            }
            storage.addAttribute(.font, value: converted, range: sub)
        }
    }
}

// MARK: - Layout and drawing

/// Paints what Markdown means but the text does not show: bullets, task boxes, the bar of a quote, the box of a
/// code block, the line of a rule.
final class MarkdownLayoutManager: NSLayoutManager {
    nonisolated override init() {
        super.init()
        nonisolated(unsafe) let manager = self
        MainActor.assumeIsolated { manager.allowsNonContiguousLayout = false }
    }

    nonisolated required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    /// Where the box of each task is drawn, for clicks (container coordinates).
    private(set) var taskBoxes: [(rect: CGRect, location: Int)] = []

    nonisolated override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        nonisolated(unsafe) let manager = self
        MainActor.assumeIsolated { manager.drawDecorations(forGlyphRange: glyphsToShow, at: origin) }
    }

    private func drawDecorations(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let padding = container.lineFragmentPadding
        let width = container.size.width - padding * 2

        func lineRects(_ range: NSRange) -> [CGRect] {
            var rects: [CGRect] = []
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in rects.append(rect) }
            return rects
        }

        // Code blocks: one rounded box across the column.
        storage.enumerateAttribute(.mdCodeBlock, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil, NSIntersectionRange(range, characters).length > 0 || NSLocationInRange(characters.location, range) else { return }
            let rects = lineRects(range)
            guard let first = rects.first, let last = rects.last else { return }
            let box = CGRect(x: origin.x + padding, y: origin.y + first.minY, width: width, height: last.maxY - first.minY)
                .insetBy(dx: 0, dy: 1)
            NSColor.quaternaryLabelColor.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        }
        storage.enumerateAttribute(.mdQuote, in: characters) { value, range, _ in
            guard value != nil else { return }
            for rect in lineRects(range) {
                let bar = CGRect(x: origin.x + padding + 2, y: origin.y + rect.minY, width: 3, height: rect.height)
                NSColor.tertiaryLabelColor.setFill()
                NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
        storage.enumerateAttribute(.mdRule, in: characters) { value, range, _ in
            guard value != nil, let rect = lineRects(range).first else { return }
            let line = CGRect(x: origin.x + padding, y: origin.y + rect.midY - 0.5, width: width, height: 1)
            NSColor.separatorColor.setFill()
            line.fill()
        }
        storage.enumerateAttribute(.mdBullet, in: characters) { value, range, _ in
            guard value != nil else { return }
            let glyph = glyphIndexForCharacter(at: range.location)
            let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let font = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont).flatMap { $0.pointSize > 1 ? $0 : nil }
                ?? .systemFont(ofSize: 13)
            let size = round(font.pointSize * 0.36 * 2) / 2
            let x = fragment.minX + padding + (style?.firstLineHeadIndent ?? 0) - round(font.pointSize * 0.85)
            let baseline = fragment.minY + typesetter.baselineOffset(in: self, glyphIndex: glyph)
            let dot = CGRect(x: origin.x + x - size / 2, y: origin.y + baseline - font.xHeight / 2 - size / 2, width: size, height: size)
            NSColor.secondaryLabelColor.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
        taskBoxes.removeAll { NSLocationInRange($0.location, characters) }
        storage.enumerateAttribute(.mdTask, in: characters) { value, range, _ in
            guard let done = value as? Bool else { return }
            let glyph = glyphIndexForCharacter(at: range.location)
            var effective = NSRange()
            let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: &effective)
            let used = lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            let font = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont).flatMap { $0.pointSize > 1 ? $0 : nil }
                ?? .systemFont(ofSize: 13)
            let side = round(font.pointSize * 1.05)
            let x = location(forGlyphAt: glyph).x + fragment.minX
            // Centred on the text's x-height, not on the line box (the line spacing sits under the text).
            let baseline = fragment.minY + (typesetter.baselineOffset(in: self, glyphIndex: glyph))
            let box = CGRect(x: origin.x + x - side - round(font.pointSize * 0.5), y: origin.y + baseline - font.xHeight / 2 - side / 2,
                             width: side, height: side)
            _ = used
            let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
            if done {
                NSColor.controlAccentColor.setFill()
                path.fill()
                let check = NSBezierPath()
                check.move(to: CGPoint(x: box.minX + side * 0.26, y: box.midY + side * 0.02))
                check.line(to: CGPoint(x: box.minX + side * 0.44, y: box.minY + side * 0.72))
                check.line(to: CGPoint(x: box.minX + side * 0.76, y: box.minY + side * 0.28))
                check.lineWidth = 1.6
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                NSColor.white.setStroke()
                check.stroke()
            } else {
                NSColor.secondaryLabelColor.setStroke()
                path.lineWidth = 1.2
                path.stroke()
            }
            taskBoxes.append((box.offsetBy(dx: -origin.x, dy: -origin.y), range.location))
        }
    }
}

// MARK: - Text view

/// The editing behaviour of a Markdown editor: lists continue on Return, Tab nests them, task boxes toggle on
/// click, ⌘B / ⌘I / ⌘K wrap the selection, links open with a click on lines not being edited.
final class MarkdownTextView: NSTextView {
    var onFocusChange: (Bool) -> Void = { _ in }
    /// Keeps the text this wide at most and centres it (a document window); 0: use the full width.
    var readableWidth: CGFloat = 0 { didSet { updateInsets() } }
    var verticalInset: CGFloat = 8 { didSet { updateInsets() } }
    var horizontalInset: CGFloat = 4 { didSet { updateInsets() } }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateInsets()
    }

    private func updateInsets() {
        var horizontal = horizontalInset
        if readableWidth > 0 { horizontal = max(horizontalInset, (bounds.width - readableWidth) / 2) }
        let inset = NSSize(width: floor(horizontal), height: verticalInset)
        if textContainerInset != inset { textContainerInset = inset }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange(false) }
        return accepted
    }

    private var nsString: NSString { string as NSString }

    override func mouseDown(with event: NSEvent) {
        if let layout = layoutManager as? MarkdownLayoutManager {
            let point = convert(event.locationInWindow, from: nil)
            let local = CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
            if let hit = layout.taskBoxes.first(where: { $0.rect.insetBy(dx: -4, dy: -4).contains(local) }) {
                toggleTask(at: hit.location)
                return
            }
        }
        super.mouseDown(with: event)
    }

    private static let taskPattern = try! NSRegularExpression(pattern: #"^([ \t]*(?:>[ \t]?)*[ \t]*[-*+][ \t]+\[)([ xX])(\])"#)

    func toggleTask(at location: Int) {
        let line = nsString.paragraphRange(for: NSRange(location: min(location, nsString.length), length: 0))
        guard let match = Self.taskPattern.firstMatch(in: string, range: line) else { return }
        let mark = match.range(at: 2)
        let done = nsString.substring(with: mark) != " "
        replace(mark, with: done ? " " : "x")
    }

    /// An undoable edit, as if typed.
    func replace(_ range: NSRange, with text: String) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
    }

    private static let listPattern = try! NSRegularExpression(pattern: #"^([ \t]*(?:>[ \t]?)*[ \t]*)(?:([-*+])([ \t]+\[[ xX]\])?|(\d{1,9})([.)]))([ \t]+)"#)
    private static let quotePattern = try! NSRegularExpression(pattern: #"^([ \t]*(?:>[ \t]?)+)"#)

    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText(), selectedRange().length == 0 else { return super.insertNewline(sender) }
        let caret = selectedRange().location
        let line = nsString.paragraphRange(for: NSRange(location: caret, length: 0))
        var content = line
        if content.length > 0, nsString.character(at: NSMaxRange(content) - 1) == 10 { content.length -= 1 }
        // Inside a code block Return keeps the indentation and nothing else.
        if MarkdownStyler.codeBlocks(in: nsString).contains(where: { NSLocationInRange(caret, $0) && $0.location != line.location }) {
            let indent = (nsString.substring(with: content) as NSString).range(of: #"^[ \t]*"#, options: .regularExpression)
            super.insertNewline(sender)
            if indent.length > 0 { insertText((nsString.substring(with: content) as NSString).substring(with: indent), replacementRange: selectedRange()) }
            return
        }
        guard caret > content.location || content.length == 0 else { return super.insertNewline(sender) }
        if let match = Self.listPattern.firstMatch(in: string, range: content) {
            let marker = NSRange(location: match.range.location, length: match.range.length)
            // An empty item ends the list (Return on "- " leaves an empty line).
            if NSMaxRange(marker) >= NSMaxRange(content) {
                replace(marker, with: "")
                return
            }
            guard caret >= NSMaxRange(marker) else { return super.insertNewline(sender) }
            let lead = nsString.substring(with: match.range(at: 1))
            let spacing = nsString.substring(with: match.range(at: 6))
            var next: String
            if match.range(at: 2).location != NSNotFound {
                next = lead + nsString.substring(with: match.range(at: 2)) + (match.range(at: 3).location != NSNotFound ? " [ ]" : "") + spacing
            } else {
                let number = (Int(nsString.substring(with: match.range(at: 4))) ?? 0) + 1
                next = lead + "\(number)" + nsString.substring(with: match.range(at: 5)) + spacing
            }
            insertText("\n" + next, replacementRange: selectedRange())
            return
        }
        if let match = Self.quotePattern.firstMatch(in: string, range: content) {
            if NSMaxRange(match.range) >= NSMaxRange(content) {
                replace(match.range, with: "")
                return
            }
            insertText("\n" + nsString.substring(with: match.range), replacementRange: selectedRange())
            return
        }
        super.insertNewline(sender)
    }

    override func insertTab(_ sender: Any?) {
        guard !hasMarkedText(), indentListLines(by: 1) else { return super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        guard !hasMarkedText(), indentListLines(by: -1) else { return super.insertBacktab(sender) }
    }

    /// Nests (or un-nests) the list items the selection touches. False when it touches none.
    private func indentListLines(by step: Int) -> Bool {
        let lines = nsString.paragraphRange(for: selectedRange())
        var starts: [Int] = []
        nsString.enumerateSubstrings(in: lines, options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in starts.append(range.location) }
        let listStarts = starts.filter { start in
            let line = nsString.paragraphRange(for: NSRange(location: start, length: 0))
            return Self.listPattern.firstMatch(in: string, range: line) != nil
        }
        guard !listStarts.isEmpty, listStarts.count == starts.count else { return false }
        let selection = selectedRange()
        var shift = 0, firstShift = 0
        breakUndoCoalescing()
        for (k, start) in listStarts.enumerated() {
            let location = start + shift
            if step > 0 {
                replace(NSRange(location: location, length: 0), with: "  ")
                shift += 2
                if k == 0 { firstShift = 2 }
            } else {
                let available = nsString.substring(with: NSRange(location: location, length: min(2, nsString.length - location)))
                let remove = available.prefix { $0 == " " }.count
                guard remove > 0 else { continue }
                replace(NSRange(location: location, length: remove), with: "")
                shift -= remove
                if k == 0 { firstShift = -remove }
            }
        }
        setSelectedRange(NSRange(location: max(selection.location + firstShift, 0), length: max(selection.length + shift - firstShift, 0)))
        return true
    }

    /// Wraps the selection in `marker` (or unwraps it); with nothing selected, puts the caret between a pair.
    func toggleWrap(_ marker: String) {
        let range = selectedRange()
        let m = (marker as NSString).length
        let selected = nsString.substring(with: range)
        if selected.hasPrefix(marker), selected.hasSuffix(marker), (selected as NSString).length >= 2 * m {
            replace(range, with: String(selected.dropFirst(marker.count).dropLast(marker.count)))
            setSelectedRange(NSRange(location: range.location, length: range.length - 2 * m))
            return
        }
        if range.location >= m, NSMaxRange(range) + m <= nsString.length,
           nsString.substring(with: NSRange(location: range.location - m, length: m)) == marker,
           nsString.substring(with: NSRange(location: NSMaxRange(range), length: m)) == marker {
            replace(NSRange(location: NSMaxRange(range), length: m), with: "")
            replace(NSRange(location: range.location - m, length: m), with: "")
            setSelectedRange(NSRange(location: range.location - m, length: range.length))
            return
        }
        replace(range, with: marker + selected + marker)
        setSelectedRange(NSRange(location: range.location + m, length: range.length))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "b": toggleWrap("**"); return true
        case "i": toggleWrap("*"); return true
        case "k":
            insertLink()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    // MARK: Formatting (the document toolbar)

    /// `[text](https://)` around the selection, the address selected (or the caret in the brackets).
    func insertLink() {
        let range = selectedRange()
        let text = nsString.substring(with: range)
        replace(range, with: "[\(text)](https://)")
        let urlStart = range.location + (text as NSString).length + 3
        setSelectedRange(text.isEmpty ? NSRange(location: range.location + 1, length: 0) : NSRange(location: urlStart, length: 8))
    }

    /// The lines the selection touches, without their line breaks, and the range they span.
    private func selectedLines() -> (range: NSRange, lines: [String]) {
        var range = nsString.paragraphRange(for: selectedRange())
        if range.length > 0, nsString.character(at: NSMaxRange(range) - 1) == 10 { range.length -= 1 }
        return (range, nsString.substring(with: range).components(separatedBy: "\n"))
    }

    private func replaceLines(_ range: NSRange, with lines: [String]) {
        let text = lines.joined(separator: "\n")
        breakUndoCoalescing()
        replace(range, with: text)
        setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
        window?.makeFirstResponder(self)
    }

    /// 标题 1–3 for the lines touched; the same level again makes them plain text (0: plain text).
    func toggleHeading(_ level: Int) {
        let (range, lines) = selectedLines()
        let pattern = try! NSRegularExpression(pattern: #"^#{1,6}[ \t]+"#)
        let marker = String(repeating: "#", count: level) + " "
        let all = level > 0 && lines.allSatisfy { $0.hasPrefix(marker) }
        replaceLines(range, with: lines.map { line in
            let body = pattern.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length), withTemplate: "")
            return all || level == 0 ? body : marker + body
        })
    }

    enum LineStyle { case bullet, numbered, task, quote }

    /// Makes the lines touched a list, a task list or a quote (or plain lines again, when they all are one already).
    func toggleLineStyle(_ style: LineStyle) {
        let (range, lines) = selectedLines()
        let list = try! NSRegularExpression(pattern: #"^([ \t]*)(?:[-*+][ \t]+\[[ xX]\][ \t]+|[-*+][ \t]+|\d{1,9}[.)][ \t]+)"#)
        let quote = try! NSRegularExpression(pattern: #"^[ \t]*>[ \t]?"#)
        func matches(_ regex: NSRegularExpression, _ line: String) -> Bool {
            regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
        }
        func strip(_ regex: NSRegularExpression, _ line: String) -> String {
            regex.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length), withTemplate: "$1")
        }
        let already: Bool = switch style {
        case .bullet: lines.allSatisfy { $0.range(of: #"^[ \t]*[-*+][ \t]+(?!\[[ xX]\])"#, options: .regularExpression) != nil }
        case .numbered: lines.allSatisfy { $0.range(of: #"^[ \t]*\d{1,9}[.)][ \t]+"#, options: .regularExpression) != nil }
        case .task: lines.allSatisfy { $0.range(of: #"^[ \t]*[-*+][ \t]+\[[ xX]\]"#, options: .regularExpression) != nil }
        case .quote: lines.allSatisfy { matches(quote, $0) }
        }
        var number = 0
        replaceLines(range, with: lines.map { line in
            if style == .quote {
                let body = quote.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length), withTemplate: "")
                return already ? body : "> " + body
            }
            let body = strip(list, line)
            if already { return body }
            let indent = String(body.prefix { $0 == " " || $0 == "\t" })
            let text = String(body.dropFirst(indent.count))
            number += 1
            switch style {
            case .bullet: return indent + "- " + text
            case .numbered: return indent + "\(number). " + text
            default: return indent + "- [ ] " + text
            }
        })
    }

    /// A fenced code block around the lines touched (an empty one at the caret).
    func insertCodeBlock() {
        if selectedRange().length == 0 {
            insertBlock("```\n\n```", caretOffset: 4)
        } else {
            let (range, lines) = selectedLines()
            replaceLines(range, with: ["```"] + lines + ["```"])
        }
    }

    /// Inserts a block (a rule, a table) on lines of its own after the caret's line.
    func insertBlock(_ block: String, caretOffset: Int? = nil) {
        var line = nsString.paragraphRange(for: selectedRange())
        if line.length > 0, nsString.character(at: NSMaxRange(line) - 1) == 10 { line.length -= 1 }
        let empty = nsString.substring(with: line).trimmingCharacters(in: .whitespaces).isEmpty
        let text = (empty ? "" : "\n\n") + block + "\n"
        let at = empty ? line.location : NSMaxRange(line)
        breakUndoCoalescing()
        replace(NSRange(location: at, length: empty ? line.length : 0), with: text)
        let start = at + (empty ? 0 : 2)
        setSelectedRange(NSRange(location: caretOffset.map { start + $0 } ?? at + (text as NSString).length, length: 0))
        window?.makeFirstResponder(self)
    }

    override func clicked(onLink link: Any, at charIndex: Int) {
        if let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Controller

/// Where a Markdown editor's text comes from and goes to: an item's note, or a .md file.
struct MarkdownSource {
    /// Identifies the document in change notifications.
    var key: String
    var load: () -> String
    var save: (String) -> Void
    /// Posted (object: `key`) after any editor saved it.
    var notification: Notification.Name
}

/// A live-preview Markdown editor: the text view, its styling, and saving 0.8 s after typing stops.
final class MarkdownEditorController: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    let scrollView = NSScrollView()
    let textView: MarkdownTextView
    private let layout = MarkdownLayoutManager()
    private(set) var styler: MarkdownStyler
    private var source: MarkdownSource?
    private var saveTask: Task<Void, Never>?
    private(set) var isDirty = false
    private var isLoading = false
    private var lastFocusRequest = 0
    private var pending: NSRange?
    private var codeBlocks: [NSRange] = []
    private var activeLines: NSRange?
    private var observedName: Notification.Name?

    init(fontSize: CGFloat = 13, placeholder: String = "") {
        styler = MarkdownStyler(fontSize: fontSize)
        let storage = NSTextStorage()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        textView = MarkdownTextView(frame: .zero, textContainer: container)
        super.init()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        textView.delegate = self
        storage.delegate = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = styler.bodyFont
        textView.textColor = .labelColor
        textView.typingAttributes = styler.baseAttributes
        textView.defaultParagraphStyle = styler.baseAttributes[.paragraphStyle] as? NSParagraphStyle
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        textView.onFocusChange = { [weak self] focused in self?.updateActiveLines(force: true, focused: focused) }
        textView.setAccessibilityIdentifier("noteEditor")
        textView.setAccessibilityLabel(String(localized: "笔记"))
        let attributed = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor.placeholderTextColor, .font: styler.bodyFont])
        if textView.responds(to: Selector(("setPlaceholderAttributedString:"))) {
            textView.setValue(attributed, forKey: "placeholderAttributedString")
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    var text: String { textView.string }

    /// Shows a document (saving the one shown before).
    func load(_ source: MarkdownSource) {
        guard source.key != self.source?.key else { return }
        saveNow()
        self.source = source
        if observedName != source.notification {
            if let observedName { NotificationCenter.default.removeObserver(self, name: observedName, object: nil) }
            NotificationCenter.default.addObserver(self, selector: #selector(documentDidChange(_:)), name: source.notification, object: nil)
            observedName = source.notification
        }
        reload(keepSelection: false)
        textView.undoManager?.removeAllActions()
        textView.scroll(.zero)
    }

    @objc private func documentDidChange(_ notification: Notification) {
        // Our own saves come back here too; only another editor's change (or an append from the reader) reloads.
        guard let key = notification.object as? String, key == source?.key,
              (notification.userInfo?["sender"] as? ObjectIdentifier) != ObjectIdentifier(self), !isDirty else { return }
        reload(keepSelection: true)
    }

    private func reload(keepSelection: Bool) {
        guard let source else { return }
        let text = source.load()
        guard text != textView.string else { return }
        isLoading = true
        let selection = textView.selectedRanges
        textView.string = text
        restyleAll()
        let length = (text as NSString).length
        let kept = selection.filter { $0.rangeValue.upperBound <= length }
        textView.selectedRanges = keepSelection && !kept.isEmpty ? kept : [NSValue(range: NSRange(location: keepSelection ? length : 0, length: 0))]
        isLoading = false
    }

    func focus(request: Int) {
        guard request != lastFocusRequest else { return }
        lastFocusRequest = request
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.textView.window?.makeFirstResponder(self.textView)
        }
    }

    // MARK: Styling

    private func restyleAll() {
        guard let storage = textView.textStorage else { return }
        codeBlocks = MarkdownStyler.codeBlocks(in: storage.string as NSString)
        activeLines = currentActiveLines()
        styler.style(storage, range: NSRange(location: 0, length: storage.length), active: activeLines, codeBlocks: codeBlocks)
        textView.typingAttributes = typingAttributes()
    }

    /// The paragraphs being edited: those the selection touches, while the editor has focus.
    private func currentActiveLines(focused: Bool? = nil) -> NSRange? {
        let isFocused = focused ?? (textView.window?.firstResponder === textView)
        guard isFocused else { return nil }
        let string = textView.string as NSString
        let selection = textView.selectedRange()
        guard selection.location <= string.length else { return nil }
        return string.paragraphRange(for: selection)
    }

    private func updateActiveLines(force: Bool = false, focused: Bool? = nil) {
        guard let storage = textView.textStorage, !textView.hasMarkedText() else { return }
        let new = currentActiveLines(focused: focused)
        guard force || new != activeLines else { return }
        let old = activeLines
        activeLines = new
        for range in [old, new].compactMap({ $0 }) where NSMaxRange(range) <= storage.length {
            styler.style(storage, range: range, active: new, codeBlocks: codeBlocks)
        }
        if old == nil, new == nil, force { styler.style(storage, range: NSRange(location: 0, length: storage.length), active: nil, codeBlocks: codeBlocks) }
        textView.typingAttributes = typingAttributes()
    }

    /// What new text looks like before styling catches up — and, while an input method composes, what the
    /// composition is drawn with: the look of the line the caret is on. A new empty line under a heading is body text
    /// (it used to take the heading's line break's style, with its space above, so the candidates sat lower than the
    /// committed text); inside a heading, typed text is heading-sized from the first character.
    private func typingAttributes() -> [NSAttributedString.Key: Any] {
        var attributes = styler.baseAttributes
        guard let storage = textView.textStorage, storage.length > 0 else { return attributes }
        let string = storage.string as NSString
        let caret = min(textView.selectedRange().location, storage.length)
        let line = string.paragraphRange(for: NSRange(location: caret, length: 0))
        var content = line
        while content.length > 0, let last = UnicodeScalar(string.character(at: NSMaxRange(content) - 1)),
              CharacterSet.newlines.contains(last) { content.length -= 1 }
        // An empty line (or the empty last line after a final line break): body text.
        guard content.length > 0, line.location < storage.length else { return attributes }
        // The character before the caret on this line, else the line's first one; syntax characters lend their
        // paragraph and size, not their colour or hiding.
        let at = caret > content.location ? min(caret - 1, NSMaxRange(content) - 1) : content.location
        var source = storage.attributes(at: at, effectiveRange: nil)
        if source[.mdHidden] != nil {
            // A hidden marker has a hair-thin font: take the size from the line's visible text instead.
            var visible: Int?
            storage.enumerateAttribute(.mdHidden, in: content) { value, range, stop in
                if value == nil { visible = range.location; stop.pointee = true }
            }
            if let visible { source = storage.attributes(at: visible, effectiveRange: nil) }
        }
        if let font = source[.font] as? NSFont, font.pointSize > 1 { attributes[.font] = font }
        if let style = source[.paragraphStyle] { attributes[.paragraphStyle] = style }
        return attributes
    }

    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            pending = pending.map { NSUnionRange($0, editedRange) } ?? editedRange
        }
    }

    func textDidChange(_ notification: Notification) {
        applyPendingStyle()
        guard !isLoading else { return }
        isDirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func applyPendingStyle() {
        guard let storage = textView.textStorage, let edited = pending else { return }
        // While an input method composes, its marked text keeps the look it has; styling follows the commit.
        guard !textView.hasMarkedText() else { return }
        pending = nil
        let string = storage.string as NSString
        let blocks = MarkdownStyler.codeBlocks(in: string)
        var range = NSRange(location: min(edited.location, storage.length), length: 0)
        range.length = min(NSMaxRange(edited), storage.length) - range.location
        if blocks != codeBlocks {
            // A fence opened or closed: everything after it may change.
            let first = zip(blocks, codeBlocks).first { $0 != $1 }.map { min($0.location, $1.location) }
                ?? min(blocks.last?.location ?? range.location, codeBlocks.last?.location ?? range.location, range.location)
            range = NSRange(location: min(first, range.location), length: storage.length - min(first, range.location))
        }
        codeBlocks = blocks
        // The line edited before (now left, perhaps) is styled again too, so its syntax hides.
        let previous = activeLines.map { NSRange(location: min($0.location, storage.length), length: 0) }
        activeLines = currentActiveLines()
        var union = activeLines.map { NSUnionRange($0, range) } ?? range
        if let previous { union = NSUnionRange(union, string.paragraphRange(for: previous)) }
        styler.style(storage, range: union, active: activeLines, codeBlocks: codeBlocks)
        textView.typingAttributes = typingAttributes()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isLoading else { return }
        if pending != nil { applyPendingStyle() }
        updateActiveLines()
    }

    func textDidEndEditing(_ notification: Notification) { saveNow() }

    func saveNow() {
        saveTask?.cancel()
        guard isDirty, let source else { return }
        isDirty = false
        source.save(textView.string)
        NotificationCenter.default.post(name: source.notification, object: source.key, userInfo: ["sender": ObjectIdentifier(self)])
    }
}
