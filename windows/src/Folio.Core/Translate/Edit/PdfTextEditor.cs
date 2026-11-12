using Folio.Core.Translate.Engine;
using Folio.Core.Translate.Layout;
using Folio.Core.Translate.Pdf;

namespace Folio.Core.Translate.Edit;

/// <summary>A block of text on a page that the PDF editor offers (EDIT-01): geometry in the page's user space (points,
/// origin bottom left); Text has {vN} for each formula kept as drawn.</summary>
public sealed record PdfTextBlock(int Page, int Index, double Left, double Bottom, double Right, double Top, string Text,
                                  double FontSize, double LineHeight, string Color, bool IsBold, bool IsItalic, bool IsSerif,
                                  string Alignment, bool IsEditable, string? Reason);

/// <summary>Edits the existing text of a PDF block by block (EDIT-01), on the translation engine as the macOS app does
/// (PDFTextEditor.swift): the layout analysis finds the blocks; replacing one renders the document with that block's
/// text set anew in its space — its size, colour and line spacing, smaller only when it does not fit — its glyphs taken
/// out of the page and everything else left as it was; formulas move with the {vN} placeholders standing for them.</summary>
public static class PdfTextEditor
{
    static LayoutAnalyzer Analyzer() => new(new LayoutAnalyzer.Options { TranslateTables = true, TranslateReferences = true });

    /// <summary>The page's layout with every block of text offered: the translator leaves some alone (author lines,
    /// figures' labels), the editor does not; formulas stay as they are.</summary>
    internal static PageLayout? Analyse(PdfSource source, int page)
    {
        var analyzer = Analyzer();
        // Headings and captions are told apart from the size most of the document's text is set in, not the page's.
        analyzer.KnownBodySize = BodySize(source);
        var layout = analyzer.Analyze(source, [page]).FirstOrDefault();
        if (layout == null) return null;
        // One block per paragraph (the translator's blocks run some together and cut others).
        layout.Blocks = EditParagraphs.Refine(layout.Blocks);
        foreach (var block in layout.Blocks) if (block.Kind != BlockKind.Formula) block.Translate = true;
        return layout;
    }

    static readonly System.Runtime.CompilerServices.ConditionalWeakTable<PdfSource, object> BodySizes = new();

    /// <summary>The size most text of the document is set in, from its first pages (as the macOS editor finds it).</summary>
    static double BodySize(PdfSource source)
    {
        if (BodySizes.TryGetValue(source, out var known)) return (double)known;
        var counts = new Dictionary<double, int>();
        int pages = Math.Min(source.Pages.Count, 8);
        for (int number = 1; number <= pages; number++)
        {
            var interpreter = new ContentInterpreter();
            interpreter.Run(source.Pages[number - 1]);
            foreach (var g in interpreter.Glyphs)
                if (g.IsVisible && g.IsHorizontal && g.Size > 0.5 && g.Size < 400)
                {
                    var key = Math.Round(g.Size * 2) / 2;
                    counts[key] = counts.GetValueOrDefault(key) + 1;
                }
        }
        double size = counts.Count == 0 ? 10 : counts.MaxBy(kv => kv.Value).Key;
        BodySizes.AddOrUpdate(source, size);
        return size;
    }

    /// <summary>The text blocks of page (1-based), in reading order.</summary>
    public static List<PdfTextBlock> Blocks(string path, int page)
    {
        using var source = PdfSource.Open(path);
        if (page < 1 || page > source.Pages.Count) return [];
        var layout = Analyse(source, page);
        return layout == null ? [] : Blocks(layout);
    }

    static List<PdfTextBlock> Blocks(PageLayout layout)
    {
        var result = new List<PdfTextBlock>();
        var all = SegmentBuilder.Segments(layout);
        var segments = all.Where(s => !s.IsLead).ToDictionary(s => s.Block);
        var leads = all.Where(s => s.IsLead).ToDictionary(s => s.Block);
        for (int index = 0; index < layout.Blocks.Count; index++)
        {
            var block = layout.Blocks[index];
            if (block.Lines.Count == 0) continue;
            segments.TryGetValue(index, out var segment);
            // The paragraph's text with the bold words it starts with ("Latent Path-Field Generation. Finally, …"); lines
            // are joined with a space, which Chinese and Japanese do not have between characters.
            var text = segment == null ? block.Text : Shown(segment, leads.GetValueOrDefault(index));
            text = EditParagraphs.ClosingCjkBreaks(text);
            if (text.Trim().Length == 0) continue;
            string? reason = null;
            if (segment == null) reason = block.Kind == BlockKind.Formula ? Loc.S("公式不能编辑") : Loc.S("这里的文字不能编辑");
            else if (TextSegmentHasOnlyFormulas(segment)) reason = Loc.S("公式不能编辑");
            var rect = block.Rect;
            var color = block.Color;
            string Hex(double v) => ((int)Math.Round(Math.Clamp(v, 0, 1) * 255)).ToString("X2");
            var font = block.Font;
            result.Add(new PdfTextBlock(layout.Number - 1, index, rect.X, rect.Y, rect.X + rect.Width, rect.Y + rect.Height, text,
                block.Size, block.Pitch, $"#{Hex(color.R)}{Hex(color.G)}{Hex(color.B)}", font.IsBold, font.IsItalic, font.IsSerif,
                block.IsCentered ? "center" : block.Lines.Count > 2 ? "justified" : "left", reason == null, reason));
        }
        return result;
    }

