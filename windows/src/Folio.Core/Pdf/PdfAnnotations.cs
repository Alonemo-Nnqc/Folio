using System.Globalization;
using System.Text;
using UglyToad.PdfPig;
using UglyToad.PdfPig.Annotations;
using UglyToad.PdfPig.Core;
using UglyToad.PdfPig.Tokens;

namespace Folio.Core;

/// <summary>An annotation in a PDF, for the inspector's 标注 list and the AI tools.</summary>
public sealed record PdfAnnotation(int Page, string Kind, string ColorHex, string? Text, string? Comment, string? Author, DateTime? Modified);

/// <summary>Reads markup annotations (highlights, notes, text boxes, drawings) and the text they cover.</summary>
public static class PdfAnnotations
{
    public static List<PdfAnnotation> Read(string path)
    {
        var result = new List<PdfAnnotation>();
        try
        {
            using var document = PdfDocument.Open(path);
            for (int p = 1; p <= document.NumberOfPages; p++)
            {
                var page = document.GetPage(p);
                foreach (var a in page.GetAnnotations())
                {
                    var kind = a.Type switch
                    {
                        AnnotationType.Highlight => "highlight",
                        AnnotationType.Underline => "underline",
                        AnnotationType.StrikeOut => "strikeOut",
                        AnnotationType.Squiggly => "squiggly",
                        AnnotationType.Text => "note",
                        AnnotationType.FreeText => "textBox",
                        AnnotationType.Ink => "ink",
                        _ => null,
                    };
                    if (kind == null) continue;
                    string? covered = null;
                    if (a.QuadPoints.Count > 0)
                    {
                        var sb = new StringBuilder();
                        foreach (var quad in a.QuadPoints)
                        {
                            var rect = Bounds(quad);
                            foreach (var letter in page.Letters)
                            {
                                var c = letter.BoundingBox.Centroid;
                                if (c.X >= rect.Left && c.X <= rect.Right && c.Y >= rect.Bottom && c.Y <= rect.Top) sb.Append(letter.Value);
                            }
                            sb.Append(' ');
                        }
                        covered = Text.CollapseWhitespace(sb.ToString());
                    }
                    var comment = Text.NonEmpty(a.Content);
                    string? author = a.AnnotationDictionary.TryGet(NameToken.T, out StringToken? t) ? t.Data : null;
                    result.Add(new PdfAnnotation(p, kind, Color(a), Text.NonEmpty(covered), comment, author, null));
                }
            }
        }
        catch { }
        return result;
    }

    static PdfRectangle Bounds(QuadPointsQuadrilateral quad)
    {
        double left = double.MaxValue, bottom = double.MaxValue, right = double.MinValue, top = double.MinValue;
        foreach (var p in quad.Points)
        {
            left = Math.Min(left, p.X); right = Math.Max(right, p.X);
            bottom = Math.Min(bottom, p.Y); top = Math.Max(top, p.Y);
        }
        return new PdfRectangle(left, bottom, right, top);
    }

    static string Color(Annotation a)
    {
        if (a.AnnotationDictionary.TryGet(NameToken.C, out ArrayToken? c) && c.Data.Count == 3)
        {
            var v = c.Data.OfType<NumericToken>().Select(n => (int)Math.Round(Math.Clamp(n.Double, 0, 1) * 255)).ToList();
            if (v.Count == 3) return $"#{v[0]:X2}{v[1]:X2}{v[2]:X2}";
        }
        return a.Type == AnnotationType.Highlight ? "#FFD60A" : "#FF9F0A";
    }
}
