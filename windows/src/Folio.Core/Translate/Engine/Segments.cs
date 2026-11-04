using System.Text;
using System.Text.RegularExpressions;
using Folio.Core.Translate.Layout;

namespace Folio.Core.Translate.Engine;

// Port of macos/.../FolioTranslate/Engine/Segments.swift.

/// <summary>An inline formula kept as drawn: where it is on the original page.</summary>
public sealed class FormulaSpan
{
    public Rect Rect;
    public double Baseline;
    public HashSet<int> Runs = [];
    public double Size = 10;
    public List<int> Glyphs = [];
    public List<SpanLink> Links = [];
    public Rect Ink = Rect.Null;
    public List<FormulaSpan> Continuation = [];
    public bool Spaced;
    public List<int> Icons = [];
    public IEnumerable<SpanLink> AllLinks => Links.Concat(Continuation.SelectMany(c => c.Links));
}

/// <summary>One unit sent for translation: the text of a block, with formulas replaced by {v1}, {v2} …</summary>
public sealed class TextSegment
{
    public int Page;
    public int Block;
    public BlockKind Kind;
    public string Source = "";
    public List<FormulaSpan> Formulas = [];
    public bool IsLead;
    public string Id => IsLead ? $"{Page}-{Block}-lead" : $"{Page}-{Block}";
    public static string Placeholder(int n) => $"{{v{n}}}";
}

public static partial class SegmentBuilder
{
    /// <summary>The segments of a page. Blocks already in the script of target need no translation.</summary>
    public static List<TextSegment> Segments(PageLayout layout, string target = "")
    {
        var result = new List<TextSegment>();
        for (int index = 0; index < layout.Blocks.Count; index++)
        {
            var block = layout.Blocks[index];
            if (!block.Translate) continue;
            var (text, formulas, lead) = TextOf(block);
            if (!HasWords(text) && !HasWords(lead?.Text ?? "")) continue;
            if (IsInScript(target, (lead?.Text ?? "") + " " + text)) continue;
            if (lead is { } l) result.Add(new TextSegment { Page = layout.Number, Block = index, Kind = BlockKind.Heading, Source = l.Text, Formulas = l.Formulas, IsLead = true });
            result.Add(new TextSegment { Page = layout.Number, Block = index, Kind = block.Kind, Source = text, Formulas = formulas });
        }
        return result;
    }

    /// <summary>The segments of a document; one written in the target's script has nothing to translate.</summary>
    public static List<TextSegment> Segments(List<PageLayout> layouts, string target)
    {
        var all = layouts.SelectMany(l => Segments(l)).ToList();
        if (IsInScript(target, string.Join(" ", all.Select(s => s.Source)), 0.3)) return [];
        return layouts.SelectMany(l => Segments(l, target)).ToList();
    }

    [GeneratedRegex(@"\{v\d+\}")]
    private static partial Regex PlaceholderPattern();

    public static bool HasWords(string text) => PlaceholderPattern().Replace(text, "").EnumerateRunes().Any(System.Text.Rune.IsLetter);

    /// <summary>Whether most letters of text are already in the script of the language target.</summary>
    public static bool IsInScript(string target, string text, double share = 0.5)
    {
        var language = target.ToLowerInvariant();
        (int, int)[] ranges;
        if (language.StartsWith("zh")) ranges = [(0x4E00, 0x9FFF), (0x3400, 0x4DBF)];
        else if (language.StartsWith("ja")) ranges = [(0x4E00, 0x9FFF), (0x3040, 0x30FF)];
        else if (language.StartsWith("ko")) ranges = [(0xAC00, 0xD7AF)];
        else return false;
        int letters = 0, inScript = 0;
        foreach (var r in PlaceholderPattern().Replace(text, "").EnumerateRunes())
        {
            if (!System.Text.Rune.IsLetter(r)) continue;
            if (r.Value is >= 0xFF21 and <= 0xFF5A) continue;
            letters++;
            if (ranges.Any(x => r.Value >= x.Item1 && r.Value <= x.Item2)) inScript++;
        }
        return letters > 0 && inScript >= letters * share;
    }

