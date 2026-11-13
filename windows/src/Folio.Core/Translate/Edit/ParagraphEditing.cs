using System.Text;
using Folio.Core.Translate.Engine;
using Folio.Core.Translate.Layout;
using Folio.Core.Translate.Pdf;
using Folio.Core.Translate.Typeset;
using SkiaSharp;

namespace Folio.Core.Translate.Edit;

/// <summary>A paragraph open for editing in place (EDIT-01), with what it needs while it is edited: the file read once,
/// the page's analysis and its drawing. Written into the file as an incremental update that changes only the page's
/// content (its annotations, links and everything else stay as they are), so undoing it is cutting the file back.</summary>
public sealed class ParagraphEditing : IDisposable
{
    public string Path { get; }
    /// <summary>1-based.</summary>
    public int PageNumber { get; }
    public PdfParagraph Paragraph { get; }
    readonly PdfSource _source;
    readonly PageLayout _layout;

    ParagraphEditing(string path, int pageNumber, PdfSource source, PageLayout layout, PdfParagraph paragraph)
    {
        Path = path;
        PageNumber = pageNumber;
        _source = source;
        _layout = layout;
        Paragraph = paragraph;
    }

    public void Dispose() => _source.Dispose();

    /// <summary>Block index of page (1-based) opened, or null when it cannot be edited in place.</summary>
    public static ParagraphEditing? Open(string path, int page, int index) => Open(path, File.ReadAllBytes(path), page, index);

    /// <summary>The same, from data: the file as read (the file itself is not kept open while it is edited).</summary>
    public static ParagraphEditing? Open(string path, byte[] data, int page, int index)
    {
        var source = PdfSource.Open(data);
        try
        {
            if (page < 1 || page > source.Pages.Count) { source.Dispose(); return null; }
            var layout = PdfTextEditor.Analyse(source, page);
            if (layout == null || index < 0 || index >= layout.Blocks.Count) { source.Dispose(); return null; }
            var block = layout.Blocks[index];
            if (block.Lines.Count == 0 || block.Lines.Any(l => l.IsRotated) || block.Kind is BlockKind.Formula or BlockKind.Figure or BlockKind.Rotated or BlockKind.Code)
            {
                source.Dispose();
                return null;
            }
            var interpreter = new ContentInterpreter();
            interpreter.Run(source.Pages[page - 1]);
            // Text drawn as a clipping path, or in Type 3 fonts, is not set again.
            foreach (var g in block.Lines.SelectMany(l => l.Chars).SelectMany(c => c.Glyphs).Where(g => g < interpreter.Glyphs.Count))
            {
                var glyph = interpreter.Glyphs[g];
                if (glyph.RenderMode >= 4 || glyph.Font >= 0 && glyph.Font < interpreter.Fonts.Count && interpreter.Fonts[glyph.Font].Dict.Name("Subtype") == "Type3")
                {
                    source.Dispose();
                    return null;
                }
            }
            var (_, formulas, lead) = SegmentBuilder.TextOf(block);
            var spans = lead is { } l ? [.. l.Formulas, .. formulas] : formulas;
            // How far down it may grow: to the top of what is under it in its column, else the lowest text of the page.
            var rect = block.Rect;
            var below = layout.Blocks.Where((_, k) => k != index).Select(b => b.Rect).Concat(layout.Figures).Concat(layout.Tables);
            var under = below.Where(o => o.MaxY <= rect.MinY + 1 && Math.Min(o.MaxX, rect.MaxX) - Math.Max(o.MinX, rect.MinX) > Math.Min(o.W, rect.W) * 0.3).ToList();
            double lowest = layout.Blocks.Count > 0 ? layout.Blocks.Min(b => b.Rect.MinY) : layout.MediaBox.MinY + 36;
            double floor = under.Count > 0 ? under.Max(o => o.MaxY) + 2 : Math.Min(lowest, rect.MinY);
            var paragraph = new PdfParagraph(page - 1, index, block, spans, interpreter, layout.MediaBox, floor);
            return new ParagraphEditing(path, page, source, layout, paragraph);
        }
        catch
        {
            source.Dispose();
            throw;
        }
    }

