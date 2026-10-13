import Foundation

/// A JSON value with ordered keys, for the entries Folio writes into other apps' configuration.
indirect enum OrderedJSON: Sendable, Equatable {
    case string(String)
    case bool(Bool)
    case array([OrderedJSON])
    case object([(String, OrderedJSON)])

    static func == (lhs: OrderedJSON, rhs: OrderedJSON) -> Bool { lhs.render(indent: "", unit: "") == rhs.render(indent: "", unit: "") }

    /// Pretty-printed with `unit` per level; continuation lines start with `indent`.
    func render(indent: String, unit: String) -> String {
        switch self {
        case .string(let value): return Self.quote(value)
        case .bool(let value): return value ? "true" : "false"
        case .array(let values):
            // Short arrays of scalars stay on one line, as people write them.
            return "[" + values.map { $0.render(indent: indent, unit: unit) }.joined(separator: ", ") + "]"
        case .object(let members):
            guard !members.isEmpty else { return "{}" }
            let inner = indent + unit
            let body = members.map { "\(inner)\(Self.quote($0.0)): \($0.1.render(indent: inner, unit: unit))" }
            return "{\n" + body.joined(separator: ",\n") + "\n\(indent)}"
        }
    }

    static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04X", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}

struct JSONCError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Edits JSON / JSON-with-comments files the way VS Code's `jsonc-parser` does: Folio's one member is
/// replaced, inserted or removed, and every other byte — key order, indentation, comments, trailing
/// commas — stays as the user (or the other app) wrote it.
struct JSONCDocument {
    private(set) var text: String

    init(_ text: String) {
        self.text = text
    }

    // MARK: Reading

    /// The document as Foundation objects (comments and trailing commas ignored).
    func object() throws -> [String: Any] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [:] }
        guard let data = Self.strippingComments(text).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw JSONCError(message: "not valid JSON")
        }
        guard let object = root as? [String: Any] else { throw JSONCError(message: "the top level is not an object") }
        return object
    }

    /// JSON text without `//` and `/* */` comments and without trailing commas.
    static func strippingComments(_ text: String) -> String {
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        var pendingComma: Int?   // index in `out` of a comma that may turn out to be trailing
        while i < bytes.count {
            let byte = bytes[i]
            if byte == UInt8(ascii: "\"") {
                pendingComma = nil
                let end = Scanner.stringEnd(bytes, from: i)
                out += bytes[i..<end]
                i = end
                continue
            }
            if byte == UInt8(ascii: "/"), i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "/") {
                while i < bytes.count, bytes[i] != UInt8(ascii: "\n") { i += 1 }
                continue
            }
            if byte == UInt8(ascii: "/"), i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "*") {
                i += 2
                while i + 1 < bytes.count, !(bytes[i] == UInt8(ascii: "*") && bytes[i + 1] == UInt8(ascii: "/")) { i += 1 }
                i = min(i + 2, bytes.count)
                out.append(UInt8(ascii: " "))
                continue
            }
            if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]"), let comma = pendingComma {
                out[comma] = UInt8(ascii: " ")
            }
            if byte == UInt8(ascii: ",") { pendingComma = out.count }
            else if !Scanner.isSpace(byte) { pendingComma = nil }
            out.append(byte)
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: Editing

    /// Sets `root[container][name]` to `value`, or removes it when `value` is nil. A missing
    /// `container` is created; removing the last member leaves an empty `container` in place.
    mutating func setMember(_ name: String, in container: String, to value: OrderedJSON?) throws {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let value else { return }
            text = OrderedJSON.object([(container, .object([(name, value)]))]).render(indent: "", unit: "  ") + "\n"
            return
        }
        _ = try object()   // refuse to edit something that is not a JSON object
        var bytes = Array(text.utf8)
        var scanner = Scanner(bytes: bytes)
        guard let root = try scanner.parseRoot() else { throw JSONCError(message: "the top level is not an object") }
        let unit = Self.indentUnit(bytes, root)

        if let member = root.members.first(where: { $0.key == container }) {
            guard let inner = member.object else {
                // `container` holds something else (e.g. null): replace it with an object.
                guard let value else { return }
                let indent = Self.lineIndent(bytes, at: member.keyStart)
                let replacement = OrderedJSON.object([(name, value)]).render(indent: indent, unit: unit)
                bytes.replaceSubrange(member.valueRange, with: Array(replacement.utf8))
                text = String(decoding: bytes, as: UTF8.self)
                return
            }
            let containerIndent = Self.lineIndent(bytes, at: member.keyStart)
            if let existing = inner.members.first(where: { $0.key == name }) {
                if let value {
                    let indent = Self.lineIndent(bytes, at: existing.keyStart)
                    bytes.replaceSubrange(existing.valueRange, with: Array(value.render(indent: indent, unit: unit).utf8))
                } else {
                    Self.remove(existing, from: inner, in: &bytes)
                }
            } else if let value {
                Self.insert(name, value, into: inner, indent: containerIndent + unit, closingIndent: containerIndent, unit: unit, in: &bytes)
            }
        } else if let value {
            Self.insert(container, .object([(name, value)]), into: root, indent: unit, closingIndent: "", unit: unit, in: &bytes)
        }
        text = String(decoding: bytes, as: UTF8.self)
    }

    private static func insert(_ name: String, _ value: OrderedJSON, into object: Scanner.Object, indent: String,
                               closingIndent: String, unit: String, in bytes: inout [UInt8]) {
        let member = "\(OrderedJSON.quote(name)): \(value.render(indent: indent, unit: unit))"
        if let last = object.members.last {
            // After the last value (a trailing comma, if any, ends up after the new member).
            bytes.insert(contentsOf: Array(",\n\(indent)\(member)".utf8), at: last.valueRange.upperBound)
        } else {
            // Empty object: keep anything inside it (comments), put the member on its own line.
            let inside = String(decoding: bytes[(object.open + 1)..<object.close], as: UTF8.self)
            let replacement = inside.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "\n\(indent)\(member)\n\(closingIndent)"
                : inside.trimmingCharacters(in: .whitespaces) + "\n\(indent)\(member)\n\(closingIndent)"
            bytes.replaceSubrange((object.open + 1)..<object.close, with: Array(replacement.utf8))
        }
    }

    private static func remove(_ member: Scanner.Member, from object: Scanner.Object, in bytes: inout [UInt8]) {
        let index = object.members.firstIndex { $0.keyStart == member.keyStart }!
        var start = member.keyStart
        var end = member.valueRange.upperBound
        if index == object.members.count - 1, index > 0, let previousComma = object.members[index - 1].commaAfter {
            // The last member: from the previous member's comma to the end of the value, so a trailing
            // comma or comment after it stays where it was (this undoes `insert` exactly).
            start = previousComma
        } else if let comma = member.commaAfter {
            // "key": value,  → remove through the comma and the rest of its line.
            end = comma + 1
            start = lineStartIfBlank(bytes, start)
            end = lineEndIfBlank(bytes, end)
        } else {
            start = lineStartIfBlank(bytes, start)
            end = lineEndIfBlank(bytes, end)
        }
        bytes.removeSubrange(start..<end)
    }

    /// The start of the line when only spaces precede `index` on it.
    private static func lineStartIfBlank(_ bytes: [UInt8], _ index: Int) -> Int {
        var i = index
        while i > 0, bytes[i - 1] == UInt8(ascii: " ") || bytes[i - 1] == UInt8(ascii: "\t") { i -= 1 }
        return i > 0 && bytes[i - 1] != UInt8(ascii: "\n") ? index : i
    }

    /// Past the newline when only spaces follow `index` on its line.
    private static func lineEndIfBlank(_ bytes: [UInt8], _ index: Int) -> Int {
        var i = index
        while i < bytes.count, bytes[i] == UInt8(ascii: " ") || bytes[i] == UInt8(ascii: "\t") { i += 1 }
        if i < bytes.count, bytes[i] == UInt8(ascii: "\n") { return i + 1 }
        if i < bytes.count, bytes[i] == UInt8(ascii: "\r"), i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "\n") { return i + 2 }
        return index
    }

    /// The whitespace at the start of the line containing `index`.
    static func lineIndent(_ bytes: [UInt8], at index: Int) -> String {
        var start = index
        while start > 0, bytes[start - 1] != UInt8(ascii: "\n") { start -= 1 }
        var end = start
        while end < bytes.count, bytes[end] == UInt8(ascii: " ") || bytes[end] == UInt8(ascii: "\t") { end += 1 }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    /// The file's indentation step: the indent of the root's first member, else two spaces.
    private static func indentUnit(_ bytes: [UInt8], _ root: Scanner.Object) -> String {
        guard let first = root.members.first else { return "  " }
        let indent = lineIndent(bytes, at: first.keyStart)
        return indent.isEmpty ? "  " : indent
    }
}

