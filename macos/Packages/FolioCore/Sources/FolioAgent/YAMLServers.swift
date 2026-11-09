import Foundation

/// Adds and removes one server in a YAML file's top-level map (Hermes' `mcp_servers`, goose's `extensions`), line by
/// line: everything else in the file, comments included, stays exactly as it was.
enum YAMLServers {
    struct Unsupported: Error, LocalizedError {
        let key: String
        var errorDescription: String? { "\(key) is not a block mapping" }
    }

    private static func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
    private static func isContent(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !trimmed.hasPrefix("#")
    }

    /// The line holding `key:` and the lines of its value.
    private static func block(_ lines: [String], key: String) -> (line: Int, children: Range<Int>)? {
        guard let line = lines.firstIndex(where: { $0.hasPrefix(key + ":") }) else { return nil }
        let end = lines[(line + 1)...].firstIndex { isContent($0) && indent($0) == 0 } ?? lines.count
        return (line, (line + 1)..<end)
    }

    /// The lines of `name`'s entry, and how far its siblings are indented.
    private static func entry(_ lines: [String], in children: Range<Int>, name: String) -> (range: Range<Int>, indent: Int)? {
        guard let start = children.first(where: { isContent(lines[$0]) && lines[$0].trimmingCharacters(in: .whitespaces) == name + ":" }) else { return nil }
        let level = indent(lines[start])
        var end = lines[(start + 1)..<children.upperBound].firstIndex { isContent($0) && indent($0) <= level } ?? children.upperBound
        // Comments and blank lines after it belong to what follows.
        while end > start + 1, !isContent(lines[end - 1]) { end -= 1 }
        return (start..<end, level)
    }

    /// The value of `field` in `name`'s entry.
    static func value(of field: String, in text: String, key: String, name: String) -> String? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let block = block(lines, key: key), let entry = entry(lines, in: block.children, name: name) else { return nil }
        for line in lines[entry.range].dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(field + ":") else { continue }
            let raw = trimmed.dropFirst(field.count + 1).trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("\""), let end = raw.dropFirst().firstMatch(of: /(?:[^"\\]|\\.)*"/) {
                return String(end.output.dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            }
            if raw.hasPrefix("'") { return String(raw.dropFirst().prefix { $0 != "'" }) }
            return raw.components(separatedBy: " #")[0].trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    /// A double-quoted scalar.
    static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// `text` with `name` set to `fields` (lines relative to the entry), or removed when `fields` is nil.
    static func edited(_ text: String, key: String, name: String, fields: [String]?) throws -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let found = block(lines, key: key) else {
            guard let fields else { return text }
            while lines.last?.isEmpty == true { lines.removeLast() }
            if !lines.isEmpty { lines.append("") }
            return (lines + ["\(key):", "  \(name):"] + fields.map { "    " + $0 } + [""]).joined(separator: "\n")
        }
        let inline = lines[found.line].dropFirst(key.count + 1).components(separatedBy: " #")[0].trimmingCharacters(in: .whitespaces)
        guard ["", "{}", "null", "~"].contains(inline) else { throw Unsupported(key: key) }

        var children = found.children
        var level = children.first { isContent(lines[$0]) }.map { indent(lines[$0]) } ?? 2
        if let old = entry(lines, in: children, name: name) {
            level = old.indent
            lines.removeSubrange(old.range)
            children = children.lowerBound..<(children.upperBound - old.range.count)
        }
        if let fields {
            let pad = String(repeating: " ", count: level)
            lines.insert(contentsOf: ["\(pad)\(name):"] + fields.map { pad + "  " + $0 }, at: found.line + 1)
            lines[found.line] = "\(key):"
        } else if !children.contains(where: { isContent(lines[$0]) }) {
            lines[found.line] = "\(key): {}"
        }
        return lines.joined(separator: "\n")
    }
}