    // Preview

    /// <summary>The lines as they are now, as a one-page PDF in page space (only the glyphs of the lines drawn again), and
    /// where it paints over the page; null when nothing changed.</summary>
    public (byte[] Pdf, List<Rect> Paint)? Preview()
    {
        var drawing = Paragraph.Draw();
        if (drawing.Rewritten.Count == 0 && drawing.Glyphs.Count == 0) return null;
        var interpreter = Paragraph.Interpreter;
        var writer = new PdfWriter();
        var copier = new PdfCopier(writer, _source);
        var fonts = new Dictionary<string, PdfValue>();
        var names = new Dictionary<int, string>();
        var xobjects = new Dictionary<string, int>();
        var content = new StringBuilder(PdfParagraph.Content(drawing.Glyphs, font =>
        {
            if (names.TryGetValue(font, out var name)) return name;
            name = "P" + names.Count;
            names[font] = name;
            fonts[name] = copier.Copy(interpreter.Fonts[font].Dict);
            return name;
        }));
        content.Append(FormulaContent(drawing.Transplants, [], [], [], interpreter, copier, "PF", xobjects, fonts));
        if (FallbackForm(drawing.Fallback, writer) is { } form)
        {
            xobjects["PT"] = form;
            content.Append("q /PT Do Q\n");
        }
        var resources = new Dictionary<string, PdfValue> { ["Font"] = PdfValue.Dict(fonts) };
        if (xobjects.Count > 0) resources["XObject"] = PdfValue.Dict(xobjects.ToDictionary(kv => kv.Key, kv => PdfValue.Ref(kv.Value)));
        int pages = writer.Reserve();
        int contents = writer.AddStream([], Encoding.Latin1.GetBytes(content.ToString()));
        int pageObject = writer.Add(PdfValue.Dict(new Dictionary<string, PdfValue>
        {
            ["Type"] = PdfValue.Name("Page"), ["Parent"] = PdfValue.Ref(pages), ["MediaBox"] = PdfValue.RectValue(_layout.MediaBox),
            // The page's own crop box: the viewer places the preview by it.
            ["CropBox"] = PdfValue.RectValue(_layout.CropBox.IsNull || _layout.CropBox.IsEmpty ? _layout.MediaBox : _layout.CropBox),
            ["Resources"] = PdfValue.Dict(resources), ["Contents"] = PdfValue.Ref(contents),
        }));
        writer.Set(pages, PdfValue.Dict(new Dictionary<string, PdfValue>
        {
            ["Type"] = PdfValue.Name("Pages"), ["Kids"] = PdfValue.Array([PdfValue.Ref(pageObject)]), ["Count"] = PdfValue.Int(1),
        }));
        int root = writer.Add(PdfValue.Dict(new Dictionary<string, PdfValue> { ["Type"] = PdfValue.Name("Catalog"), ["Pages"] = PdfValue.Ref(pages) }));
        return (writer.Finish(root, null), drawing.Paint);
    }

    // Writing

