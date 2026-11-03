import Foundation

/// An operand of a content-stream operator.
indirect enum ContentOperand: Sendable, Equatable {
    case number(Double)
    case name(String)
    case string(Data)
    case array([ContentOperand])
    case dict([String: ContentOperand])
    case bool(Bool)
    case null

    var number: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    var name: String? {
        if case .name(let n) = self { return n }
        return nil
    }
}

/// One operator with its operands, and the bytes it occupies in the stream (operands included).
struct ContentOp: Sendable {
    var name: String
    var operands: [ContentOperand]
    var range: Range<Int>
    /// For `BI … ID … EI`: the inline image's dictionary (abbreviated keys as written).
    var inlineImage: [String: ContentOperand]?
}

/// Splits a decoded content stream into operators (PDF 32000-1 §7.2, §7.8.2).
struct ContentLexer {
    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    static func parse(_ data: Data) -> [ContentOp] {
        var lexer = ContentLexer(data)
        return lexer.parseAll()
    }

    private enum Token {
        case operand(ContentOperand)
        case keyword(String)
        case arrayStart, arrayEnd, dictStart, dictEnd
    }

    mutating func parseAll() -> [ContentOp] {
        var ops: [ContentOp] = []
        var operands: [ContentOperand] = []
        var start: Int?
        while true {
            skipWhitespace()
            guard index < bytes.count else { break }
            let tokenStart = index
            guard let token = nextToken() else { break }
            if start == nil { start = tokenStart }
            switch token {
            case .operand(let value):
                operands.append(value)
            case .arrayStart:
                operands.append(.array(parseArray()))
            case .dictStart:
                operands.append(.dict(parseDict()))
            case .arrayEnd, .dictEnd:
                break
            case .keyword(let word):
                switch word {
                case "true": operands.append(.bool(true)); continue
                case "false": operands.append(.bool(false)); continue
                case "null": operands.append(.null); continue
                default: break
                }
                if word == "BI" {
                    let image = parseInlineImage()
                    ops.append(ContentOp(name: "BI", operands: [], range: start!..<index, inlineImage: image))
                } else {
                    ops.append(ContentOp(name: word, operands: operands, range: start!..<index))
                }
                operands = []
                start = nil
            }
        }
        return ops
    }

