import CoreGraphics
import Foundation

/// An inline formula kept as drawn: where it is on the original page.
struct FormulaSpan: Sendable, Hashable {
    var rect: CGRect
    var baseline: Double
    /// The text operators (indexes into the page's runs) that drew it.
    var runs: Set<Int> = []
    /// The size of the text around it.
    var size: Double = 10
    /// Its glyphs (indexes into the page's glyphs), drawn again where the formula goes.
    var glyphs: [Int] = []
    /// The links on it: they follow it to wherever the translation puts it.
    var links: [SpanLink] = []
    /// Where its ink is, from the shapes of its characters.
    var ink: CGRect = .null
    /// The rest of a citation broken over lines: set right after it wherever the translation puts it.
    var continuation: [FormulaSpan] = []
    /// A word space goes between this piece and the one before it.
    var spaced = false
    /// Pictures set among the words (indexes into the page's marks), drawn again where it goes.
    var icons: [Int] = []

    /// The links on it and its continuation.
    var allLinks: [SpanLink] { links + continuation.flatMap(\.links) }
}

/// One unit sent for translation: the text of a block, with formulas replaced by `{v1}`, `{v2}` …
struct TextSegment: Sendable, Hashable {
    var page: Int
    var block: Int
    var kind: BlockKind
    var source: String
    var formulas: [FormulaSpan]
    /// The block's heading set in its first line ("Datasets. We use …"): translated apart and set in bold before
    /// the rest of the block.
    var isLead = false

    var id: String { isLead ? "\(page)-\(block)-lead" : "\(page)-\(block)" }
    /// Placeholder for formula `n` (1-based).
    static func placeholder(_ n: Int) -> String { "{v\(n)}" }
}

enum SegmentBuilder {
    /// The segments of a page. Blocks already in the script of `target` need no translation and stay as they are.
    static func segments(for layout: PageLayout, target: String = "") -> [TextSegment] {
        layout.blocks.enumerated().flatMap { index, block -> [TextSegment] in
            guard block.translate else { return [] }
            let (text, formulas, lead) = text(of: block)
            // Nothing left to translate around its formulas and citations: the block stays as it is.
            guard hasWords(text) || hasWords(lead?.text ?? "") else { return [] }
            guard !isInScript(of: target, (lead?.text ?? "") + " " + text) else { return [] }
            var result: [TextSegment] = []
            if let lead {
                result.append(TextSegment(page: layout.number, block: index, kind: .heading, source: lead.text, formulas: lead.formulas, isLead: true))
            }
            result.append(TextSegment(page: layout.number, block: index, kind: block.kind, source: text, formulas: formulas))
            return result
        }
    }

    /// The segments of a document. One written in the target's script has nothing to translate, not even its
    /// stray lines of Latin letters (formulas, names).
    static func segments(for layouts: [PageLayout], target: String) -> [TextSegment] {
        let all = layouts.flatMap { segments(for: $0) }
        // Papers in another language have hardly any of these letters; here a third is plenty (formulas and names count too).
        guard !isInScript(of: target, all.map(\.source).joined(separator: " "), share: 0.3) else { return [] }
        return layouts.flatMap { segments(for: $0, target: target) }
    }