    /// <summary>The edit written into the file: only the lines that changed are drawn again, with the page's own fonts;
    /// the page's content changes and nothing else. False when there was nothing to write.</summary>
    public bool Apply()
    {
        var drawing = Paragraph.Draw();
        if (!Paragraph.IsModified || drawing.Rewritten.Count == 0 && drawing.Glyphs.Count == 0) return false;
        var interpreter = Paragraph.Interpreter;
        var block = _layout.Blocks[Paragraph.Block];

        // 1. The glyphs of the lines drawn again leave the page; everything else stays.
        var kept = new HashSet<int>();
        for (int k = 0; k < _layout.Blocks.Count; k++)
            if (k != Paragraph.Block)
                foreach (var line in _layout.Blocks[k].Lines) foreach (var c in line.Chars) kept.UnionWith(c.Glyphs);
        for (int li = 0; li < block.Lines.Count; li++)
            if (!drawing.Rewritten.Contains(li))
                foreach (var c in block.Lines[li].Chars) kept.UnionWith(c.Glyphs);
        var removal = new PageRemoval { Kept = kept };
        foreach (var li in drawing.Rewritten.Where(li => li < block.Lines.Count).OrderBy(li => li))
        {
            var line = block.Lines[li];
            removal.Rects.Add(line.Rect.InsetBy(-0.5, -line.Size * 0.1));
            foreach (var c in line.Chars) removal.Glyphs.UnionWith(c.Glyphs);
        }
        removal.Glyphs.ExceptWith(kept);
        var removed = Enumerable.Range(0, interpreter.Glyphs.Count).Where(i => removal.Removes(interpreter.Glyphs[i], i)).ToHashSet();
        var edits = TranslationRenderer.GlyphEdits(interpreter, removed);
        var (droppedRules, chips) = GraphicEdits(interpreter, removal.Rects, drawing.Transplants, edits);

        // 2. The page's content again, as an update of the file: its drawing without those lines, then the lines.
        string token = Token();
        AnnotationWriter.ReplacePageContent(Path, PageNumber, first =>
        {
            var writer = new PdfWriter { Offset = (int)first - 1 };
            var copier = new PdfCopier(writer, _source) { InPlace = true };
            var editor = new ContentEditor(interpreter.Streams, edits, copier, $"FolioE{token}n");
            var (body, resources) = editor.PageContent();
            var content = new MemoryStream();
            content.Write("q\n"u8);
            content.Write(body);
            content.Write("\nQ\n"u8);
            var fonts = new Dictionary<string, PdfValue>();
            var names = new Dictionary<int, string>();
            content.Write(Encoding.Latin1.GetBytes(PdfParagraph.Content(drawing.Glyphs, font =>
            {
                if (names.TryGetValue(font, out var name)) return name;
                name = $"FolioE{token}g{names.Count}";
                names[font] = name;
                fonts[name] = copier.Copy(interpreter.Fonts[font].Dict);
                return name;
            })));
            var xobjects = new Dictionary<string, int>();
            var claimed = removal.Glyphs.Union(drawing.Transplants.SelectMany(t => t.Formula.Glyphs)).ToHashSet();
            var orphans = removed.Where(g => !claimed.Contains(g) && interpreter.Glyphs[g].IsVisible).ToHashSet();
            content.Write(Encoding.Latin1.GetBytes(FormulaContent(drawing.Transplants, orphans, droppedRules, chips, interpreter, copier, $"FolioE{token}", xobjects, fonts)));
            if (FallbackForm(drawing.Fallback, writer) is { } form)
            {
                xobjects[$"FolioE{token}T"] = form;
                content.Write(Encoding.Latin1.GetBytes($"q /FolioE{token}T Do Q\n"));
            }
            var pageResources = interpreter.Streams.GetValueOrDefault(StreamPath.Root)?.Resources;
            Merge(resources, "XObject", xobjects.ToDictionary(kv => kv.Key, kv => PdfValue.Ref(kv.Value)), pageResources, copier);
            Merge(resources, "Font", fonts, pageResources, copier);
            int contents = writer.AddStream([], content.ToArray());
            return new AnnotationWriter.PageContentUpdate(writer.Objects.ToList(), contents, PdfValue.Dict(resources), drawing.LinkPlaces);
        });
        return true;
    }

    /// <summary>resources[key] with extra entries added (the page's entry may be a reference to its dictionary).</summary>
    static void Merge(Dictionary<string, PdfValue> resources, string key, Dictionary<string, PdfValue> extra, PDict? source, PdfCopier copier)
    {
        if (extra.Count == 0) return;
        Dictionary<string, PdfValue> entries = [];
        if (resources.TryGetValue(key, out var existing) && existing.DictValue is { } d) entries = new(d);
        else if (source?.Dict(key) is { } own) entries = copier.Entries(own);
        foreach (var (name, value) in extra) entries[name] = value;
        resources[key] = PdfValue.Dict(entries);
    }

