import Foundation

/// What a line of a document (outside code blocks and tables) is: the symbols at its start, which are never drawn (a
/// bullet, a number, a box, a bar, a larger font stand for them), and where its text begins.
struct MarkdownLine {
    enum Kind: Equatable {
        case text, heading(Int), bullet, numbered(Int), task(Bool), rule
        /// A further line of a list item, indented under it.
        case continuation
        var isList: Bool { switch self { case .bullet, .numbered, .task: true; default: false } }
    }

    /// The line without its line break.
    var content: NSRange
    var kind: Kind = .text
    var quoteDepth = 0
    /// The length of the quote's own symbols ("> ").
    var quoteLength = 0
    /// Columns before the list marker.
    var indent = 0
    /// Where the list marker ("-", "1.") is.
    var marker = NSRange(location: 0, length: 0)
    /// Where the text begins.
    var textStart: Int

    var prefix: NSRange { NSRange(location: content.location, length: textStart - content.location) }
    var isEmpty: Bool { textStart >= NSMaxRange(content) }
    /// Columns what is nested under this item is indented by.
    var childIndent: Int {
        if case .numbered(let number) = kind { return indent + "\(number)".count + 2 }
        return indent + 2
    }

    private static let rule = try! NSRegularExpression(pattern: #"^ {0,3}([-*_])([ \t]*\1){2,}[ \t]*$"#)
    private static let quote = try! NSRegularExpression(pattern: #"^[ \t]{0,3}(?:>[ \t]?)+"#)
    private static let heading = try! NSRegularExpression(pattern: #"^(#{1,6})[ \t]+"#)
    private static let task = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+])[ \t]+\[([ xX])\](?:[ \t]+|$)"#)
    private static let bullet = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+])[ \t]+"#)
    private static let ordered = try! NSRegularExpression(pattern: #"^([ \t]*)((\d{1,9})[.)])[ \t]+"#)

    static func columns(_ whitespace: String) -> Int { whitespace.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } }

    /// The line around `location`.
    init(in string: NSString, at location: Int) {
        let line = string.paragraphRange(for: NSRange(location: min(location, string.length), length: 0))
        var content = line
        while content.length > 0, [10, 13].contains(string.character(at: NSMaxRange(content) - 1)) { content.length -= 1 }
        self.content = content
        textStart = content.location
        guard content.length > 0 else { return }
        let text = string.substring(with: content) as NSString
        let whole = NSRange(location: 0, length: text.length)
        if Self.rule.firstMatch(in: text as String, range: whole) != nil { kind = .rule; return }
        var start = 0
        if let match = Self.quote.firstMatch(in: text as String, range: whole) {
            quoteLength = match.range.length
            quoteDepth = text.substring(with: match.range).filter { $0 == ">" }.count
            start = match.range.length
        }
        let rest = text.substring(from: start)
        let span = NSRange(location: 0, length: (rest as NSString).length)
        func take(_ match: NSTextCheckingResult, _ found: Kind) {
            kind = found
            if found.isList {
                indent = Self.columns((rest as NSString).substring(with: match.range(at: 1)))
                marker = NSRange(location: content.location + start + match.range(at: 2).location, length: match.range(at: 2).length)
            }
            textStart = content.location + start + match.range.length
        }
        textStart = content.location + start
        if let match = Self.heading.firstMatch(in: rest, range: span) { take(match, .heading(match.range(at: 1).length)) }
        else if let match = Self.task.firstMatch(in: rest, range: span) { take(match, .task((rest as NSString).substring(with: match.range(at: 3)) != " ")) }
        else if let match = Self.bullet.firstMatch(in: rest, range: span) { take(match, .bullet) }
        else if let match = Self.ordered.firstMatch(in: rest, range: span) { take(match, .numbered(Int((rest as NSString).substring(with: match.range(at: 3))) ?? 1)) }
        else {
            let white = rest.prefix { $0 == " " || $0 == "\t" }
            let columns = Self.columns(String(white))
            // A line that is only indented so far is one too, where what is written on it will be: as deep as the item's text.
            let blank = rest.trimmingCharacters(in: .whitespaces).isEmpty
            if columns >= 2, let above = Self.item(above: line.location, in: string, indentedUnder: columns, depth: quoteDepth), !blank || columns == above.childIndent {
                kind = .continuation
                indent = above.indent
                marker = above.marker
                textStart += (String(white) as NSString).length
            }
        }
    }

    /// The item a line indented by `columns` belongs to.
    static func item(above location: Int, in string: NSString, indentedUnder columns: Int, depth: Int) -> MarkdownLine? {
        var at = location
        for _ in 0..<200 where at > 0 {
            let line = string.paragraphRange(for: NSRange(location: at - 1, length: 0))
            let text = string.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || text.hasPrefix("#") { return nil }
            let plain = MarkdownLine(plain: string, line: line)
            if plain.quoteDepth != depth { return nil }
            if plain.kind.isList, plain.indent < columns { return plain }
            if !plain.kind.isList, plain.indent < 2 { return nil }
            at = line.location
        }
        return nil
    }

    /// As `init(in:at:)`, without looking at the lines above (a further line of an item is plain text, its indent told).
    private init(plain string: NSString, line: NSRange) {
        let text = string.substring(with: line)
        let own = MarkdownLine(in: text as NSString, at: 0)
        self = own
        content.location += line.location
        textStart += line.location
        marker.location += line.location
        if !own.kind.isList { indent = Self.columns(String(text.prefix { $0 == " " || $0 == "\t" })) }
    }

    /// How deep the item is nested: the items above it that it is indented under.
    static func level(of item: MarkdownLine, in string: NSString) -> Int {
        var level = 0, current = item.indent, at = item.content.location, blanks = 0
        for _ in 0..<400 where at > 0 && current > 0 {
            let line = string.paragraphRange(for: NSRange(location: at - 1, length: 0))
            at = line.location
            let text = string.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { blanks += 1; if blanks > 1 { break }; continue }
            blanks = 0
            let above = MarkdownLine(plain: string, line: line)
            if above.quoteDepth != item.quoteDepth { break }
            if above.kind.isList {
                if above.indent < current { level += 1; current = above.indent }
            } else if above.indent < 2 { break }
        }
        return level
    }

    /// The lines of the list around `location`: up to a blank line, a heading or plain text.
    static func list(around location: Int, in string: NSString) -> NSRange {
        var range = string.paragraphRange(for: NSRange(location: min(location, string.length), length: 0))
        func belongs(_ line: NSRange) -> Bool {
            let found = MarkdownLine(in: string, at: line.location)
            return found.kind.isList || found.kind == .continuation
        }
        guard belongs(range) else { return range }
        while range.location > 0 {
            let above = string.paragraphRange(for: NSRange(location: range.location - 1, length: 0))
            guard belongs(above) else { break }
            range = NSUnionRange(above, range)
        }
        while NSMaxRange(range) < string.length {
            let below = string.paragraphRange(for: NSRange(location: NSMaxRange(range), length: 0))
            guard below.length > 0, belongs(below) else { break }
            range = NSUnionRange(range, below)
        }
        return range
    }
}

