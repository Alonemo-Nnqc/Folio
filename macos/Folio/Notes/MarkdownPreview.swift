import AppKit
import FolioCore
import Quartz

/// A Markdown document or note as Quick Look shows it: set as in the editor, read-only. The system's own Quick Look has no
/// preview of Markdown.
final class MarkdownPreviewItem: NSObject, QLPreviewItem {
    let url: URL
    let title: String

    private init(url: URL, title: String) { self.url = url; self.title = title }

    nonisolated var previewItemURL: URL! { url }
    nonisolated var previewItemTitle: String! { title }

    private static let folder = FileManager.default.temporaryDirectory.appending(path: "FolioPreview", directoryHint: .isDirectory)
    private static var made: [String: (text: String, item: MarkdownPreviewItem, preferences: MarkdownPreferences)] = [:]
    private static var count = 0

    /// `key`: the file's or the item's id. `base`: where pictures named in the text are.
    static func item(key: String, title: String, text: String, base: URL?) -> MarkdownPreviewItem? {
        if let known = made[key], known.text == text, known.item.title == title, known.preferences == .current { return known.item }
        // Another address for another text: Quick Look remembers what it drew.
        let url = folder.appending(path: "\(key)-\(count).html")
        count += 1
        do {
            if made.isEmpty { try? FileManager.default.removeItem(at: folder) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(MarkdownHTML.page(text, title: title, base: base).utf8).write(to: url)
        } catch { return nil }
        let item = MarkdownPreviewItem(url: url, title: title)
        made[key] = (text, item, .current)
        return item
    }
}

/// Markdown as HTML, line by line as the editor sets it (a line break is a line break, a quote ends where its symbol does).
enum MarkdownHTML {
    static func page(_ text: String, title: String, base: URL? = nil) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark"><title>\(escape(title))</title>
        <style>\(css())</style></head><body><main>\(body(text, base: base))</main></body></html>
        """
    }

    // MARK: Lines

    static func body(_ source: String, base: URL? = nil) -> String {
        let text = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") as NSString
        let codes = MarkdownCode.all(in: text), tables = MarkdownTable.all(in: text, outside: codes)
        var html = "", quotes = 0, location = 0
        func quote(_ depth: Int) {
            if depth > quotes { html += String(repeating: "<blockquote>", count: depth - quotes) }
            if depth < quotes { html += String(repeating: "</blockquote>", count: quotes - depth) }
            quotes = depth
        }
        while location < text.length {
            if let code = codes.first(where: { $0.range.location == location }) {
                quote(0)
                html += self.code(code, in: text)
                location = NSMaxRange(code.range)
                continue
            }
            if let table = tables.first(where: { $0.range.location == location }) {
                quote(0)
                html += self.table(table.table, base)
                location = NSMaxRange(table.range)
                continue
            }
            let line = MarkdownLine(in: text, at: location)
            let content = inline(text.substring(with: NSRange(location: line.textStart, length: max(NSMaxRange(line.content) - line.textStart, 0))), base)
            quote(line.kind == .rule ? 0 : line.quoteDepth)
            switch line.kind {
            case .rule: html += "<hr>"
            case .heading(let level): html += "<h\(level)>\(content)</h\(level)>"
            case .bullet, .numbered, .task, .continuation:
                let level = MarkdownLine.level(of: line, in: text)
                var mark = "", kind = ""
                switch line.kind {
                case .bullet: mark = ["•", "◦", "▪"][level % 3]
                case .numbered: mark = escape(text.substring(with: line.marker))
                case .task(let done): mark = done ? "☑" : "☐"; kind = done ? " done" : ""
                default: break
                }
                html += "<div class=\"item\(kind)\" style=\"--level:\(level)\"><span class=\"mark\">\(mark)</span><span>\(content)</span></div>"
            case .text: html += content.trimmingCharacters(in: .whitespaces).isEmpty ? "<div class=\"blank\"></div>" : "<p>\(content)</p>"
            }
            let next = NSMaxRange(text.paragraphRange(for: NSRange(location: location, length: 0)))
            if next <= location { break }
            location = next
        }
        quote(0)
        return html
    }

    private static func code(_ code: MarkdownCode, in text: NSString) -> String {
        let source = code.isClosed ? text.substring(with: code.text) : text.substring(with: code.body)
        var html = ""
        if let language = code.language(in: text).id {
            let string = source as NSString
            var at = 0
            for token in CodeHighlighter.shared.tokens(source, language: language) where token.range.location >= at && NSMaxRange(token.range) <= string.length {
                html += escape(string.substring(with: NSRange(location: at, length: token.range.location - at)))
                html += "<span class=\"t-\(escape(token.kind))\">\(escape(string.substring(with: token.range)))</span>"
                at = NSMaxRange(token.range)
            }
            html += escape(string.substring(from: at))
        } else { html = escape(source) }
        return "<pre><code>\(html)</code></pre>"
    }

    private static func table(_ table: MarkdownTable, _ base: URL?) -> String {
        func row(_ cells: [String], _ tag: String) -> String {
            "<tr>" + zip(cells, table.alignments).map { cell, alignment in
                let style = switch alignment { case .none: ""; case .left: " style=\"text-align:left\""; case .center: " style=\"text-align:center\""; case .right: " style=\"text-align:right\"" }
                return "<\(tag)\(style)>\(cell.components(separatedBy: "\n").map { inline($0, base) }.joined(separator: "<br>"))</\(tag)>"
            }.joined() + "</tr>"
        }
        guard let head = table.rows.first else { return "" }
        return "<div class=\"table\"><table><thead>\(row(head, "th"))</thead><tbody>\(table.rows.dropFirst().map { row($0, "td") }.joined())</tbody></table></div>"
    }

    // MARK: In a line

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// What is settled stands as a character of its own (a private one) while the rest is looked at.
    static func inline(_ source: String, _ base: URL? = nil) -> String {
        var kept: [String] = []
        func keep(_ html: String) -> String {
            guard let scalar = Unicode.Scalar(0xF0000 + kept.count), kept.count < 60_000 else { return html }
            kept.append(html)
            return String(Character(scalar))
        }
        func each(_ pattern: String, in text: String, _ replace: ([String]) -> String) -> String {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
            let string = text as NSString
            var result = "", at = 0
            for match in regex.matches(in: text, range: NSRange(location: 0, length: string.length)) {
                result += string.substring(with: NSRange(location: at, length: match.range.location - at))
                result += replace((0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : string.substring(with: match.range(at: $0)) })
                at = NSMaxRange(match.range)
            }
            return result + string.substring(from: at)
        }
        func emphasis(_ text: String) -> String {
            var html = escape(text)
            html = each(#"(\*\*\*)(?=[^\s*])(.+?)(?<=[^\s*])\1(?!\*)"#, in: html) { "<strong><em>\($0[2])</em></strong>" }
            html = each(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, in: html) { "<strong>\($0[2])</strong>" }
            html = each(#"(?<!\*)(\*)(?=[^\s*])([^*\n]+?)(?<=[^\s*])\1(?!\*)"#, in: html) { "<em>\($0[2])</em>" }
            html = each(#"(?<![_\p{L}\p{N}])(_)(?=[^\s_])(.+?)(?<=[^\s_])\1(?![_\p{L}\p{N}])"#, in: html) { "<em>\($0[2])</em>" }
            html = each(#"(~~)(?=\S)(.+?)(?<=\S)\1"#, in: html) { "<del>\($0[2])</del>" }
            return each(#"(==)(?=\S)(.+?)(?<=\S)\1"#, in: html) { "<mark>\($0[2])</mark>" }
        }
        func link(_ target: String, _ shown: String) -> String {
            let safe = ["http", "https", "mailto", "folio"].contains(URL(string: target)?.scheme?.lowercased() ?? "")
            return safe ? keep("<a href=\"\(escape(target))\">") + shown + keep("</a>") : shown
        }
        var text = String(String.UnicodeScalarView(source.unicodeScalars.filter { !(0xF0000...0xFFFFF).contains($0.value) }))
        text = each(#"(`+)(?!`)(.+?)(?<!`)\1(?!`)"#, in: text) { keep("<code>\(escape($0[2].trimmingCharacters(in: .whitespaces)))</code>") }
        text = each(#"\\([\\`*_{}\[\]()#+\-.!~=|>])"#, in: text) { keep(escape($0[1])) }
        text = each(#"(!\[)([^\]\n]*)(\]\(([^)\s]+)(?:[ \t]+"[^"\n]*")?\))"#, in: text) { parts in
            if let image = picture(parts[4], base) { return keep("<img src=\"\(image)\" alt=\"\(escape(parts[2]))\">") }
            return link(parts[4], parts[2].isEmpty ? parts[4] : parts[2])
        }
        text = each(#"(?<!!)(\[)([^\]\n]+)(\]\(([^)\s]+)(?:[ \t]+"[^"\n]*")?\))"#, in: text) { link($0[4], $0[2]) }
        text = each(#"(<)?(https?://[^\s<>()，。、；：！？（）《》「」“”\x{F0000}-\x{FFFFF}]*[^\s<>().,;:!?'"\]，。、；：！？（）《》「」“”\x{F0000}-\x{FFFFF}])(>)?"#, in: text) { link($0[2], keep(escape($0[2]))) }
        text = each(#"(?i)<br\s*/?>"#, in: text) { _ in keep("<br>") }
        let html = emphasis(text)
        // A piece may hold others (the code in a link's words does not: those are beside it).
        var result = String.UnicodeScalarView()
        for scalar in html.unicodeScalars {
            let index = Int(scalar.value) - 0xF0000
            if kept.indices.contains(index) { result.append(contentsOf: kept[index].unicodeScalars) } else { result.append(scalar) }
        }
        return String(result)
    }

    /// A picture beside the document, in the page itself (Quick Look loads nothing else).
    private static func picture(_ path: String, _ base: URL?) -> String? {
        let types = ["png": "png", "jpg": "jpeg", "jpeg": "jpeg", "gif": "gif", "webp": "webp", "svg": "svg+xml"]
        guard !path.contains("://"), let base, let type = types[(path as NSString).pathExtension.lowercased()] else { return nil }
        let url = URL(fileURLWithPath: path.removingPercentEncoding ?? path, relativeTo: base)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 20_000_000, let data = try? Data(contentsOf: url) else { return nil }
        return "data:image/\(type);base64,\(data.base64EncodedString())"
    }

    // MARK: The look

    private static func hex(_ color: NSColor, dark: Bool) -> String {
        var result = ""
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB) ?? .gray
            result = String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
        }
        return result
    }

    private static func tokens(_ dark: Bool) -> String {
        let kinds = ["keyword", "doctag", "selector-tag", "template-tag", "name", "tag", "string", "regexp", "char", "addition", "quote", "number", "literal", "symbol",
                     "bullet", "link", "comment", "deletion", "title", "section", "function", "built_in", "type", "class", "selector-class", "selector-id", "attr",
                     "attribute", "variable", "template-variable", "property", "meta"]
        return kinds.compactMap { kind in CodeHighlighter.color(of: kind).map { ".t-\(kind){color:\(hex($0, dark: dark))}" } }.joined()
    }

    private static func css() -> String {
        let p = MarkdownPreferences.current, styler = MarkdownStyler(fontSize: p.fontSize, preferences: p)
        let face = switch p.typeface { case .system: "-apple-system"; case .serif: "ui-serif"; case .rounded: "ui-rounded"; case .mono: "ui-monospace" }
        let headings = (1...4).map { "h\($0){font-size:\(Int(styler.headingFont($0).pointSize))px}" }.joined()
        return """
        :root{--text:#1d1d1f;--soft:#6e6e73;--line:rgba(0,0,0,.12);--fill:rgba(0,0,0,.045);--back:#fff;--link:#0a66d8;--code:\(hex(MarkdownStyler.codeColor, dark: false));--mark:rgba(255,214,10,.4)}
        *{box-sizing:border-box}html{background:var(--back)}
        body{margin:0;color:var(--text);font:\(p.fontSize)px/\(p.lineHeight) \(face),-apple-system,"PingFang SC",sans-serif;-webkit-font-smoothing:antialiased;overflow-wrap:break-word}
        main{max-width:\(p.readableWidth > 0 ? "\(Int(p.readableWidth) + 80)px" : "none");margin:0 auto;padding:36px 40px 56px}
        p{margin:0 0 \(p.paragraphSpacing)em}.blank{height:.8em}
        h1,h2,h3,h4,h5,h6{margin:.9em 0 .4em;line-height:1.3;font-weight:600}h1:first-child,h2:first-child,h3:first-child{margin-top:0}
        \(headings)h5,h6{font-size:1em}h1,h2{font-weight:700}
        blockquote{margin:.35em 0;padding:.05em 0 .05em 14px;border-left:3px solid var(--line);color:var(--soft)}blockquote>:last-child{margin-bottom:0}
        .item{display:flex;margin:0 0 \(p.paragraphSpacing * 0.5)em;padding-left:calc(var(--level)*1.65em)}.item>.mark{flex:none;width:1.65em;padding-right:.55em;text-align:right;color:var(--soft);white-space:nowrap}.item>span:last-child{min-width:0}
        .done>span:last-child{color:var(--soft);text-decoration:\(p.strikesDone ? "line-through" : "none")}
        hr{border:0;border-top:1px solid var(--line);margin:1.4em 0}
        code{font:\(p.codeScale)em ui-monospace,"SF Mono",Menlo,monospace;color:var(--code);background:var(--fill);border-radius:4px;padding:.12em .35em}
        pre{margin:.7em 0;padding:12px 14px;background:var(--fill);border-radius:8px;overflow-x:auto;line-height:1.5}pre code{color:inherit;background:none;padding:0;white-space:pre}
        .table{margin:.7em 0;overflow-x:auto}table{border-collapse:collapse;font-size:.95em}th,td{border:1px solid var(--line);padding:6px 12px;text-align:left;vertical-align:top}th{background:var(--fill);font-weight:600}
        a{color:var(--link);text-decoration:none}mark{background:var(--mark);color:inherit;border-radius:3px;padding:.05em .15em}img{max-width:100%;border-radius:6px}
        \(tokens(false))
        @media (prefers-color-scheme:dark){:root{--text:#f2f2f4;--soft:#a1a1a6;--line:rgba(255,255,255,.16);--fill:rgba(255,255,255,.07);--back:#1e1e1e;--link:#5aa9ff;--code:\(hex(MarkdownStyler.codeColor, dark: true));--mark:rgba(255,214,10,.3)}\(tokens(true))}
        """
    }
}
