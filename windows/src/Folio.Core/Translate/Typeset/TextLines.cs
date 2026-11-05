using System.Collections.Concurrent;
using System.Text;
using HarfBuzzSharp;
using SkiaSharp;
using SkiaSharp.HarfBuzz;

namespace Folio.Core.Translate.Typeset;

// What Core Text does for the macOS engine: fonts with fallback, shaping (HarfBuzz), line breaking, justification,
// ink bounds and drawing (Skia, whose PDF backend embeds subsets of the fonts with their text).

/// <summary>A formula set among the words: room on the line, nothing drawn.</summary>
public sealed class InlineObject
{
    public double Ascent, Descent, Width;
    /// <summary>The formula (1-based) and which piece of it (0: the first).</summary>
    public int Formula, Piece;
}

/// <summary>Fonts for translated text: a Latin face like the paper's (Times or Arial) with the target script's
/// system font behind it for everything Latin fonts lack.</summary>
public static class FontCatalog
{
    public sealed record Face(SKTypeface Typeface, bool Embolden);

    static readonly ConcurrentDictionary<string, Face?> Faces = new();

    static readonly string[] LatinSerif = ["Times New Roman", "Times", "Liberation Serif", "DejaVu Serif"];
    static readonly string[] LatinSans = ["Arial", "Helvetica", "Liberation Sans", "DejaVu Sans"];

    public static Face Latin(bool serif, bool bold) =>
        Find(serif ? LatinSerif : LatinSans, bold) ?? new Face(SKTypeface.Default, bold);

    public static Face? Script(string language, bool bold, bool serif) =>
        ScriptFamilies(language, serif) is { } families ? Find(families, bold) : null;

    public static string[]? ScriptFamilies(string language, bool serif) => language.ToLowerInvariant() switch
    {
        "zh" or "zh-cn" or "zh-hans" or "zh-sg" => serif
            ? ["SimSun", "Songti SC", "STSong", "Noto Serif CJK SC", "Source Han Serif SC"]
            : ["Microsoft YaHei", "PingFang SC", "Noto Sans CJK SC", "Source Han Sans SC"],
        "zh-tw" or "zh-hk" or "zh-hant" => serif
            ? ["PMingLiU", "MingLiU", "Songti TC", "Noto Serif CJK TC"]
            : ["Microsoft JhengHei", "PingFang TC", "Noto Sans CJK TC"],
        "ja" => serif ? ["Yu Mincho", "Hiragino Mincho ProN", "MS Mincho"] : ["Yu Gothic", "Hiragino Sans", "Meiryo"],
        "ko" => serif ? ["Batang", "AppleMyungjo", "Malgun Gothic"] : ["Malgun Gothic", "Apple SD Gothic Neo"],
        "ar" => ["Segoe UI", "Arial", "Geeza Pro"],
        "th" => ["Leelawadee UI", "Tahoma", "Thonburi"],
        "hi" => ["Nirmala UI", "Kohinoor Devanagari", "Mangal"],
        _ => null,
    };

    static Face? Find(string[] families, bool bold)
    {
        foreach (var family in families)
        {
            var face = Faces.GetOrAdd(family + "|" + bold, _ =>
            {
                var typeface = SKFontManager.Default.MatchFamily(family, bold ? SKFontStyle.Bold : SKFontStyle.Normal);
                if (typeface == null) return null;
                return new Face(typeface, bold && typeface.FontWeight < 600);
            });
            if (face != null) return face;
        }
        return null;
    }

    /// <summary>The face for a character none of the chosen faces has.</summary>
    public static Face Fallback(int codepoint, bool bold, string language)
    {
        return Faces.GetOrAdd($"#{codepoint >> 8}|{bold}|{language}", _ =>
        {
            var typeface = SKFontManager.Default.MatchCharacter(null, bold ? SKFontStyle.Bold : SKFontStyle.Normal, [language], codepoint);
            return typeface == null ? null : new Face(typeface, bold && typeface.FontWeight < 600);
        }) is { } face && face.Typeface.ContainsGlyph(codepoint) ? face
            : SKFontManager.Default.MatchCharacter(null, SKFontStyle.Normal, [language], codepoint) is { } any ? new Face(any, bold)
            : Latin(false, bold);
    }

