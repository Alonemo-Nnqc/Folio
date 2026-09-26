import FolioCore
import Foundation
import JavaScriptCore

/// Errors raised while loading citeproc-js or rendering a bibliography with it.
public enum CSLRendererError: Error, CustomStringConvertible, Equatable {
    case contextUnavailable
    case resourceMissing(String)
    case scriptFailed(String)

    public var description: String {
        switch self {
        case .contextUnavailable: "无法创建 JavaScriptCore 环境"
        case .resourceMissing(let name): "缺少引用导出所需的资源文件：\(name)"
        case .scriptFailed(let message): "citeproc-js 出错：\(message)"
        }
    }
}

/// Renders `CitationEntry` lists into formatted citations using citeproc-js
/// (GB/T 7714-2015, APA) or the pure-Swift `BibTeXWriter` (BibTeX).
///
/// citeproc-js runs inside one `JSContext`; this type is **not** `Sendable`
/// and must only ever be used from a single thread/task. Create one
/// `CSLRenderer` per consumer (e.g. one per actor) and reuse it — the
/// citeproc-js script and each style's `CSL.Engine` are loaded lazily once
/// and cached for the lifetime of the renderer.
public final class CSLRenderer {
    /// Mutable box read by the `retrieveItem` JS callback. Rebuilt before
    /// every `render(_:style:)` call; holds no reference back to `self` so
    /// the JS object graph (owned indirectly via `context`) cannot retain
    /// this renderer in a cycle.
    private final class ItemStore {
        var items: [String: [String: Any]] = [:]
    }

    private let context: JSContext
    private let engineConstructor: JSValue
    private let sys: JSValue
    private let itemStore = ItemStore()
    private let styleXML: [CitationStyle: String]
    private var engines: [CitationStyle: JSValue] = [:]
    private var lastException: String?

    public init() throws {
        guard let context = JSContext() else {
            throw CSLRendererError.contextUnavailable
        }
        self.context = context

        var capturedException: String?
        context.exceptionHandler = { _, exception in
            capturedException = exception?.toString() ?? "unknown JavaScript exception"
        }

        context.evaluateScript("var module = { exports: {} }; var exports = module.exports;")
        let citeprocSource = try Self.loadResourceText("citeproc_commonjs", extension: "js")
        context.evaluateScript(citeprocSource)
        if let capturedException {
            throw CSLRendererError.scriptFailed(capturedException)
        }

        guard
            let moduleValue = context.objectForKeyedSubscript("module"),
            let cslValue = moduleValue.objectForKeyedSubscript("exports"),
            let engineCtor = cslValue.objectForKeyedSubscript("Engine"),
            !engineCtor.isUndefined
        else {
            throw CSLRendererError.scriptFailed("citeproc-js 未导出 CSL.Engine")
        }
        context.setObject(cslValue, forKeyedSubscript: "CSL" as NSString)
        self.engineConstructor = engineCtor

        self.styleXML = [
            .apa: try Self.loadResourceText("apa", extension: "csl"),
            .gbt7714: try Self.loadResourceText(
                "china-national-standard-gb-t-7714-2015-numeric", extension: "csl"),
        ]

        let localeXML: [String: String] = [
            "en-US": try Self.loadResourceText("locales-en-US", extension: "xml"),
            "zh-CN": try Self.loadResourceText("locales-zh-CN", extension: "xml"),
        ]

        let sys = JSValue(newObjectIn: context)
        let itemStore = self.itemStore
        let retrieveItem: @convention(block) (String) -> [String: Any] = { id in
            itemStore.items[id] ?? [:]
        }
        let retrieveLocale: @convention(block) (String) -> String = { lang in
            localeXML[lang] ?? localeXML["en-US"] ?? ""
        }
        sys?.setObject(retrieveItem, forKeyedSubscript: "retrieveItem" as NSString)
        sys?.setObject(retrieveLocale, forKeyedSubscript: "retrieveLocale" as NSString)
        guard let sys else { throw CSLRendererError.contextUnavailable }
        self.sys = sys

        // Route later exceptions (during engine construction / rendering) to
        // this instance instead of the now-dead local variable above.
        context.exceptionHandler = { [weak self] _, exception in
            self?.lastException = exception?.toString() ?? "unknown JavaScript exception"
        }
    }