    static readonly Dictionary<string, string> Ligatures = new() { ["ﬁ"] = "fi", ["ﬂ"] = "fl", ["ﬀ"] = "ff", ["ﬃ"] = "ffi", ["ﬄ"] = "ffl", ["ﬅ"] = "st", ["ﬆ"] = "st" };

    public sealed record Lead(string Text, List<FormulaSpan> Formulas);

    /// <summary>The block's text with formulas as placeholders; a heading run into its first line comes apart.</summary>
    public static (string Text, List<FormulaSpan> Formulas, Lead? Lead) TextOf(LayoutBlock block)
    {
        var output = new StringBuilder();
        var formulas = new List<FormulaSpan>();
        Lead? leadParts = null;
        (int Target, bool Spaced)? openLink = null;
        var (held, breaks) = LinkText.Held(block);
        var lead = RunInHeading(block, held);
        for (int index = 0; index < block.Lines.Count; index++)
        {
            var line = block.Lines[index];
            var chars = line.Chars;
            int i = 0;
            while (i < chars.Count)
            {
                var c = chars[i];
                if (lead is { } ld && index == ld.Line && i == ld.End + 1)
                {
                    leadParts = new Lead(output.ToString().Trim(' '), formulas);
                    output.Clear();
                    formulas = [];
                }
                if (held[index][i] && !c.IsSpace)
                {
                    var rect = c.GlyphBox;
                    var ink = c.InkBox;
                    var runs = c.Run is { } run0 ? new HashSet<int> { run0 } : [];
                    var glyphs = new List<int>(c.Glyphs);
                    var linkRects = c.Link is { } l0 ? new Dictionary<int, Rect> { [l0] = c.GlyphBox } : [];
                    var icons = c.Icon is { } ic ? new List<int> { ic } : [];
                    int j = i;
                    while (j + 1 < chars.Count && held[index][j + 1] && !breaks[index].Contains(j + 1))
                    {
                        j++;
                        var cj = chars[j];
                        if (cj.IsSpace) continue;
                        rect = rect.Union(cj.GlyphBox);
                        ink = ink.Union(cj.InkBox);
                        if (cj.Run is { } r) runs.Add(r);
                        glyphs.AddRange(cj.Glyphs);
                        if (cj.Icon is { } icon) icons.Add(icon);
                        if (cj.Link is { } link) linkRects[link] = linkRects.TryGetValue(link, out var existing) ? existing.Union(cj.GlyphBox) : cj.GlyphBox;
                    }
                    var links = linkRects.Count == 1 ? [new SpanLink(linkRects.First().Key, rect)]
                        : linkRects.Select(kv => new SpanLink(kv.Key, kv.Value)).OrderBy(s => s.Link).ToList();
                    glyphs.Sort();
                    var span = new FormulaSpan { Rect = rect, Baseline = line.Baseline, Runs = runs, Size = line.Size, Glyphs = glyphs, Links = links, Ink = ink, Icons = icons };
                    if (links.Count > 0 && rect.W > line.Size * 5 && chars.Skip(i).Take(j - i + 1).All(x => !x.IsMath) && WordPieces(chars.GetRange(i, j - i + 1), line) is { } first)
                        span = first;
                    if (openLink is { } open && c.LinkTarget == open.Target && formulas.Count > 0 && chars.Take(i).All(x => x.IsSpace))
                    {
                        span.Spaced = open.Spaced;
                        var more = span.Continuation;
                        span.Continuation = [];
                        formulas[^1].Continuation.Add(span);
                        formulas[^1].Continuation.AddRange(more);
                    }
                    else
                    {
                        formulas.Add(span);
                        output.Append(TextSegment.Placeholder(formulas.Count));
                    }
                    openLink = null;
                    if ((j == chars.Count - 1 || chars.Skip(j + 1).All(x => x.IsSpace))
                        && chars.Skip(i).Take(j - i + 1).LastOrDefault(x => x.LinkTarget != null)?.LinkTarget is { } target)
                    {
                        var last = chars[j].Text;
                        openLink = (target, !(last.EndsWith('-') || last.EndsWith('–') || last.EndsWith('—')));
                    }
                    i = j + 1;
                    continue;
                }
                if (!c.IsSpace) openLink = null;
                if (c.IsSpace) { if (output.Length == 0 || output[^1] != ' ') output.Append(' '); }
                else output.Append(Ligatures.GetValueOrDefault(c.Text) ?? c.Text);
                i++;
            }
            if (index >= block.Lines.Count - 1) break;
            var nextText = block.Lines[index + 1].Text;
            var current = output.ToString();
            if (current.EndsWith('-') && current.Length >= 2 && char.IsLetter(current[^2]))
            {
                var word = current[..^1].Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? "";
                if (nextText.Length > 0 && char.IsLower(nextText[0]) && !word.Contains('-') && !word.Contains('/')) output.Length--;
            }
            else if (output.Length == 0 || output[^1] != ' ') output.Append(' ');
        }
        return (output.ToString().Trim(' '), formulas, leadParts);
    }

