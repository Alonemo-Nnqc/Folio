import AppKit
import JavaScriptCore

/// Colours the code of code blocks and tells what language it is in (highlight.js, run in JavaScriptCore; the same
/// files as the Windows app's).
@MainActor
final class CodeHighlighter {
    static let shared = CodeHighlighter()

    struct Language: Identifiable { var id: String; var title: String }
    struct Token { var range: NSRange; var kind: String }

    private let code: JSValue?
    let languages: [Language]
    private var detected: [String: String] = [:]
    private var colored: [String: [Token]] = [:]

    private init() {
        guard let context = JSContext() else { code = nil; languages = []; return }
        for name in ["highlight.min", "code-languages"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "js"), let source = try? String(contentsOf: url, encoding: .utf8) {
                context.evaluateScript(source)
            }
        }
        code = context.objectForKeyedSubscript("folioCode").flatMap { $0.isUndefined ? nil : $0 }
        languages = (code?.objectForKeyedSubscript("languages")?.toArray() as? [[String]] ?? []).map { Language(id: $0[0], title: $0[1]) }
    }

    func title(of language: String) -> String { languages.first { $0.id == language }?.title ?? language }

    /// The language an info string ("py") names.
    func resolve(_ info: String) -> String? {
        code?.invokeMethod("resolve", withArguments: [info]).flatMap { $0.isString ? $0.toString() : nil }
    }

    func detect(_ text: String) -> String? {
        if let known = detected[text] { return known.isEmpty ? nil : known }
        let found = code?.invokeMethod("detect", withArguments: [text]).flatMap { $0.isString ? $0.toString() : nil }
        if detected.count > 200 { detected.removeAll() }
        detected[text] = found ?? ""
        return found
    }

    func tokens(_ text: String, language: String) -> [Token] {
        let key = language + "\n" + text
        if let known = colored[key] { return known }
        let flat = code?.invokeMethod("tokens", withArguments: [text, language])?.toArray() ?? []
        var tokens: [Token] = []
        var index = 0
        while index + 2 < flat.count {
            if let start = flat[index] as? Int, let end = flat[index + 1] as? Int, let kind = flat[index + 2] as? String {
                tokens.append(Token(range: NSRange(location: start, length: end - start), kind: kind))
            }
            index += 3
        }
        if colored.count > 100 { colored.removeAll() }
        colored[key] = tokens
        return tokens
    }

    static func color(of kind: String) -> NSColor? {
        switch kind {
        case "keyword", "doctag", "selector-tag", "template-tag", "name", "tag": keyword
        case "string", "regexp", "char", "addition", "quote": string
        case "number", "literal", "symbol", "bullet", "link": number
        case "comment", "deletion": kind == "comment" ? comment : keyword
        case "title", "section", "function": title
        case "built_in", "type", "class", "selector-class", "selector-id": type
        case "attr", "attribute", "variable", "template-variable", "property", "meta": attribute
        default: nil
        }
    }

    private static func dynamic(_ light: Int, _ dark: Int) -> NSColor {
        func color(_ hex: Int) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
        let pair = (color(light), color(dark))
        return NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? pair.1 : pair.0 }
    }

    private static let keyword = dynamic(0xC2185B, 0xFF7AB2)
    private static let string = dynamic(0x2E7D32, 0x9BD88A)
    private static let number = dynamic(0x8A4B08, 0xE8B86D)
    private static let comment = dynamic(0x8A8F98, 0x7F8790)
    private static let title = dynamic(0x1F5FBF, 0x7CB8FF)
    private static let type = dynamic(0x6F42C1, 0xC9A7FF)
    private static let attribute = dynamic(0x00728A, 0x6FD3E3)
}