/// A fenced code block.
struct MarkdownCode: Equatable {
    /// The fences and the lines between.
    var range: NSRange
    var open: NSRange
    /// The closing fence's line (nil: the block was never closed).
    var close: NSRange?
    /// What follows the opening fence: the language.
    var info: String

    var isClosed: Bool { close != nil }
    /// The code, with the line break before the closing fence.
    var body: NSRange {
        let start = NSMaxRange(open)
        return NSRange(location: start, length: max((close?.location ?? NSMaxRange(range)) - start, 0))
    }
    /// The code without its final line break.
    var text: NSRange { NSRange(location: body.location, length: max(body.length - (isClosed ? 1 : 0), 0)) }

    static func all(in string: NSString) -> [MarkdownCode] {
        // The fence decides; most documents have none.
        guard string.range(of: "```").location != NSNotFound || string.range(of: "~~~").location != NSNotFound else { return [] }
        var blocks: [MarkdownCode] = []
        var open: NSRange?
        var fence = "", info = ""
        var location = 0
        while location < string.length {
            let line = string.paragraphRange(for: NSRange(location: location, length: 0))
            let text = string.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if let start = open {
                if text.hasPrefix(fence), text.allSatisfy({ $0 == fence.first }) {
                    blocks.append(MarkdownCode(range: NSUnionRange(start, line), open: start, close: line, info: info))
                    open = nil
                }
            } else if text.hasPrefix("```") || text.hasPrefix("~~~") {
                fence = String(text.prefix { $0 == text.first })
                info = text.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
                // "```code```" in a line is inline code.
                if !info.contains("`") { open = line }
            }
            location = NSMaxRange(line)
            if line.length == 0 { break }
        }
        if let open { blocks.append(MarkdownCode(range: NSRange(location: open.location, length: string.length - open.location), open: open, close: nil, info: info)) }
        return blocks
    }