    /// Renders `entries` in one `style`. BibTeX is produced by `BibTeXWriter`
    /// directly; GB/T 7714 and APA go through citeproc-js.
    ///
    /// GB/T 7714 output is plain text, one entry per line, with the style's
    /// numeric "[1]" bibliography label stripped. APA output is plain text
    /// plus an HTML rendering that preserves italics (e.g. journal titles).
    public func render(_ entries: [CitationEntry], style: CitationStyle) throws -> CitationOutput {
        guard !entries.isEmpty else { return CitationOutput(plainText: "") }

        if style == .bibtex {
            return CitationOutput(plainText: BibTeXWriter.document(entries))
        }

        let engine = try cachedEngine(for: style)

        var items: [String: [String: Any]] = [:]
        items.reserveCapacity(entries.count)
        var ids: [String] = []
        ids.reserveCapacity(entries.count)
        for entry in entries {
            items[entry.id] = CSLJSONMapper.csljson(id: entry.id, metadata: entry.metadata)
            ids.append(entry.id)
        }
        itemStore.items = items

        lastException = nil
        engine.invokeMethod("setOutputFormat", withArguments: ["text"])
        engine.invokeMethod("updateItems", withArguments: [ids])
        try checkException()

        var lines = try bibliographyEntries(engine: engine).map {
            $0.trimmingCharacters(in: .newlines)
        }
        if style == .gbt7714 {
            lines = lines.map(Self.strippingNumericLabel)
        }
        let plainText = lines.joined(separator: "\n")

        var html: String?
        if style == .apa {
            engine.invokeMethod("setOutputFormat", withArguments: ["html"])
            try checkException()
            html = try bibliographyHTML(engine: engine)
        }

        return CitationOutput(plainText: plainText, html: html)
    }

    // MARK: - Engine cache

    private func cachedEngine(for style: CitationStyle) throws -> JSValue {
        if let cached = engines[style] { return cached }
        guard let xml = styleXML[style] else {
            throw CSLRendererError.resourceMissing("\(style.rawValue).csl")
        }
        lastException = nil
        // Force English (en-US) locale terms regardless of the style's own
        // default-locale: Folio's metadata sources are English-only
        // (requirement META-02), so citation terms such as "et al." should
        // stay in English even under the Chinese GB/T 7714 style.
        guard
            let engine = engineConstructor.construct(withArguments: [sys, xml, "en-US", true]),
            !engine.isUndefined
        else {
            throw CSLRendererError.scriptFailed(
                lastException ?? "无法为样式 \(style.rawValue) 创建 CSL.Engine")
        }
        try checkException()
        engines[style] = engine
        return engine
    }

    // MARK: - citeproc-js call helpers

    /// `engine.makeBibliography()` returns a two-element JS array:
    /// `[bibliographyMeta, entryStrings]`.
    private func makeBibliography(engine: JSValue) throws -> JSValue {
        lastException = nil
        guard let result = engine.invokeMethod("makeBibliography", withArguments: []) else {
            throw CSLRendererError.scriptFailed("makeBibliography() 未返回结果")
        }
        try checkException()
        guard !result.isUndefined, !result.isNull else {
            throw CSLRendererError.scriptFailed("makeBibliography() 未返回结果")
        }
        return result
    }

    private func jsArrayStrings(_ value: JSValue) -> [String] {
        let length = Int(value.forProperty("length")?.toInt32() ?? 0)
        guard length > 0 else { return [] }
        return (0..<length).map { value.atIndex($0)?.toString() ?? "" }
    }

    private func bibliographyEntries(engine: JSValue) throws -> [String] {
        let result = try makeBibliography(engine: engine)
        guard let entriesValue = result.atIndex(1) else { return [] }
        return jsArrayStrings(entriesValue)
    }

    private func bibliographyHTML(engine: JSValue) throws -> String {
        let result = try makeBibliography(engine: engine)
        guard let meta = result.atIndex(0), let entriesValue = result.atIndex(1) else {
            return ""
        }
        let bibstart = meta.forProperty("bibstart")?.toString() ?? ""
        let bibend = meta.forProperty("bibend")?.toString() ?? ""
        let entries = jsArrayStrings(entriesValue).joined()
        return bibstart + entries + bibend
    }

    private func checkException() throws {
        if let message = lastException {
            lastException = nil
            throw CSLRendererError.scriptFailed(message)
        }
    }

    /// Strips a leading numeric bibliography label such as `"[1]"` (with any
    /// following space) from one rendered GB/T 7714 entry.
    private static func strippingNumericLabel(_ line: String) -> String {
        guard line.hasPrefix("[") else { return line }
        guard let closing = line.firstIndex(of: "]") else { return line }
        let label = line[line.index(after: line.startIndex)..<closing]
        guard !label.isEmpty, label.allSatisfy(\.isNumber) else { return line }
        var rest = line[line.index(after: closing)...]
        while let first = rest.first, first == " " {
            rest = rest.dropFirst()
        }
        return String(rest)
    }

    // MARK: - Resource loading

    private static func loadResourceText(_ name: String, extension ext: String) throws -> String {
        guard
            let url = Bundle.module.url(
                forResource: name, withExtension: ext, subdirectory: "Resources")
        else {
            throw CSLRendererError.resourceMissing("\(name).\(ext)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
