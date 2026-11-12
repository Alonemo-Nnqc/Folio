using System.Text.RegularExpressions;
using Folio.Core.Translate.Layout;

namespace Folio.Core.Translate.Edit;

/// <summary>The page's blocks as the PDF editor offers them (EDIT-01): one block per paragraph. The layout analysis is
/// tuned for translation, which tolerates blocks that run two paragraphs together or stop a line short; editing does
/// not, so they are cut and joined again here, by the rules of the macOS editor (EditParagraphs.swift): cut before a line
/// that starts a paragraph (a first-line indent after a short line), a line far below or in another size (a page number
/// swept in), after a heading on its own line; joined when a block goes on from another (same column and size, one line
/// below, not set in, the line before full or mid-sentence), a two-line title, a caption's next line.</summary>
public static partial class EditParagraphs
{
    static readonly HashSet<BlockKind> Fixed = [BlockKind.Formula, BlockKind.Figure, BlockKind.TableCell, BlockKind.Rotated, BlockKind.Code, BlockKind.Header];
    static readonly HashSet<BlockKind> Joinable = [BlockKind.Paragraph, BlockKind.Caption, BlockKind.Reference, BlockKind.Other, BlockKind.Author];
    const string Terminal = ".。!！?？:：;；…";

    [GeneratedRegex(@"(?<=[\p{IsCJKUnifiedIdeographs}぀-ヿ가-힯　-〿＀-￯]) (?=[\p{IsCJKUnifiedIdeographs}぀-ヿ가-힯　-〿＀-￯])")]
    private static partial Regex CjkBreak();

    [GeneratedRegex(@"[\]\)）」”""'\s\d,\-–]+$")]
    private static partial Regex Trailing();

    /// <summary>A space between two CJK characters taken out: where a line broke inside Chinese text.</summary>
    public static string ClosingCjkBreaks(string text) => CjkBreak().Replace(text, "");

    static bool EndsSentence(LayoutLine line)
    {
        var text = line.Text.Trim();
        var stripped = Trailing().Replace(text, "");
        var s = stripped.Length == 0 ? text : stripped;
        return s.Length > 0 && Terminal.Contains(s[^1]);
    }

    /// <summary>Whether a line reads as words rather than math: two Chinese characters, or two words of letters.</summary>
    static bool IsWordy(LayoutLine line)
    {
        var text = line.Text;
        if (text.Count(c => c is >= '一' and <= '鿿') >= 2) return true;
        return Regex.Split(text, @"[^\p{L}]+").Count(w => w.Length >= 3) >= 2;
    }

    static bool IsCaptionStart(LayoutLine line)
    {
        var start = line.Text.Trim();
        return new[] { "图", "表", "Fig", "Table", "TABLE", "FIG" }.Any(p => start.StartsWith(p, StringComparison.Ordinal));
    }

    public static List<LayoutBlock> Refine(List<LayoutBlock> blocks)
    {
        // Text taken for a formula or for part of a figure (a caption full of labels, a line with a superscript citation).
        foreach (var block in blocks)
        {
            if (block.Kind is not (BlockKind.Formula or BlockKind.Figure) || !block.Lines.All(IsWordy)) continue;
            if (IsCaptionStart(block.Lines[0])) block.Kind = BlockKind.Caption;
            else if (block.Kind == BlockKind.Formula) block.Kind = BlockKind.Paragraph;
        }
        return Join(blocks.SelectMany(Cut).ToList());
    }

    // Cutting