    /// <summary>What the user edits: a run-in heading, then the paragraph, its placeholders numbered after the heading's
    /// (as the renderer numbers them).</summary>
    static string Shown(TextSegment body, TextSegment? lead) =>
        lead == null ? body.Source : lead.Source + " " + Placeholders.Replace(body.Source, n => TextSegment.Placeholder(n + lead.Formulas.Count));

    static bool TextSegmentHasOnlyFormulas(TextSegment segment) =>
        System.Text.RegularExpressions.Regex.Replace(segment.Source, @"\{v\d+\}", "").Trim().Length == 0;

    /// <summary>The file with block index of page (1-based) set to text. expected is the block's text as the user saw it:
    /// when the block reads differently now (the file changed), nothing is written.</summary>
    public static byte[] Replace(string path, int page, int index, string expected, string text)
    {
        using var source = PdfSource.Open(path);
        if (page < 1 || page > source.Pages.Count) throw new InvalidOperationException(Loc.S("这段文字已经变了，请重新选择"));
        var layout = Analyse(source, page) ?? throw new InvalidOperationException(Loc.S("这段文字已经变了，请重新选择"));
        var segments = SegmentBuilder.Segments(layout);
        var segment = segments.FirstOrDefault(s => !s.IsLead && s.Block == index);
        var lead = segments.FirstOrDefault(s => s.IsLead && s.Block == index);
        if (segment == null || EditParagraphs.ClosingCjkBreaks(Shown(segment, lead)) != expected) throw new InvalidOperationException(Loc.S("这段文字已经变了，请重新选择"));
        text = text.Replace("\r\n", "\n").Replace('\r', '\n');
        // Empty text takes the block away: a space is set, which draws nothing.
        var translations = new Dictionary<string, string>();
        if (lead != null)
        {
            // The run-in heading stays bold while the text still starts with it; the renderer numbers the paragraph's
            // placeholders after the heading's, so they go back to its own numbers. Otherwise it all becomes the paragraph.
            int shift = lead.Formulas.Count;
            if (text.StartsWith(lead.Source, StringComparison.Ordinal))
            {
                translations[lead.Id] = lead.Source;
                text = Placeholders.Replace(text[lead.Source.Length..].TrimStart(), n => TextSegment.Placeholder(Math.Max(1, n - shift)));
            }
            else translations[lead.Id] = " ";
        }
        translations[segment.Id] = text.Trim().Length == 0 ? " " : text;
        // Every page goes into the output; only the edited one is analysed (the others are copied as they are).
        var layouts = Enumerable.Range(1, source.Pages.Count).Select(n =>
        {
            if (n == page) return layout;
            var geometry = PdfComposer.Geometry(source.Pages[n - 1]);
            return new PageLayout { Number = n, MediaBox = geometry.MediaBox, CropBox = geometry.CropBox };
        }).ToList();
        var renderer = new TranslationRenderer(source, Language(text)) { KeepLineSpacing = true };
        var output = renderer.Render(layouts, segments, translations, true, false, TranslationOptions.DualLayouts.sideBySide, null);
        return output.Mono ?? throw new InvalidOperationException(Loc.S("无法写入修改"));
    }

    /// <summary>The language the new text is in, for its fonts: Chinese, Japanese or Korean when it has their characters.</summary>
    static string Language(string text)
    {
        if (text.Any(c => c is >= '぀' and <= 'ヿ')) return "ja";
        if (text.Any(c => c is >= '가' and <= '힯')) return "ko";
        if (text.Any(c => c is >= '一' and <= '鿿')) return "zh";
        return "en";
    }
}