    static string Token()
    {
        const string letters = "abcdefghijkmnpqrstuvwxyz23456789";
        return string.Concat(Enumerable.Range(0, 5).Select(_ => letters[Random.Shared.Next(letters.Length)]));
    }

    /// <summary>Thin rules inside the lines taken out (a formula's bar), pictures among its words and coloured chips around
    /// formulas: dropped from the page, drawn again with the formulas they belong to.</summary>
    static (List<int> Rules, Dictionary<int, int> Chips) GraphicEdits(ContentInterpreter interpreter, List<Rect> rects, List<Transplant> transplants,
                                                                       Dictionary<OpLocation, EditAction> edits)
    {
        var rules = new List<int>();
        var formulaAreas = transplants.Select(t => t.Formula.Rect.InsetBy(-0.5, -t.Formula.Size * 0.15)).ToList();
        void Drop(GraphicMark mark)
        {
            for (int op = mark.OpStart; op <= mark.OpEnd; op++) edits[new OpLocation(mark.Location.Stream, op)] = EditAction.DropAction;
        }
        for (int m = 0; m < interpreter.Marks.Count; m++)
        {
            var mark = interpreter.Marks[m];
            if (mark.Kind == GraphicMark.MarkKind.Image || mark.IsWhite) continue;
            if (!(mark.Rect.H < 4 && rects.Any(r => r.InsetBy(-0.5, -0.5).Contains(mark.Rect)) || TranslationRenderer.IsRule(mark.Rect, formulaAreas))) continue;
            Drop(mark);
            rules.Add(m);
        }
        foreach (var transplant in transplants)
            foreach (var m in transplant.Formula.Icons.Where(m => m < interpreter.Marks.Count)) Drop(interpreter.Marks[m]);
        var chips = new Dictionary<int, int>();
        foreach (var transplant in transplants)
        {
            var formula = transplant.Formula;
            for (int m = 0; m < interpreter.Marks.Count; m++)
            {
                var mark = interpreter.Marks[m];
                if (mark.Kind != GraphicMark.MarkKind.Fill || mark.IsWhite || mark.HasCurves || chips.ContainsKey(m)) continue;
                if (!(mark.Rect.H >= 4 && mark.Rect.Contains(new Pt(formula.Rect.MidX, formula.Baseline + formula.Size * 0.25))
                      && mark.Rect.W < formula.Rect.W + formula.Size * 2 && mark.Rect.H < formula.Size * 2)) continue;
                chips[m] = formula.Glyphs.Count > 0 ? formula.Glyphs[0] : -1;
                Drop(mark);
            }
        }
        return (rules, chips);
    }