    static List<LayoutBlock> Cut(LayoutBlock block)
    {
        if (block.Lines.Count < 2 || Fixed.Contains(block.Kind)) return [block];
        var lines = block.Lines;
        double size = block.Size, pitch = block.Pitch;
        double left = lines.Min(l => l.MinX), right = lines.Max(l => l.MaxX);
        bool centered = block.IsCentered;
        bool hanging = block.HangingIndent > 0 && lines[0].MaxX >= right - size * 1.5;
        var pieces = new List<List<LayoutLine>> { new() { lines[0] } };
        for (int i = 1; i < lines.Count; i++)
        {
            var previous = lines[i - 1];
            var line = lines[i];
            bool starts = previous.Baseline - line.Baseline > Math.Max(pitch * 1.75, size * 2.4);
            if (!starts && Math.Abs(previous.Size - line.Size) > 0.8 && line.MaxX - line.MinX < (right - left) * 0.3) starts = true;
            if (!starts && (previous.Size - line.Size > 0.8 || (previous.Font.IsBold && !line.Font.IsBold))
                && (previous.MaxX < right - size * 2 || (pieces[^1].Count == 1 && previous.Font.IsBold)))
                starts = true;
            if (!starts && centered && (previous.Font.IsItalic != line.Font.IsItalic || previous.Font.IsBold != line.Font.IsBold)) starts = true;
            if (!starts && !centered)
            {
                double indent = line.MinX - left;
                bool shortLine = previous.MaxX < right - size * 1.5;
                if (indent > size * 0.6 && indent < size * 4.5 && (shortLine || EndsSentence(previous)) && !hanging
                    && (Math.Abs(previous.MinX - left) < size * 0.6 || shortLine))
                    starts = true;
            }
            if (starts) pieces.Add([line]); else pieces[^1].Add(line);
        }
        if (pieces.Count == 1) return [block];
        return pieces.Select(piece =>
        {
            var part = block.Clone();
            part.Lines = piece;
            if (piece.Count == 1 && piece[0].Font.IsBold && piece[0].MaxX < right - size * 2 && block.Kind == BlockKind.Paragraph) part.Kind = BlockKind.Heading;
            return part;
        }).ToList();
    }

    // Joining

    static List<LayoutBlock> Join(List<LayoutBlock> blocks)
    {
        var result = new List<LayoutBlock>(blocks);
        bool changed = true;
        while (changed)
        {
            changed = false;
            for (int b = 0; b < result.Count && !changed; b++)
                for (int a = 0; a < result.Count; a++)
                {
                    if (a == b || !Continues(result[a], result[b])) continue;
                    result[a].Lines.AddRange(result[b].Lines);
                    result.RemoveAt(b);
                    changed = true;
                    break;
                }
        }
        return result;
    }

    static bool ContinuesTitle(LayoutBlock a, LayoutBlock b)
    {
        if (a.Kind != b.Kind || a.Kind is not (BlockKind.Title or BlockKind.Heading)) return false;
        var last = a.Lines[^1];
        var first = b.Lines[0];
        double size = a.Size;
        if (Math.Abs(size - b.Size) > 0.5 || last.Font.IsBold != first.Font.IsBold || last.Font.IsItalic != first.Font.IsItalic || EndsSentence(last)) return false;
        double gap = last.Baseline - first.Baseline;
        if (gap <= size * 0.9 || gap >= size * 1.6) return false;
        Rect ra = a.Rect, rb = b.Rect;
        return Math.Abs(ra.MidX - rb.MidX) < size || Math.Abs(ra.MinX - rb.MinX) < size * 0.5;
    }

    static bool Continues(LayoutBlock a, LayoutBlock b)
    {
        if (ContinuesTitle(a, b)) return true;
        bool wordyFormula = b.Kind == BlockKind.Formula && b.Lines.Count == 1
            && (b.Lines[0].MathRatio < 0.5 || b.Lines[0].Text.Any(c => c is >= '一' and <= '鿿'))
            && b.Rect.W < a.Rect.W * 0.5;
        bool captionLine = a.Kind == BlockKind.Caption && b.Kind == BlockKind.Figure && b.Lines.All(IsWordy);
        if (!Joinable.Contains(a.Kind) || !(Joinable.Contains(b.Kind) || wordyFormula || captionLine)) return false;
        var last = a.Lines[^1];
        var first = b.Lines[0];
        if (last.IsRotated || first.IsRotated) return false;
        double size = a.Size;
        if (Math.Abs(size - b.Size) > 0.6 || last.Font.IsBold != first.Font.IsBold) return false;
        Rect ra = a.Rect, rb = b.Rect;
        double overlap = Math.Min(ra.MaxX, rb.MaxX) - Math.Max(ra.MinX, rb.MinX);
        if (overlap <= Math.Min(ra.W, rb.W) * 0.7) return false;
        double pitch = a.Lines.Count > 1 ? a.Pitch : b.Lines.Count > 1 ? b.Pitch : size * 1.25;
        double gap = last.Baseline - first.Baseline;
        if (gap <= pitch * 0.6 || gap >= pitch * 1.35) return false;
        double left = a.Lines.Min(l => l.MinX);
        if (first.MinX - left >= size * 0.5) return false;
        double right = Math.Max(ra.MaxX, rb.MaxX);
        return last.MaxX >= right - size * 1.5 || !EndsSentence(last);
    }
}
