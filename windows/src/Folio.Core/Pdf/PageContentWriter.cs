using System.Globalization;
using System.Text;
using Folio.Core.Translate;
using Folio.Core.Translate.Pdf;
using UglyToad.PdfPig.Tokens;

namespace Folio.Core;

public static partial class AnnotationWriter
{
    /// <summary>A page's new content for <see cref="ReplacePageContent"/>: the objects to add (numbered from the number it
    /// was given), its content stream among them, its resources, and where the links of words that moved go.</summary>
    public sealed record PageContentUpdate(List<(int Number, byte[] Body)> Objects, int Contents, PdfValue Resources, Dictionary<int, List<Rect>> LinkPlaces);

    /// <summary>编辑 PDF 文字 (EDIT-01): page (1-based) given new content and resources as an incremental update — the page
    /// keeps its annotations and everything else, the rest of the file is not touched, and undoing is cutting the update
    /// off. make gets the first free object number.</summary>
    public static void ReplacePageContent(string path, int page, Func<long, PageContentUpdate> make)
    {
        Update(path, (document, pages, next, write) =>
        {
            IToken Resolve(IToken t) => t is IndirectReferenceToken r ? document.Structure.GetObject(r.Data).Data : t;
            static string Value(PdfValue value)
            {
                var ms = new MemoryStream();
                value.Serialize(ms);
                return Encoding.Latin1.GetString(ms.ToArray());
            }
            var info = pages(page);
            long first = next();
            var update = make(first);
            for (int k = 1; k < update.Objects.Count; k++) next();
            foreach (var (number, body) in update.Objects) write(number, Encoding.Latin1.GetString(body));

            // Links over words that moved: where the words are now.
            int linkIndex = -1;
            foreach (var token in info.Annots)
            {
                if (Resolve(token) is not DictionaryToken annot || !(annot.TryGet(NameToken.Subtype, out var subtype) && subtype is NameToken { Data: "Link" })) continue;
                linkIndex++;
                if (token is not IndirectReferenceToken reference || !update.LinkPlaces.TryGetValue(linkIndex, out var places) || places.Count == 0) continue;
                var bounds = places.Skip(1).Aggregate(places[0], (r, p) => r.Union(p));
                static string N(double v) => PdfValue.Format(v);
                var quads = string.Join(' ', places.Select(p => $"{N(p.MinX)} {N(p.MaxY)} {N(p.MaxX)} {N(p.MaxY)} {N(p.MinX)} {N(p.MinY)} {N(p.MaxX)} {N(p.MinY)}"));
                var dict = new StringBuilder("<<");
                foreach (var (key, value) in annot.Data.Where(kv => kv.Key is not "Rect" and not "QuadPoints"))
                    dict.Append('/').Append(EscapeName(key)).Append(' ').Append(Serialize(value)).Append(' ');
                dict.Append(CultureInfo.InvariantCulture, $"/Rect [{N(bounds.MinX)} {N(bounds.MinY)} {N(bounds.MaxX)} {N(bounds.MaxY)}] /QuadPoints [{quads}]>>");
                write(reference.Data.ObjectNumber, dict.ToString());
            }

            // The page: its new content and resources, everything else as it was.
            var page2 = new StringBuilder("<<");
            foreach (var (key, value) in info.Dictionary.Data.Where(kv => kv.Key is not "Contents" and not "Resources"))
                page2.Append('/').Append(EscapeName(key)).Append(' ').Append(Serialize(value)).Append(' ');
            page2.Append("/Resources ").Append(Value(update.Resources)).Append(CultureInfo.InvariantCulture, $" /Contents {update.Contents} 0 R>>");
            write(info.Number, page2.ToString());
            return [];
        });
    }
}