    /// <summary>The formulas of the lines drawn again, at their new places: their glyphs, rules, pictures and chips (as the
    /// translation renderer draws formulas it moves).</summary>
    static string FormulaContent(List<Transplant> transplants, HashSet<int> orphans, List<int> droppedRules, Dictionary<int, int> chips,
                                 ContentInterpreter interpreter, PdfCopier copier, string prefix, Dictionary<string, int> xobjects,
                                 Dictionary<string, PdfValue> fonts)
    {
        var content = new StringBuilder();
        var fontNames = new Dictionary<int, string>();
        static string Matrix(Affine m) => string.Join(" ", new[] { m.A, m.B, m.C, m.D, m.Tx, m.Ty }.Select(PdfValue.Format));
        foreach (var transplant in transplants)
        {
            var formula = transplant.Formula;
            var area = formula.Rect.InsetBy(-0.5, -formula.Size * 0.15);
            var glyphs = new List<int>(formula.Glyphs);
            glyphs.AddRange(orphans.Where(g => area.Contains(new Pt(interpreter.Glyphs[g].Box.MidX, interpreter.Glyphs[g].Box.MidY))));
            var rules = droppedRules.Where(r => TranslationRenderer.IsRule(interpreter.Marks[r].Rect, [area]))
                .Concat(chips.Where(c => c.Value == (formula.Glyphs.Count > 0 ? formula.Glyphs[0] : -1)).Select(c => c.Key)).ToList();
            var t = transplant.Transform;
            content.Append($"q {PdfValue.Format(t.A)} 0 0 {PdfValue.Format(t.D)} {PdfValue.Format(t.Tx)} {PdfValue.Format(t.Ty)} cm\n");
            foreach (var m in formula.Icons)
            {
                if (interpreter.Images.TryGetValue(m, out var image) && copier.Copy(image.Stream) is PdfValue.RefV reference)
                {
                    var name = prefix + "I" + xobjects.Count;
                    xobjects[name] = reference.Number;
                    content.Append($"q {Matrix(image.Matrix)} cm /{name} Do Q\n");
                }
                else if (interpreter.Paths.TryGetValue(m, out var ctm) && interpreter.Streams.TryGetValue(interpreter.Marks[m].Location.Stream, out var stream))
                {
                    var mark = interpreter.Marks[m];
                    var ops = string.Join("\n", Enumerable.Range(mark.OpStart, mark.OpEnd - mark.OpStart + 1)
                        .Select(o => Encoding.Latin1.GetString(stream.Source, stream.Ops[o].Start, stream.Ops[o].End - stream.Ops[o].Start)));
                    content.Append($"q {Matrix(ctm)} cm {PdfValue.Format(mark.Color.R)} {PdfValue.Format(mark.Color.G)} {PdfValue.Format(mark.Color.B)} rg\n{ops}\nQ\n");
                }
            }
            content.Append(TranslationRenderer.Drawing(glyphs.Distinct().OrderBy(g => g).ToList(), rules, interpreter, font =>
            {
                if (fontNames.TryGetValue(font, out var name)) return name;
                name = prefix + "G" + fontNames.Count;
                fontNames[font] = name;
                fonts[name] = copier.Copy(interpreter.Fonts[font].Dict);
                return name;
            }));
            content.Append("Q\n");
        }
        return content.ToString();
    }

    /// <summary>Characters no font of the page has, drawn in a system font of the same kind into a form XObject of writer
    /// (its fonts subset to the glyphs used).</summary>
    int? FallbackForm(List<PdfParagraph.FallbackRun> runs, PdfWriter writer)
    {
        if (runs.Count == 0) return null;
        var media = _layout.MediaBox;
        double top = Math.Max(media.MaxY, 1), right = Math.Max(media.MaxX, 1);
        var used = new HashSet<ushort>();
        var stream = new MemoryStream();
        using (var document = SKDocument.CreatePdf(stream))
        {
            var canvas = document.BeginPage((float)right, (float)top);
            foreach (var run in runs)
            {
                using var font = new SKFont(run.Face.Typeface, (float)run.Size) { Subpixel = true, LinearMetrics = true, Embolden = run.Face.Embolden };
                using var paint = new SKPaint
                {
                    Color = new SKColor((byte)Math.Round(run.Color.R * 255), (byte)Math.Round(run.Color.G * 255), (byte)Math.Round(run.Color.B * 255)),
                    IsAntialias = true,
                };
                foreach (var g in font.GetGlyphs(run.Text)) used.Add(g);
                canvas.DrawText(run.Text, (float)run.Origin.X, (float)(top - run.Origin.Y), font, paint);
            }
            document.EndPage();
            document.Close();
        }
        using var overlay = PdfSource.Open(stream.ToArray());
        if (overlay.Pages.Count == 0) return null;
        var copier = new PdfCopier(writer, overlay)
        {
            Transform = s => s.Dict.RawObject("Length1") == null ? ToUnicodeFix.Apply(s.Data) : FontSubsetter.Subset(s.Data, used),
        };
        var page = overlay.Pages[0];
        var resources = page.Resources is { } r ? copier.Entries(r) : [];
        return writer.AddStream(new Dictionary<string, PdfValue>
        {
            ["Type"] = PdfValue.Name("XObject"), ["Subtype"] = PdfValue.Name("Form"), ["BBox"] = PdfValue.RectValue(PdfComposer.Geometry(page).MediaBox),
            ["Resources"] = PdfValue.Dict(resources),
        }, [.. "q\n"u8, .. page.Contents(), .. "\nQ\n"u8]);
    }
}
