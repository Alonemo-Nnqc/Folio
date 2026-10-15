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
        case .contextUnavailable: String(localized: "无法创建 JavaScriptCore 环境", bundle: .module)
        case .resourceMissing(let name): String(localized: "缺少引用导出所需的资源文件：\(name)", bundle: .module)
        case .scriptFailed(let message): String(localized: "citeproc-js 出错：\(message)", bundle: .module)
        }
    }
}

/// Renders `CitationEntry` lists into formatted citations using citeproc-js
/// (GB/T 7714-2015, APA, IEEE, MLA, Chicago, Harvard, Vancouver, Nature) or the
/// pure-Swift `BibTeXWriter` (BibTeX).
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
            throw CSLRendererError.scriptFailed(String(localized: "citeproc-js 未导出 CSL.Engine", bundle: .module))
        }
        context.setObject(cslValue, forKeyedSubscript: "CSL" as NSString)
        self.engineConstructor = engineCtor

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
    /// numeric "[1]" bibliography label stripped. The other styles also get an
    /// HTML rendering that preserves italics (e.g. journal titles); numeric
    /// styles (IEEE, Vancouver, Nature) keep their labels.
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

        var lines = try bibliographyEntries(engine: engine).map(Self.cleanTextEntry)
        if style == .gbt7714 {
            lines = lines.map(Self.strippingNumericLabel)
        }
        let plainText = lines.joined(separator: "\n")

        var html: String?
        if style != .gbt7714 {
            engine.invokeMethod("setOutputFormat", withArguments: ["html"])
            try checkException()
            html = try bibliographyHTML(engine: engine)
        }

        return CitationOutput(plainText: plainText, html: html)
    }

    /// In-text citations for `entries` in `style`: one per entry (in the given order) plus one
    /// combined citation for all of them, e.g. "(Zhang & Gao, 2026)" / "[1]" and
    /// "(Qi, 2025; Zhang & Gao, 2026)" / "[1], [2]". Numeric styles number the entries in the given
    /// order, matching `render(_:style:)`. BibTeX gives LaTeX `\cite{key}` commands.
    public func inTextCitations(_ entries: [CitationEntry], style: CitationStyle) throws -> (each: [String], combined: String) {
        guard !entries.isEmpty else { return ([], "") }
        if style == .bibtex {
            let keys = entries.map(\.citationKey)
            return (keys.map { "\\cite{\($0)}" }, "\\cite{\(keys.joined(separator: ","))}")
        }
        let engine = try cachedEngine(for: style)
        var items: [String: [String: Any]] = [:]
        for entry in entries { items[entry.id] = CSLJSONMapper.csljson(id: entry.id, metadata: entry.metadata) }
        itemStore.items = items
        let ids = entries.map(\.id)
        lastException = nil
        engine.invokeMethod("setOutputFormat", withArguments: ["text"])
        engine.invokeMethod("updateItems", withArguments: [ids])
        try checkException()
        func cluster(_ ids: [String]) throws -> String {
            let citationItems = ids.map { ["id": $0] }
            guard let value = engine.invokeMethod("makeCitationCluster", withArguments: [citationItems]) else {
                throw CSLRendererError.scriptFailed(String(localized: "makeCitationCluster() 未返回结果", bundle: .module))
            }
            try checkException()
            return value.toString() ?? ""
        }
        return (try ids.map { try cluster([$0]) }, try cluster(ids))
    }

    // MARK: - Engine cache

    private func cachedEngine(for style: CitationStyle) throws -> JSValue {
        if let cached = engines[style] { return cached }
        guard let resource = style.cslResource else {
            throw CSLRendererError.resourceMissing("\(style.rawValue).csl")
        }
        let xml = try Self.loadResourceText(resource, extension: "csl")
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
                lastException ?? String(localized: "无法为样式 \(style.rawValue) 创建 CSL.Engine", bundle: .module))
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
            throw CSLRendererError.scriptFailed(String(localized: "makeBibliography() 未返回结果", bundle: .module))
        }
        try checkException()
        guard !result.isUndefined, !result.isNull else {
            throw CSLRendererError.scriptFailed(String(localized: "makeBibliography() 未返回结果", bundle: .module))
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

    /// One text-mode bibliography entry on one line: citeproc separates a numeric label from the
    /// reference with a tab or nothing (`second-field-align`), so "[1]Author" becomes "[1] Author".
    private static func cleanTextEntry(_ entry: String) -> String {
        var line = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        if let match = line.firstMatch(of: /^(\[\d+\]|\d+\.)(?=\S)/) {
            line.insert(" ", at: match.range.upperBound)
        }
        return line
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