    private static func hasWords(_ text: String) -> Bool {
        text.replacingOccurrences(of: #"\{v\d+\}"#, with: "", options: .regularExpression).contains(where: \.isLetter)
    }

    /// Whether most letters of `text` are already in the script of the language `target`.
    static func isInScript(of target: String, _ text: String, share: Double = 0.5) -> Bool {
        let language = target.lowercased()
        let ranges: [ClosedRange<UInt32>]
        if language.hasPrefix("zh") {
            ranges = [0x4E00...0x9FFF, 0x3400...0x4DBF]
        } else if language.hasPrefix("ja") {
            ranges = [0x4E00...0x9FFF, 0x3040...0x30FF]
        } else if language.hasPrefix("ko") {
            ranges = [0xAC00...0xD7AF]
        } else {
            return false
        }
        var letters = 0, inScript = 0
        for scalar in text.replacingOccurrences(of: #"\{v\d+\}"#, with: "", options: .regularExpression).unicodeScalars where scalar.properties.isAlphabetic {
            // Full-width Latin letters only occur in text set in these scripts.
            if (0xFF21...0xFF5A).contains(scalar.value) { continue }
            letters += 1
            if ranges.contains(where: { $0.contains(scalar.value) }) { inScript += 1 }
        }
        return letters > 0 && Double(inScript) >= Double(letters) * share
    }

    private static let ligatures: [String: String] = ["ﬁ": "fi", "ﬂ": "fl", "ﬀ": "ff", "ﬃ": "ffi", "ﬄ": "ffl", "ﬅ": "st", "ﬆ": "st"]

    /// The block's text with formulas as placeholders; lines joined, words hyphenated across lines rejoined. A heading
    /// run into its first line comes apart, with its own text and formulas.
    static func text(of block: LayoutBlock) -> (String, [FormulaSpan], (text: String, formulas: [FormulaSpan])?) {
        var out = ""
        var formulas: [FormulaSpan] = []
        var leadParts: (text: String, formulas: [FormulaSpan])?
        // The link the last formula ended in, while nothing but a line break has come after it.
        var openLink: (target: Int, spaced: Bool)?
        let (held, breaks) = LinkText.held(in: block)
        let lead = runInHeading(of: block, held: held)
        for (index, line) in block.lines.enumerated() {
            let chars = line.chars
            var i = 0
            while i < chars.count {
                let c = chars[i]
                if let lead, index == lead.line, i == lead.end + 1 {
                    leadParts = (out.trimmingCharacters(in: .whitespaces), formulas)
                    out = ""
                    formulas = []
                }
                if held[index][i] && !c.isSpace {
                    var rect = c.glyphBox
                    var ink = c.inkBox
                    var runs: Set<Int> = c.run.map { [$0] } ?? []
                    var glyphs = c.glyphs
                    var linkRects: [Int: CGRect] = c.link.map { [$0: c.glyphBox] } ?? [:]
                    var icons: [Int] = c.icon.map { [$0] } ?? []
                    var j = i
                    while j + 1 < chars.count, held[index][j + 1], !breaks[index].contains(j + 1) {
                        j += 1
                        if !chars[j].isSpace {
                            rect = rect.union(chars[j].glyphBox)
                            ink = ink.union(chars[j].inkBox)
                            if let run = chars[j].run { runs.insert(run) }
                            glyphs += chars[j].glyphs
                            if let icon = chars[j].icon { icons.append(icon) }
                            if let link = chars[j].link { linkRects[link] = linkRects[link]?.union(chars[j].glyphBox) ?? chars[j].glyphBox }
                        }
                    }
                    // A single link is clickable over the whole citation, brackets too.
                    let links = linkRects.count == 1 ? [SpanLink(link: linkRects.first!.key, rect: rect)]
                        : linkRects.map { SpanLink(link: $0.key, rect: $0.value) }.sorted { $0.link < $1.link }
                    var span = FormulaSpan(rect: rect, baseline: line.baseline, runs: runs, size: line.size, glyphs: glyphs.sorted(), links: links, ink: ink, icons: icons)
                    // A long citation in words may run over a line break, word by word, still as one placeholder.
                    if !links.isEmpty, rect.width > line.size * 5, chars[i...j].allSatisfy({ !$0.isMath }), let first = wordPieces(chars[i...j], line: line) {
                        span = first
                    }
                    if let open = openLink, c.linkTarget == open.target, !formulas.isEmpty, chars[..<i].allSatisfy(\.isSpace) {
                        // The same citation going on from the line before: one placeholder for both, so nothing can come between.
                        span.spaced = open.spaced
                        let more = span.continuation
                        span.continuation = []
                        formulas[formulas.count - 1].continuation.append(span)
                        formulas[formulas.count - 1].continuation += more
                    } else {
                        formulas.append(span)
                        out += TextSegment.placeholder(formulas.count)
                    }
                    openLink = nil
                    if j == chars.count - 1 || chars[(j + 1)...].allSatisfy(\.isSpace), let target = chars[i...j].last(where: { $0.linkTarget != nil })?.linkTarget {
                        let last = chars[j].text
                        openLink = (target, !(last.hasSuffix("-") || last.hasSuffix("–") || last.hasSuffix("—")))
                    }
                    i = j + 1
                    continue
                }
                if !c.isSpace { openLink = nil }
                if c.isSpace {
                    if !out.hasSuffix(" ") { out += " " }
                } else {
                    out += ligatures[c.text] ?? c.text
                }
                i += 1
            }
            guard index < block.lines.count - 1 else { break }
            let next = block.lines[index + 1].text.first
            if out.hasSuffix("-"), out.dropLast().last?.isLetter == true {
                // A word hyphenated at the line's end comes together; a compound ("state-of-the-" "art", "Contrast-" "Driven")
                // or an address keeps its hyphen, without a space.
                let word = out.dropLast().split(whereSeparator: \.isWhitespace).last ?? ""
                if next?.isLowercase == true, !word.contains("-"), !word.contains("/") { out.removeLast() }
            } else if !out.hasSuffix(" ") {
                out += " "
            }
        }
        return (out.trimmingCharacters(in: .whitespaces), formulas, leadParts)
    }

    /// A held stretch of words as a first word and the others as its continuation.
    private static func wordPieces(_ chars: ArraySlice<PageChar>, line: LayoutLine) -> FormulaSpan? {
        var pieces: [FormulaSpan] = []
        var current: [PageChar] = []
        func close() {
            guard let head = current.first else { return }
            var rect = head.glyphBox, ink = head.inkBox
            for c in current.dropFirst() {
                rect = rect.union(c.glyphBox)
                ink = ink.union(c.inkBox)
            }
            let links = Set(current.compactMap(\.link)).sorted().map { SpanLink(link: $0, rect: rect) }
            pieces.append(FormulaSpan(rect: rect, baseline: line.baseline, runs: Set(current.compactMap(\.run)), size: line.size,
                                      glyphs: current.flatMap(\.glyphs).sorted(), links: links, ink: ink, spaced: true))
            current = []
        }
        for c in chars {
            if c.isSpace { close() } else { current.append(c) }
        }
        close()
        guard pieces.count > 1 else { return nil }
        var first = pieces.removeFirst()
        first.continuation = pieces
        return first
    }

    /// The bold words a paragraph starts with, up to the punctuation ending them ("Datasets." "Loss function:"), when
    /// the rest is in another type: where the first line's last character of them is.
    static func runInHeading(of block: LayoutBlock, held: [[Bool]]) -> (line: Int, end: Int)? {
        guard block.kind == .paragraph, block.lines.count >= 2, !block.font.isBold else { return nil }
        let chars = block.lines[0].chars
        guard let first = chars.first(where: { !$0.isSpace }), first.font.isBold else { return nil }
        var end = -1
        var words = 1
        for (k, c) in chars.enumerated() {
            if c.isSpace {
                words += 1
                continue
            }
            if !c.font.isBold && !held[0][k] { break }
            end = k
        }
        guard end >= 0, words <= 14 else { return nil }
        while end >= 0, chars[end].isSpace { end -= 1 }
        // The rest of the line has to be in the other type, and the bold has to end like a heading.
        let rest = chars[(end + 1)...].filter { !$0.isSpace }
        guard !rest.isEmpty, rest.filter({ $0.font.isBold }).count * 4 <= rest.count, let last = chars[end].text.last,
              ".:：。—–-?".contains(last) else { return nil }
        return (0, end)
    }
}

/// Section headings every paper has, in Chinese: machine translation services get them wrong ("Abstract" →
/// "抽象的"), so they are set from this list.
enum StandardHeadings {
    static let chinese: [String: String] = [
        "abstract": "摘要", "introduction": "引言", "related work": "相关工作", "related works": "相关工作",
        "background": "背景", "method": "方法", "methods": "方法", "methodology": "方法", "approach": "方法",
        "proposed method": "所提方法", "experiments": "实验", "experiment": "实验", "experimental results": "实验结果",
        "results": "结果", "results and discussion": "结果与讨论", "discussion": "讨论", "conclusion": "结论",
        "conclusions": "结论", "conclusion and future work": "结论与展望", "limitations": "局限性", "references": "参考文献",
        "acknowledgments": "致谢", "acknowledgements": "致谢", "acknowledgment": "致谢", "appendix": "附录",
        "keywords": "关键词", "index terms": "关键词", "datasets": "数据集", "implementation details": "实现细节",
        "ablation study": "消融实验", "ablation studies": "消融实验", "preliminaries": "预备知识", "overview": "概述",
        "article info": "文章信息", "a b s t r a c t": "摘要", "a r t i c l e i n f o": "文章信息",
    ]