    static readonly ConcurrentDictionary<SKTypeface, (HarfBuzzSharp.Font Font, int UnitsPerEm)> Shapers = new();

    internal static (HarfBuzzSharp.Font Font, int UnitsPerEm) Shaper(SKTypeface typeface) => Shapers.GetOrAdd(typeface, t =>
    {
        using var stream = t.OpenStream(out int index);
        var blob = stream.ToHarfBuzzBlob();
        var face = new HarfBuzzSharp.Face(blob, index);
        int upem = Math.Max(t.UnitsPerEm, 16);
        face.UnitsPerEm = upem;
        var font = new HarfBuzzSharp.Font(face);
        font.SetScale(upem, upem);
        font.SetFunctionsOpenType();
        return (font, upem);
    });
}

/// <summary>Glyphs of a stretch of text in one face, in units of the em.</summary>
internal sealed class ShapedRun
{
    public int Start, End;
    public FontCatalog.Face? Face;
    public bool Rtl;
    public bool IsObject;
    public ushort[] Glyphs = [];
    public int[] Clusters = [];
    public double[] Advances = [], OffsetX = [], OffsetY = [];
    /// <summary>Ink of each glyph, y down, per em.</summary>
    public SKRect[] Bounds = [];
}

/// <summary>A paragraph shaped once, in units of the em, for every size it is tried at.</summary>
internal sealed class Shaped
{
    public string Text = "";
    public double[] Advance = [];
    public List<ShapedRun> Runs = [];
    public bool[] BreakBefore = [];

    static readonly ConcurrentDictionary<string, Shaped> Cache = new();

    public static Shaped Of(string text, bool[] bold, string language, bool serif)
    {
        var key = new StringBuilder().Append(language).Append('|').Append(serif ? 's' : 'n').Append('|');
        foreach (var b in bold) key.Append(b ? '1' : '0');
        key.Append('|').Append(text);
        var k = key.ToString();
        if (Cache.TryGetValue(k, out var hit)) return hit;
        var shaped = Make(text, bold, language, serif);
        if (Cache.Count > 4000) Cache.Clear();
        Cache[k] = shaped;
        return shaped;
    }

    static Shaped Make(string text, bool[] bold, string language, bool serif)
    {
        var s = new Shaped { Text = text, Advance = new double[text.Length], BreakBefore = LineBreaks.Opportunities(text) };
        var lang = language.Split('-')[0];
        int i = 0;
        while (i < text.Length)
        {
            if (text[i] == '￼')
            {
                s.Runs.Add(new ShapedRun { Start = i, End = i + 1, IsObject = true });
                i++;
                continue;
            }
            bool b = bold[i];
            var latin = FontCatalog.Latin(serif, b);
            var script = FontCatalog.Script(language, b, serif);
            FontCatalog.Face FaceFor(int cp) =>
                latin.Typeface.ContainsGlyph(cp) ? latin
                : script != null && script.Typeface.ContainsGlyph(cp) ? script
                : FontCatalog.Fallback(cp, b, lang);
            int start = i;
            int first = Utf.At(text, i);
            // A run starting with a space or a joiner takes the face of what follows.
            int probe = i;
            while (probe < text.Length && text[probe] != '\uFFFC' && IsNeutral(text, probe)) probe++;
            var face = FaceFor(probe < text.Length && text[probe] != '\uFFFC' ? Utf.At(text, probe) : 'a');
            i += first > 0xFFFF ? 2 : 1;
            while (i < text.Length && text[i] != '￼' && bold[i] == b)
            {
                int cp = Utf.At(text, i);
                // Spaces, joiners and marks go with what they follow.
                bool neutral = IsNeutral(text, i);
                if (!neutral && !face.Typeface.ContainsGlyph(cp) || !neutral && face != latin && latin.Typeface.ContainsGlyph(cp) && FaceFor(cp) != face) break;
                i += cp > 0xFFFF ? 2 : 1;
            }
            s.Runs.Add(Shape(text, start, i, face, lang, s.Advance));
        }
        return s;
    }

