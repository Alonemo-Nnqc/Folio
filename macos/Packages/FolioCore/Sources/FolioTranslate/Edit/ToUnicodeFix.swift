import Foundation

/// Core Graphics writes a font's ToUnicode map by asking the font which character each glyph stands for, and Chinese
/// fonts draw a Kangxi radical (⼀ U+2F00) and its ideograph (一 U+4E00) with one glyph: copied or searched text then
/// comes out as radicals. Their compatibility mappings (NFKC) lead back to the ideographs. (The same fix as the Windows
/// engine's `ToUnicodeFix`, where Skia does the same.)
enum ToUnicodeFix {
    static func needsFix(_ value: UInt32) -> Bool {
        (0x2E80...0x2FDF).contains(value) || (0xF900...0xFAFF).contains(value) || (0x2F800...0x2FA1F).contains(value)
    }

    /// `text` with radicals and compatibility ideographs as unified ideographs.
    static func fixed(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { needsFix($0.value) }) else { return text }
        var result = ""
        for scalar in text.unicodeScalars {
            let character = String(scalar)
            result += needsFix(scalar.value) ? character.precomposedStringWithCompatibilityMapping : character
        }
        return result
    }

    private static let charBlock = try! NSRegularExpression(pattern: #"(\d+)\s+beginbfchar(.*?)endbfchar"#, options: .dotMatchesLineSeparators)
    private static let rangeBlock = try! NSRegularExpression(pattern: #"(\d+)\s+beginbfrange(.*?)endbfrange"#, options: .dotMatchesLineSeparators)
    private static let pair = try! NSRegularExpression(pattern: #"<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>"#)
    private static let range = try! NSRegularExpression(pattern: #"<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>"#)

    private static func decode(_ hex: String) -> String {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex), next > index {
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return String(bytes: bytes, encoding: .utf16BigEndian) ?? ""
    }

    private static func encode(_ text: String) -> String {
        text.utf16.map { String(format: "%04X", $0) }.joined()
    }

    /// The CMap with radicals and compatibility ideographs mapped to unified ideographs; nil when it is not a CMap or
    /// nothing changes.
    static func apply(_ data: Data) -> Data? {
        guard data.count < 8_000_000, data.range(of: Data("begincmap".utf8)) != nil, data.range(of: Data("beginbf".utf8)) != nil,
              var text = String(data: data, encoding: .isoLatin1) else { return nil }
        var changed = false
        var extra: [(code: String, target: String)] = []

        func replacing(_ regex: NSRegularExpression, in text: String, _ transform: (NSTextCheckingResult, NSString) -> String) -> String {
            let ns = text as NSString
            var result = ""
            var cursor = 0
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                result += transform(match, ns)
                cursor = match.range.location + match.range.length
            }
            return result + ns.substring(from: cursor)
        }

        text = replacing(charBlock, in: text) { block, ns in
            let body = ns.substring(with: block.range(at: 2))
            let fixedBody = replacing(pair, in: body) { m, inner in
                let target = decode(inner.substring(with: m.range(at: 2)))
                let fixedTarget = fixed(target)
                guard fixedTarget != target else { return inner.substring(with: m.range) }
                changed = true
                return "<\(inner.substring(with: m.range(at: 1)))> <\(encode(fixedTarget))>"
            }
            return ns.substring(with: block.range(at: 1)) + " beginbfchar" + fixedBody + "endbfchar"
        }
        // A range whose characters change is written out one by one.
        text = replacing(rangeBlock, in: text) { block, ns in
            let body = ns.substring(with: block.range(at: 2)) as NSString
            var kept: [String] = []
            for m in range.matches(in: body as String, range: NSRange(location: 0, length: body.length)) {
                let loHex = body.substring(with: m.range(at: 1))
                guard let lo = Int(loHex, radix: 16), let hi = Int(body.substring(with: m.range(at: 2)), radix: 16) else { continue }
                let first = Array(decode(body.substring(with: m.range(at: 3))).utf16)
                var any = false
                var singles: [(String, String)] = []
                var code = lo
                while code <= hi, code - lo < 256 {
                    var units = first
                    if let last = units.last { units[units.count - 1] = last &+ UInt16(code - lo) }
                    let target = String(utf16CodeUnits: units, count: units.count)
                    let fixedTarget = fixed(target)
                    any = any || fixedTarget != target
                    singles.append((String(format: "%0\(loHex.count)X", code), fixedTarget))
                    code += 1
                }
                if any {
                    extra += singles.map { (code: $0.0, target: $0.1) }
                    changed = true
                } else {
                    kept.append(body.substring(with: m.range))
                }
            }
            return kept.isEmpty ? "" : "\(kept.count) beginbfrange\n\(kept.joined(separator: "\n"))\nendbfrange"
        }
        guard changed else { return nil }
        if !extra.isEmpty {
            var blocks = ""
            for start in stride(from: 0, to: extra.count, by: 100) {
                let chunk = extra[start..<min(start + 100, extra.count)]
                blocks += "\(chunk.count) beginbfchar\n"
                for entry in chunk { blocks += "<\(entry.code)> <\(encode(entry.target))>\n" }
                blocks += "endbfchar\n"
            }
            if let at = text.range(of: "endcmap") { text.insert(contentsOf: blocks, at: at.lowerBound) } else { text += blocks }
        }
        return text.data(using: .isoLatin1)
    }
}