    /// The heading in `language`, keeping its number ("3. Experiments" → "3. 实验"); nil when not a standard one.
    static func translate(_ text: String, to language: String) -> String? {
        guard language.lowercased().hasPrefix("zh") else { return nil }
        let pattern = #"^\s*((?:\d+(?:\.\d+)*\.?|[IVX]+\.|[A-Z]\.)\s+)?(.+?)\s*[:.]?\s*$"#
        guard let match = text.firstMatch(of: try! Regex(pattern)) else { return nil }
        let number = match.output[1].substring.map(String.init) ?? ""
        let name = (match.output[2].substring.map(String.init) ?? "").lowercased()
        guard var value = chinese[name] else { return nil }
        if language.lowercased() == "zh-tw" || language.lowercased() == "zh-hant" {
            value = value.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? value
        }
        return number + value
    }
}

/// Words of table headers machine translation gets wrong out of context ("Mean" → "意思是").
enum StandardCells {
    static let chinese: [String: String] = [
        "mean": "平均", "average": "平均", "avg": "平均", "avg.": "平均", "method": "方法", "methods": "方法",
        "ours": "本文方法", "ours (full)": "本文方法（完整）", "backbone": "骨干网络", "arch.": "架构", "architecture": "架构",
        "params": "参数量", "params.": "参数量", "parameters": "参数量", "dataset": "数据集", "datasets": "数据集",
        "setting": "设置", "settings": "设置", "baseline": "基线", "model": "模型", "models": "模型", "year": "年份",
        "venue": "来源", "source": "源域", "target": "目标域", "time": "时间", "memory": "显存", "accuracy": "准确率",
        "total": "总计", "type": "类型", "input": "输入", "output": "输出", "training": "训练", "inference": "推理",
    ]

    static func translate(_ text: String, to language: String) -> String? {
        guard language.lowercased().hasPrefix("zh") else { return nil }
        return chinese[text.trimmingCharacters(in: .whitespaces).lowercased()]
    }
}

enum HeadingNumbers {
    /// "4.1.实验装置" → "4.1. 实验装置": the source's number keeps its space.
    static func restoreSpace(source: String, translation: String) -> String {
        guard let number = source.firstMatch(of: /^\s*(\d+(?:\.\d+)*\.?)\s+/)?.output.1 else { return translation }
        let prefix = String(number)
        guard translation.hasPrefix(prefix), !translation.dropFirst(prefix.count).hasPrefix(" ") else { return translation }
        return prefix + " " + translation.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    }
}