/// Recursive-descent scanner over UTF-8 bytes that records where objects and members are.
private struct Scanner {
    struct Member {
        let key: String
        let keyStart: Int
        let valueRange: Range<Int>
        /// The comma after the value, if any.
        let commaAfter: Int?
        /// The value when it is an object.
        let object: Object?
    }

    struct Object {
        let open: Int
        let close: Int
        let members: [Member]
    }

    let bytes: [UInt8]
    var position = 0

    static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// Index just past the string starting at `start` (a quote).
    static func stringEnd(_ bytes: [UInt8], from start: Int) -> Int {
        var i = start + 1
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "\\") { i += 2; continue }
            if bytes[i] == UInt8(ascii: "\"") { return i + 1 }
            i += 1
        }
        return bytes.count
    }

    mutating func skipTrivia() {
        while position < bytes.count {
            let byte = bytes[position]
            if Self.isSpace(byte) { position += 1; continue }
            if byte == UInt8(ascii: "/"), position + 1 < bytes.count {
                if bytes[position + 1] == UInt8(ascii: "/") {
                    while position < bytes.count, bytes[position] != UInt8(ascii: "\n") { position += 1 }
                    continue
                }
                if bytes[position + 1] == UInt8(ascii: "*") {
                    position += 2
                    while position + 1 < bytes.count, !(bytes[position] == UInt8(ascii: "*") && bytes[position + 1] == UInt8(ascii: "/")) {
                        position += 1
                    }
                    position = min(position + 2, bytes.count)
                    continue
                }
            }
            return
        }
    }

    mutating func parseRoot() throws -> Object? {
        skipTrivia()
        guard position < bytes.count, bytes[position] == UInt8(ascii: "{") else { return nil }
        return try parseObject()
    }

    /// Parses any value; returns the object when it is one.
    mutating func parseValue() throws -> Object? {
        skipTrivia()
        guard position < bytes.count else { throw JSONCError(message: "unexpected end") }
        switch bytes[position] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["):
            position += 1
            while true {
                skipTrivia()
                guard position < bytes.count else { throw JSONCError(message: "unterminated array") }
                if bytes[position] == UInt8(ascii: "]") { position += 1; return nil }
                _ = try parseValue()
                skipTrivia()
                if position < bytes.count, bytes[position] == UInt8(ascii: ",") { position += 1 }
            }
        case UInt8(ascii: "\""):
            position = Self.stringEnd(bytes, from: position)
            return nil
        default:
            while position < bytes.count, !Self.isSpace(bytes[position]),
                  ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), UInt8(ascii: "/")].contains(bytes[position]) {
                position += 1
            }
            return nil
        }
    }

    mutating func parseObject() throws -> Object {
        let open = position
        position += 1
        var members: [Member] = []
        while true {
            skipTrivia()
            guard position < bytes.count else { throw JSONCError(message: "unterminated object") }
            if bytes[position] == UInt8(ascii: "}") {
                let close = position
                position += 1
                return Object(open: open, close: close, members: members)
            }
            guard bytes[position] == UInt8(ascii: "\"") else { throw JSONCError(message: "expected a key") }
            let keyStart = position
            position = Self.stringEnd(bytes, from: position)
            let rawKey = Data(bytes[keyStart..<position])
            let key = (try? JSONSerialization.jsonObject(with: rawKey, options: [.fragmentsAllowed]) as? String) ?? ""
            skipTrivia()
            guard position < bytes.count, bytes[position] == UInt8(ascii: ":") else { throw JSONCError(message: "expected ':'") }
            position += 1
            skipTrivia()
            let valueStart = position
            let object = try parseValue()
            let valueEnd = position
            skipTrivia()
            var comma: Int?
            if position < bytes.count, bytes[position] == UInt8(ascii: ",") {
                comma = position
                position += 1
            }
            members.append(Member(key: key, keyStart: keyStart, valueRange: valueStart..<valueEnd, commaAfter: comma, object: object))
        }
    }
}