    static bool IsNeutral(string text, int i) =>
        text[i] is ' ' or '\u00A0' or '\u200B' or '\u2060' or '\u200D' or '\uFE0F'
        || char.GetUnicodeCategory(text, i) is System.Globalization.UnicodeCategory.NonSpacingMark
            or System.Globalization.UnicodeCategory.EnclosingMark or System.Globalization.UnicodeCategory.Format;

    static ShapedRun Shape(string text, int start, int end, FontCatalog.Face face, string language, double[] advance)
    {
        var (font, upem) = FontCatalog.Shaper(face.Typeface);
        using var buffer = new HarfBuzzSharp.Buffer();
        buffer.AddUtf16(text.AsSpan(), start, end - start);
        buffer.GuessSegmentProperties();
        try { buffer.Language = new Language(language); } catch { }
        font.Shape(buffer);
        var infos = buffer.GetGlyphInfoSpan();
        var positions = buffer.GetGlyphPositionSpan();
        int n = infos.Length;
        var run = new ShapedRun
        {
            Start = start, End = end, Face = face, Rtl = buffer.Direction == Direction.RightToLeft,
            Glyphs = new ushort[n], Clusters = new int[n], Advances = new double[n], OffsetX = new double[n], OffsetY = new double[n],
        };
        for (int g = 0; g < n; g++)
        {
            run.Glyphs[g] = (ushort)infos[g].Codepoint;
            run.Clusters[g] = (int)infos[g].Cluster;
            run.Advances[g] = positions[g].XAdvance / (double)upem;
            run.OffsetX[g] = positions[g].XOffset / (double)upem;
            run.OffsetY[g] = positions[g].YOffset / (double)upem;
            int c = Math.Clamp(run.Clusters[g], start, end - 1);
            run.Clusters[g] = c;
            advance[c] += run.Advances[g];
        }
        using var skFont = new SKFont(face.Typeface, 1000) { Hinting = SKFontHinting.None, Subpixel = true, LinearMetrics = true, Embolden = face.Embolden };
        var widths = new float[n];
        var bounds = new SKRect[n];
        skFont.GetGlyphWidths(run.Glyphs, widths, bounds);
        run.Bounds = bounds.Select(r => new SKRect(r.Left / 1000, r.Top / 1000, r.Right / 1000, r.Bottom / 1000)).ToArray();
        return run;
    }
}

static class Utf
{
    public static int At(string s, int i) =>
        char.IsHighSurrogate(s[i]) && i + 1 < s.Length && char.IsLowSurrogate(s[i + 1]) ? char.ConvertToUtf32(s[i], s[i + 1]) : s[i];
}

/// <summary>Where lines may break: after spaces, between Chinese and Japanese characters (not before closing
/// punctuation, not after opening brackets), around formulas, after dashes and hyphens in compounds.</summary>
public static class LineBreaks
{
    const string NoStart = ",.;:!?)]}%、。，．：；！？）］｝〉》」』】〕〗〙〛’”…‥・ー〜ゝゞ々ぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮヵヶ⁠ ";
    const string NoEnd = "([{（［｛〈《「『【〔〖〘〚‘“⁠ ";

    public static bool IsCJK(char c) => c is >= '⺀' and <= '鿿' or >= '가' and <= '힯' or >= '豈' and <= '﫿'
        or >= '＀' and <= '￯' or >= '　' and <= '〿';

    public static bool[] Opportunities(string t)
    {
        var result = new bool[t.Length + 1];
        for (int i = 1; i < t.Length; i++)
        {
            char a = t[i - 1], b = t[i];
            if (char.IsLowSurrogate(b)) continue;
            if (b == ' ' || b == '　' && a != ' ') { result[i] = false; continue; }
            if (NoStart.Contains(b) || NoEnd.Contains(a)) continue;
            if (a is ' ' or '　' or '​') { result[i] = true; continue; }
            if (a == '￼' || b == '￼') { result[i] = true; continue; }
            if (IsCJK(a) || IsCJK(b)) { result[i] = true; continue; }
            if (a is '—' or '–' or '/' && char.IsLetterOrDigit(b)) { result[i] = true; continue; }
            if (a == '-' && i >= 2 && char.IsLetter(t[i - 2]) && char.IsLetter(b)) result[i] = true;
        }
        return result;
    }
}