    /// <summary>A held stretch of words as a first word and the others as its continuation.</summary>
    static FormulaSpan? WordPieces(List<PageChar> chars, LayoutLine line)
    {
        var pieces = new List<FormulaSpan>();
        var current = new List<PageChar>();
        void Close()
        {
            if (current.Count == 0) return;
            var rect = current[0].GlyphBox;
            var ink = current[0].InkBox;
            foreach (var c in current.Skip(1)) { rect = rect.Union(c.GlyphBox); ink = ink.Union(c.InkBox); }
            var links = current.Where(c => c.Link != null).Select(c => c.Link!.Value).Distinct().OrderBy(x => x).Select(l => new SpanLink(l, rect)).ToList();
            pieces.Add(new FormulaSpan
            {
                Rect = rect, Baseline = line.Baseline, Runs = current.Where(c => c.Run != null).Select(c => c.Run!.Value).ToHashSet(), Size = line.Size,
                Glyphs = current.SelectMany(c => c.Glyphs).OrderBy(g => g).ToList(), Links = links, Ink = ink, Spaced = true,
            });
            current = [];
        }
        foreach (var c in chars) { if (c.IsSpace) Close(); else current.Add(c); }
        Close();
        if (pieces.Count <= 1) return null;
        var first = pieces[0];
        first.Continuation = pieces.Skip(1).ToList();
        return first;
    }

    /// <summary>The bold words a paragraph starts with, up to the punctuation ending them, when the rest is in another type.</summary>
    public static (int Line, int End)? RunInHeading(LayoutBlock block, List<bool[]> held)
    {
        if (block.Kind != BlockKind.Paragraph || block.Lines.Count < 2 || block.Font.IsBold) return null;
        var chars = block.Lines[0].Chars;
        if (chars.FirstOrDefault(c => !c.IsSpace) is not { } first || !first.Font.IsBold) return null;
        int end = -1, words = 1;
        for (int k = 0; k < chars.Count; k++)
        {
            var c = chars[k];
            if (c.IsSpace) { words++; continue; }
            if (!c.Font.IsBold && !held[0][k]) break;
            end = k;
        }
        if (end < 0 || words > 14) return null;
        while (end >= 0 && chars[end].IsSpace) end--;
        var rest = chars.Skip(end + 1).Where(c => !c.IsSpace).ToList();
        if (rest.Count == 0 || rest.Count(c => c.Font.IsBold) * 4 > rest.Count || chars[end].Text.Length == 0 || !".:：。—–-?".Contains(chars[end].Text[^1])) return null;
        return (0, end);
    }
}

