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
}

/// One unit sent for translation: the text of a block, with formulas replaced by `{v1}`, `{v2}` …
struct TextSegment: Sendable, Hashable {
    var page: Int
    var block: Int
    var kind: BlockKind
    var source: String
    var formulas: [FormulaSpan]

    var id: String { "\(page)-\(block)" }
    /// Placeholder for formula `n` (1-based).
    static func placeholder(_ n: Int) -> String { "{v\(n)}" }
}

enum SegmentBuilder {
    static func segments(for layout: PageLayout) -> [TextSegment] {
        layout.blocks.enumerated().compactMap { index, block in
            guard block.translate else { return nil }
            let (text, formulas) = text(of: block)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return TextSegment(page: layout.number, block: index, kind: block.kind, source: text, formulas: formulas)
        }
    }

    private static let ligatures: [String: String] = ["ﬁ": "fi", "ﬂ": "fl", "ﬀ": "ff", "ﬃ": "ffi", "ﬄ": "ffl", "ﬅ": "st", "ﬆ": "st"]

    /// The block's text with formulas as placeholders; lines joined, words hyphenated across lines rejoined.
    static func text(of block: LayoutBlock) -> (String, [FormulaSpan]) {
        var out = ""
        var formulas: [FormulaSpan] = []
        for (index, line) in block.lines.enumerated() {
            let chars = line.chars
            var i = 0
            while i < chars.count {
                let c = chars[i]
                if c.isMath && !c.isSpace {
                    var rect = c.glyphBox
                    var runs: Set<Int> = c.run.map { [$0] } ?? []
                    var j = i
                    while j + 1 < chars.count, chars[j + 1].isMath {
                        j += 1
                        if !chars[j].isSpace {
                            rect = rect.union(chars[j].glyphBox)
                            if let run = chars[j].run { runs.insert(run) }
                        }
                    }
                    formulas.append(FormulaSpan(rect: rect, baseline: line.baseline, runs: runs, size: line.size))
                    out += TextSegment.placeholder(formulas.count)
                    i = j + 1
                    continue
                }
                if c.isSpace {
                    if !out.hasSuffix(" ") { out += " " }
                } else {
                    out += ligatures[c.text] ?? c.text
                }
                i += 1
            }
            guard index < block.lines.count - 1 else { break }
            let next = block.lines[index + 1].text.first
            if out.hasSuffix("-"), out.dropLast().last?.isLetter == true, next?.isLowercase == true {
                out.removeLast()
            } else if !out.hasSuffix(" ") {
                out += " "
            }
        }
        return (out.trimmingCharacters(in: .whitespaces), formulas)
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