/// <summary>A paragraph at one size: what Core Text's attributed string and typesetter are to the macOS engine.</summary>
public sealed class Paragraph
{
    internal readonly Shaped Shaped;
    public readonly double FontSize;
    public readonly InlineObject?[] Objects;
    public readonly RGBColor Color;

    public string Text => Shaped.Text;
    public int Length => Shaped.Text.Length;

    public Paragraph(string text, bool[] bold, InlineObject?[] objects, string language, bool serif, double fontSize, RGBColor color)
    {
        Shaped = Shaped.Of(text, bold, language, serif);
        Objects = objects;
        FontSize = fontSize;
        Color = color;
    }

    public double Advance(int i) => Text[i] == '￼' ? Objects[i]?.Width ?? 0 : Shaped.Advance[i] * FontSize;

    static bool IsWhite(char c) => c is ' ' or '　' or '​' or '\t';

    /// <summary>How many characters from <paramref name="start"/> go on a line <paramref name="width"/> wide.</summary>
    public int SuggestLineBreak(int start, double width)
    {
        double x = 0;
        int lastBreak = -1;
        int i = start;
        for (; i < Length; i++)
        {
            if (i > start && Shaped.BreakBefore[i]) lastBreak = i;
            double a = Advance(i);
            if (!IsWhite(Text[i]) && i > start && x + a > width + 1e-6) break;
            x += a;
        }
        if (i >= Length) return Length - start;
        if (lastBreak > start) return lastBreak - start;
        if (char.IsLowSurrogate(Text[i]) && i - 1 > start) i--;
        return Math.Max(1, i - start);
    }

    public TextLine Line(int start, int count) => new(this, start, count, new double[count]);
}

/// <summary>One line of a paragraph, as Core Text's CTLine.</summary>
public sealed class TextLine
{
    public readonly Paragraph Paragraph;
    public readonly int Start, Length;
    /// <summary>Space added after each character (kerning, justification).</summary>
    readonly double[] _extra;

    internal TextLine(Paragraph paragraph, int start, int length, double[] extra)
    {
        Paragraph = paragraph;
        Start = start;
        Length = length;
        _extra = extra;
    }

    public string Text => Paragraph.Text.Substring(Start, Length);

    public double TypographicWidth
    {
        get
        {
            double w = 0;
            for (int k = 0; k < Length; k++) w += Paragraph.Advance(Start + k) + _extra[k];
            return w;
        }
    }

    public double TrailingWhitespaceWidth
    {
        get
        {
            double w = 0;
            for (int k = Length - 1; k >= 0 && Paragraph.Text[Start + k] is ' ' or '　' or '​' or '\t'; k--)
                w += Paragraph.Advance(Start + k) + _extra[k];
            return w;
        }
    }

    public double NaturalWidth => TypographicWidth - TrailingWhitespaceWidth;

    /// <summary>The line with `extra[k]` more after character k.</summary>
    public TextLine WithExtra(IReadOnlyDictionary<int, double> extra)
    {
        var e = (double[])_extra.Clone();
        foreach (var (k, v) in extra) if (k >= 0 && k < Length) e[k] += v;
        return new TextLine(Paragraph, Start, Length, e);
    }

    /// <summary>As CTLineCreateJustifiedLine: stretched to <paramref name="width"/>, at the spaces where it has some.</summary>
    public TextLine? Justified(double width)
    {
        double extra = width - NaturalWidth;
        if (extra <= 0.01) return null;
        int end = Length;
        while (end > 0 && Paragraph.Text[Start + end - 1] is ' ' or '　' or '​') end--;
        int begin = 0;
        while (begin < end && Paragraph.Text[Start + begin] == ' ') begin++;
        var spaces = Enumerable.Range(begin, Math.Max(0, end - begin)).Where(k => Paragraph.Text[Start + k] == ' ').ToList();
        if (spaces.Count == 0)
            spaces = Enumerable.Range(begin, Math.Max(0, end - 1 - begin)).Where(k => !char.IsHighSurrogate(Paragraph.Text[Start + k])).ToList();
        if (spaces.Count == 0) return null;
        double each = extra / spaces.Count;
        return WithExtra(spaces.ToDictionary(k => k, _ => each));
    }