    /// The language: the one its info string names, else the one its code looks like.
    @MainActor func language(in string: NSString) -> (id: String?, isDetected: Bool) {
        if !info.isEmpty { return (CodeHighlighter.shared.resolve(info), false) }
        return (CodeHighlighter.shared.detect(string.substring(with: text)), true)
    }
}

/// A table: its rows of cells, as Markdown holds them.
struct MarkdownTable: Equatable {
    enum Alignment: Equatable { case none, left, center, right }
    var rows: [[String]]
    var alignments: [Alignment]

    var columns: Int { alignments.count }

    private static let delimiter = try! NSRegularExpression(pattern: #"^[ \t]*\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$"#)

    /// The tables of a document, with the lines they take (with their line breaks).
    static func all(in string: NSString, outside code: [MarkdownCode]) -> [(range: NSRange, table: MarkdownTable)] {
        guard string.range(of: "|").location != NSNotFound else { return [] }
        var lines: [(NSRange, String)] = []
        var location = 0
        while location < string.length {
            let line = string.paragraphRange(for: NSRange(location: location, length: 0))
            lines.append((line, string.substring(with: line).trimmingCharacters(in: .newlines)))
            location = NSMaxRange(line)
        }
        var found: [(NSRange, MarkdownTable)] = []
        var index = 0
        while index + 1 < lines.count {
            let (line, header) = lines[index], (_, rule) = lines[index + 1]
            guard header.contains("|"), rule.contains("-"), rule.contains("|"),
                  delimiter.firstMatch(in: rule, range: NSRange(location: 0, length: (rule as NSString).length)) != nil,
                  !code.contains(where: { NSLocationInRange(line.location, $0.range) }),
                  MarkdownLine(in: string, at: line.location).prefix.length == 0 else { index += 1; continue }
            let head = cells(header), marks = cells(rule)
            guard head.count == marks.count else { index += 1; continue }
            let alignments = marks.map { mark -> Alignment in
                switch (mark.hasPrefix(":"), mark.hasSuffix(":")) {
                case (true, true): .center
                case (true, false): .left
                case (false, true): .right
                default: .none
                }
            }
            var rows = [head], range = NSUnionRange(line, lines[index + 1].0), next = index + 2
            while next < lines.count, lines[next].1.contains("|"), !code.contains(where: { NSLocationInRange(lines[next].0.location, $0.range) }),
                  MarkdownLine(in: string, at: lines[next].0.location).prefix.length == 0 {
                var row = Array(cells(lines[next].1).prefix(head.count))
                while row.count < head.count { row.append("") }
                rows.append(row)
                range = NSUnionRange(range, lines[next].0)
                next += 1
            }
            found.append((range, MarkdownTable(rows: rows, alignments: alignments)))
            index = next
        }
        return found
    }

    /// The cells of a line, as they read ("\|" a bar, `<br>` a line break).
    static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
        var cells = [""], escaped = false
        for character in text {
            if escaped {
                cells[cells.count - 1] += character == "|" ? "|" : "\\" + String(character)
                escaped = false
            } else if character == "\\" { escaped = true }
            else if character == "|" { cells.append("") }
            else { cells[cells.count - 1].append(character) }
        }
        if escaped { cells[cells.count - 1] += "\\" }
        return cells.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive]) }
    }

    static func escape(_ cell: String) -> String {
        cell.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>")
    }

    /// Its Markdown, without a final line break.
    var markdown: String {
        func line(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |" }
        let rule = alignments.map { alignment in
            switch alignment {
            case .none: "---"
            case .left: ":---"
            case .center: ":---:"
            case .right: "---:"
            }
        }
        var lines = rows.map { line($0.map(Self.escape)) }
        lines.insert(line(rule), at: min(1, lines.count))
        return lines.joined(separator: "\n")
    }
}