    private static func isWhitespace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 || b == 0x0C || b == 0x00 }
    private static func isDelimiter(_ b: UInt8) -> Bool { "()<>[]{}/%".utf8.contains(b) }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            let b = bytes[index]
            if Self.isWhitespace(b) {
                index += 1
            } else if b == UInt8(ascii: "%") {
                while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D { index += 1 }
            } else {
                break
            }
        }
    }

    private mutating func nextToken() -> Token? {
        guard index < bytes.count else { return nil }
        let b = bytes[index]
        switch b {
        case UInt8(ascii: "["):
            index += 1
            return .arrayStart
        case UInt8(ascii: "]"):
            index += 1
            return .arrayEnd
        case UInt8(ascii: "<"):
            if index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "<") {
                index += 2
                return .dictStart
            }
            return .operand(.string(parseHexString()))
        case UInt8(ascii: ">"):
            index += min(2, bytes.count - index)
            return .dictEnd
        case UInt8(ascii: "("):
            return .operand(.string(parseLiteralString()))
        case UInt8(ascii: "/"):
            index += 1
            return .operand(.name(parseName()))
        case UInt8(ascii: "{"), UInt8(ascii: "}"):
            index += 1
            return .keyword(String(UnicodeScalar(b)))
        default:
            if b == UInt8(ascii: "+") || b == UInt8(ascii: "-") || b == UInt8(ascii: ".") || (b >= 0x30 && b <= 0x39) {
                if let number = parseNumber() { return .operand(.number(number)) }
            }
            let start = index
            while index < bytes.count, !Self.isWhitespace(bytes[index]), !Self.isDelimiter(bytes[index]) { index += 1 }
            if index == start { index += 1 }
            return .keyword(String(decoding: bytes[start..<index], as: UTF8.self))
        }
    }

    private mutating func parseNumber() -> Double? {
        let start = index
        var seenDigit = false
        if bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
        while index < bytes.count {
            let c = bytes[index]
            if c >= 0x30 && c <= 0x39 { seenDigit = true; index += 1 }
            else if c == UInt8(ascii: ".") || c == UInt8(ascii: "-") { index += 1 }
            else { break }
        }
        guard seenDigit else {
            index = start
            return nil
        }
        // Tolerate "--5" or "1.2.3" from sloppy writers: read the longest valid prefix.
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        if let value = Double(text) { return value }
        var trimmed = text
        while !trimmed.isEmpty, Double(trimmed) == nil { trimmed.removeLast() }
        return Double(trimmed) ?? 0
    }

    private mutating func parseName() -> String {
        var out: [UInt8] = []
        while index < bytes.count, !Self.isWhitespace(bytes[index]), !Self.isDelimiter(bytes[index]) {
            if bytes[index] == UInt8(ascii: "#"), index + 2 < bytes.count,
               let value = UInt8(String(decoding: bytes[index + 1...index + 2], as: UTF8.self), radix: 16) {
                out.append(value)
                index += 3
            } else {
                out.append(bytes[index])
                index += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private mutating func parseLiteralString() -> Data {
        index += 1
        var out: [UInt8] = []
        var depth = 1
        while index < bytes.count {
            let c = bytes[index]
            index += 1
            switch c {
            case UInt8(ascii: "\\"):
                guard index < bytes.count else { break }
                let e = bytes[index]
                index += 1
                switch e {
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case 0x0D:
                    if index < bytes.count, bytes[index] == 0x0A { index += 1 }
                case 0x0A: break
                case UInt8(ascii: "0")...UInt8(ascii: "7"):
                    var value = Int(e - 0x30)
                    for _ in 0..<2 {
                        guard index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x37 else { break }
                        value = value * 8 + Int(bytes[index] - 0x30)
                        index += 1
                    }
                    out.append(UInt8(value & 0xFF))
                default: out.append(e)
                }
            case UInt8(ascii: "("):
                depth += 1
                out.append(c)
            case UInt8(ascii: ")"):
                depth -= 1
                if depth == 0 { return Data(out) }
                out.append(c)
            default:
                out.append(c)
            }
        }
        return Data(out)
    }

    private mutating func parseHexString() -> Data {
        index += 1
        var out: [UInt8] = []
        var high: UInt8?
        while index < bytes.count {
            let c = bytes[index]
            index += 1
            if c == UInt8(ascii: ">") { break }
            let value: UInt8
            switch c {
            case 0x30...0x39: value = c - 0x30
            case 0x41...0x46: value = c - 0x41 + 10
            case 0x61...0x66: value = c - 0x61 + 10
            default: continue
            }
            if let h = high {
                out.append(h << 4 | value)
                high = nil
            } else {
                high = value
            }
        }
        if let h = high { out.append(h << 4) }
        return Data(out)
    }

    private mutating func parseArray() -> [ContentOperand] {
        var items: [ContentOperand] = []
        while true {
            skipWhitespace()
            guard index < bytes.count, let token = nextToken() else { return items }
            switch token {
            case .arrayEnd: return items
            case .operand(let value): items.append(value)
            case .arrayStart: items.append(.array(parseArray()))
            case .dictStart: items.append(.dict(parseDict()))
            case .keyword(let word):
                if word == "true" { items.append(.bool(true)) }
                else if word == "false" { items.append(.bool(false)) }
                else if word == "null" { items.append(.null) }
            case .dictEnd: break
            }
        }
    }

    private mutating func parseDict() -> [String: ContentOperand] {
        var result: [String: ContentOperand] = [:]
        var key: String?
        while true {
            skipWhitespace()
            guard index < bytes.count, let token = nextToken() else { return result }
            var value: ContentOperand?
            switch token {
            case .dictEnd: return result
            case .operand(let v): value = v
            case .arrayStart: value = .array(parseArray())
            case .dictStart: value = .dict(parseDict())
            case .keyword(let word): value = word == "true" ? .bool(true) : word == "false" ? .bool(false) : .null
            case .arrayEnd: continue
            }
            if let k = key {
                result[k] = value
                key = nil
            } else if case .name(let n)? = value {
                key = n
            }
        }
    }

    /// `BI <key value>* ID <data> EI`; leaves `index` after `EI`.
    private mutating func parseInlineImage() -> [String: ContentOperand] {
        var dict: [String: ContentOperand] = [:]
        var key: String?
        while true {
            skipWhitespace()
            guard index < bytes.count, let token = nextToken() else { return dict }
            if case .keyword("ID") = token { break }
            var value: ContentOperand?
            switch token {
            case .operand(let v): value = v
            case .arrayStart: value = .array(parseArray())
            case .dictStart: value = .dict(parseDict())
            case .keyword(let word): value = .name(word)
            default: continue
            }
            if let k = key {
                dict[k] = value
                key = nil
            } else if case .name(let n)? = value {
                key = n
            }
        }
        // One whitespace byte separates ID from the data.
        if index < bytes.count { index += 1 }
        // The data ends at whitespace + "EI" + (whitespace | end).
        var i = index
        while i + 2 < bytes.count {
            if Self.isWhitespace(bytes[i]), bytes[i + 1] == UInt8(ascii: "E"), bytes[i + 2] == UInt8(ascii: "I"),
               i + 3 >= bytes.count || Self.isWhitespace(bytes[i + 3]) || Self.isDelimiter(bytes[i + 3]) {
                index = i + 3
                return dict
            }
            i += 1
        }
        index = bytes.count
        return dict
    }
}