/// <summary>Section headings every paper has, in Chinese (machine translation gets them wrong).</summary>
public static partial class StandardHeadings
{
    static readonly Dictionary<string, (string Hans, string Hant)> Chinese = new()
    {
        ["abstract"] = ("摘要", "摘要"), ["introduction"] = ("引言", "引言"), ["related work"] = ("相关工作", "相關工作"), ["related works"] = ("相关工作", "相關工作"),
        ["background"] = ("背景", "背景"), ["method"] = ("方法", "方法"), ["methods"] = ("方法", "方法"), ["methodology"] = ("方法", "方法"), ["approach"] = ("方法", "方法"),
        ["proposed method"] = ("所提方法", "所提方法"), ["experiments"] = ("实验", "實驗"), ["experiment"] = ("实验", "實驗"), ["experimental results"] = ("实验结果", "實驗結果"),
        ["results"] = ("结果", "結果"), ["results and discussion"] = ("结果与讨论", "結果與討論"), ["discussion"] = ("讨论", "討論"), ["conclusion"] = ("结论", "結論"),
        ["conclusions"] = ("结论", "結論"), ["conclusion and future work"] = ("结论与展望", "結論與展望"), ["limitations"] = ("局限性", "局限性"), ["references"] = ("参考文献", "參考文獻"),
        ["acknowledgments"] = ("致谢", "致謝"), ["acknowledgements"] = ("致谢", "致謝"), ["acknowledgment"] = ("致谢", "致謝"), ["appendix"] = ("附录", "附錄"),
        ["keywords"] = ("关键词", "關鍵詞"), ["index terms"] = ("关键词", "關鍵詞"), ["datasets"] = ("数据集", "數據集"), ["implementation details"] = ("实现细节", "實現細節"),
        ["ablation study"] = ("消融实验", "消融實驗"), ["ablation studies"] = ("消融实验", "消融實驗"), ["preliminaries"] = ("预备知识", "預備知識"), ["overview"] = ("概述", "概述"),
        ["article info"] = ("文章信息", "文章資訊"), ["a b s t r a c t"] = ("摘要", "摘要"), ["a r t i c l e i n f o"] = ("文章信息", "文章資訊"),
    };

    [GeneratedRegex(@"^\s*((?:\d+(?:\.\d+)*\.?|[IVX]+\.|[A-Z]\.)\s+)?(.+?)\s*[:.]?\s*$")]
    private static partial Regex Pattern();

    /// <summary>The heading in language, keeping its number ("3. Experiments" → "3. 实验"); null when not a standard one.</summary>
    public static string? Translate(string text, string language)
    {
        var lang = language.ToLowerInvariant();
        if (!lang.StartsWith("zh")) return null;
        var m = Pattern().Match(text);
        if (!m.Success) return null;
        var number = m.Groups[1].Success ? m.Groups[1].Value : "";
        if (!Chinese.TryGetValue(m.Groups[2].Value.ToLowerInvariant(), out var value)) return null;
        return number + (lang is "zh-tw" or "zh-hant" ? value.Hant : value.Hans);
    }
}

/// <summary>Words of table headers machine translation gets wrong out of context ("Mean" → "意思是").</summary>
public static class StandardCells
{
    static readonly Dictionary<string, string> Chinese = new()
    {
        ["mean"] = "平均", ["average"] = "平均", ["avg"] = "平均", ["avg."] = "平均", ["method"] = "方法", ["methods"] = "方法",
        ["ours"] = "本文方法", ["ours (full)"] = "本文方法（完整）", ["backbone"] = "骨干网络", ["arch."] = "架构", ["architecture"] = "架构",
        ["params"] = "参数量", ["params."] = "参数量", ["parameters"] = "参数量", ["dataset"] = "数据集", ["datasets"] = "数据集",
        ["setting"] = "设置", ["settings"] = "设置", ["baseline"] = "基线", ["model"] = "模型", ["models"] = "模型", ["year"] = "年份",
        ["venue"] = "来源", ["source"] = "源域", ["target"] = "目标域", ["time"] = "时间", ["memory"] = "显存", ["accuracy"] = "准确率",
        ["total"] = "总计", ["type"] = "类型", ["input"] = "输入", ["output"] = "输出", ["training"] = "训练", ["inference"] = "推理",
    };

    public static string? Translate(string text, string language) =>
        language.ToLowerInvariant().StartsWith("zh") ? Chinese.GetValueOrDefault(text.Trim().ToLowerInvariant()) : null;
}

public static partial class HeadingNumbers
{
    [GeneratedRegex(@"^\s*(\d+(?:\.\d+)*\.?)\s+")]
    private static partial Regex Number();

    /// <summary>"4.1.实验装置" → "4.1. 实验装置": the source's number keeps its space.</summary>
    public static string RestoreSpace(string source, string translation)
    {
        var m = Number().Match(source);
        if (!m.Success) return translation;
        var prefix = m.Groups[1].Value;
        if (!translation.StartsWith(prefix, StringComparison.Ordinal) || translation[prefix.Length..].StartsWith(' ')) return translation;
        return prefix + " " + translation[prefix.Length..].Trim(' ');
    }
}