    public readonly record struct PlacedGlyphs(FontCatalog.Face Face, ushort[] Glyphs, SKPoint[] Positions, SKRect Ink);

    /// <summary>The glyphs of the line by face, positioned from its origin (y down), and where its formulas sit.</summary>
    public (List<PlacedGlyphs> Glyphs, List<(InlineObject Object, double X)> Objects) Layout()
    {
        var p = Paragraph;
        var size = p.FontSize;
        var cx = new double[Length + 1];
        for (int k = 0; k < Length; k++) cx[k + 1] = cx[k] + p.Advance(Start + k) + _extra[k];
        int end = Start + Length;
        var glyphs = new List<PlacedGlyphs>();
        var objects = new List<(InlineObject, double)>();
        foreach (var run in p.Shaped.Runs)
        {
            if (run.End <= Start || run.Start >= end) continue;
            if (run.IsObject)
            {
                if (p.Objects[run.Start] is { } o) objects.Add((o, cx[run.Start - Start]));
                continue;
            }
            var ids = new List<ushort>();
            var points = new List<SKPoint>();
            var ink = SKRect.Empty;
            bool any = false;
            void Add(int g, double x)
            {
                ids.Add(run.Glyphs[g]);
                var pt = new SKPoint((float)(x + run.OffsetX[g] * size), (float)(-run.OffsetY[g] * size));
                points.Add(pt);
                var b = run.Bounds[g];
                if (b.Width > 0 && b.Height > 0)
                {
                    var r = new SKRect(pt.X + b.Left * (float)size, pt.Y + b.Top * (float)size, pt.X + b.Right * (float)size, pt.Y + b.Bottom * (float)size);
                    ink = any ? SKRect.Union(ink, r) : r;
                    any = true;
                }
            }
            if (run.Rtl)
            {
                int from = Math.Max(run.Start, Start), to = Math.Min(run.End, end);
                double cursor = cx[from - Start];
                for (int g = 0; g < run.Glyphs.Length; g++)
                {
                    int c = run.Clusters[g];
                    if (c < from || c >= to) continue;
                    Add(g, cursor);
                    cursor += run.Advances[g] * size;
                }
            }
            else
            {
                var within = new Dictionary<int, double>();
                for (int g = 0; g < run.Glyphs.Length; g++)
                {
                    int c = run.Clusters[g];
                    if (c < Start || c >= end) continue;
                    within.TryGetValue(c, out var offset);
                    Add(g, cx[c - Start] + offset);
                    within[c] = offset + run.Advances[g] * size;
                }
            }
            if (ids.Count > 0) glyphs.Add(new PlacedGlyphs(run.Face!, ids.ToArray(), points.ToArray(), any ? ink : SKRect.Empty));
        }
        return (glyphs, objects);
    }

    /// <summary>How far the ink of its text reaches above and below the baseline (formulas not included).</summary>
    public (double Above, double Below) Ink()
    {
        double above = 0, below = 0;
        foreach (var g in Layout().Glyphs)
        {
            if (g.Ink.IsEmpty) continue;
            above = Math.Max(above, -g.Ink.Top);
            below = Math.Max(below, g.Ink.Bottom);
        }
        return (above, below);
    }

    /// <summary>Draws the text (not the formulas) with its baseline at (x, y) of a y-down canvas.</summary>
    public void Draw(SKCanvas canvas, double x, double y, HashSet<ushort>? used = null)
    {
        var c = Paragraph.Color;
        using var paint = new SKPaint { Color = new SKColor((byte)Math.Round(c.R * 255), (byte)Math.Round(c.G * 255), (byte)Math.Round(c.B * 255)), IsAntialias = true };
        foreach (var g in Layout().Glyphs)
        {
            using var font = new SKFont(g.Face.Typeface, (float)Paragraph.FontSize)
            {
                Hinting = SKFontHinting.None, Subpixel = true, LinearMetrics = true, Embolden = g.Face.Embolden,
            };
            used?.UnionWith(g.Glyphs);
            using var builder = new SKTextBlobBuilder();
            builder.AddPositionedRun(g.Glyphs, font, g.Positions);
            using var blob = builder.Build();
            if (blob != null) canvas.DrawText(blob, (float)x, (float)y, paint);
        }
    }
}
