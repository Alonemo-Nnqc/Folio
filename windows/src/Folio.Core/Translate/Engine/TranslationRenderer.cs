using System.Globalization;
using System.Text;
using Folio.Core.Translate.Layout;
using Folio.Core.Translate.Pdf;
using Folio.Core.Translate.Typeset;
using SkiaSharp;

namespace Folio.Core.Translate.Engine;

// Port of macos/.../FolioTranslate/Engine/TranslationRenderer.swift. The translations are drawn by Skia into a
// separate PDF (fonts embedded as subsets, text copyable), whose pages are placed over the edited originals.

/// <summary>What to take out of a page: the glyphs of the translated blocks, and glyphs no character stands for
/// (spaces, invisible text) inside their lines.</summary>
public sealed class PageRemoval
{
    public HashSet<int> Glyphs = [];
    public List<Rect> Rects = [];
    /// <summary>Glyphs of text staying in the original: never removed.</summary>
    public HashSet<int> Kept = [];

    public void Add(LayoutBlock block)
    {
        foreach (var line in block.Lines)
        {
            Rects.Add(line.Rect.InsetBy(-0.5, -line.Size * 0.1));
            foreach (var c in line.Chars) Glyphs.UnionWith(c.Glyphs);
        }
    }

    public bool Removes(Glyph glyph, int index)
    {
        if (Kept.Contains(index)) return false;
        if (Glyphs.Contains(index)) return true;
        var box = glyph.Box;
        var center = new Pt(box.MidX, glyph.IsHorizontal ? glyph.Origin.Y + glyph.Size * 0.3 : box.MidY);
        return Rects.Any(r => r.Contains(center));
    }
}

/// <summary>Measurements of a render, for checking layout quality.</summary>
public sealed class RenderAudit
{
    public sealed record Entry(int Page, int Block, Rect Frame, List<Rect> Boxes, double Scale, bool Fits, int LineCount, double Pitch, double FontSize,
                               List<(double Baseline, double MinX, double MaxX)> Lines);

    readonly object _lock = new();
    public List<Entry> Entries { get; } = [];
    public int Conflicts, LostGlyphs, FormulaGlyphs;
    public List<string> LeftBehind { get; } = [];
    public Dictionary<int, Dictionary<int, double>> Moved { get; } = [];

    public void Record(int page, int block, Rect frame, Typesetter.Result result, Typesetter.Plan plan)
    {
        var boxes = new List<Rect>();
        foreach (var (line, origin) in result.Lines)
        {
            var ink = line.Ink();
            double width = line.NaturalWidth;
            if (width > 0 && ink.Above + ink.Below > 0) boxes.Add(new Rect(origin.X, origin.Y - ink.Below, width, ink.Above + ink.Below));
        }
        boxes.AddRange(result.Transplants.Select(t => (t.Formula.Ink.IsNull ? t.Formula.Rect : t.Formula.Ink).Applying(t.Transform)));
        var lines = result.Lines.Select(e => (e.Origin.Y, e.Origin.X, e.Origin.X + e.Line.NaturalWidth)).ToList();
        lock (_lock) Entries.Add(new Entry(page, block, frame, boxes, result.Scale, result.Fits, result.Lines.Count, result.Pitch, plan.FontSize, lines));
    }
}

public sealed class TranslationRenderer(PdfSource source, string language)
{
    public PdfSource Source { get; } = source;
    public string Language { get; } = language;
    public RenderAudit? Audit { get; set; }
    /// <summary>Images and fonts of the source, compressed once for all the documents rendered from it.</summary>
    readonly StreamDataCache _streamCache = new();

    public sealed class Output
    {
        public byte[]? Mono, Dual, Base, Overlay;
    }

    /// <summary>Text keeps the original's line spacing, closer only when it needs to fit (the PDF editor, as on the Mac):
    /// a translation fills its paragraph's height instead.</summary>
    public bool KeepLineSpacing { get; set; }

    /// <summary>Also produce <see cref="Output.Base"/> and <see cref="Output.Overlay"/>.</summary>
    public bool AuditLayers { get; set; }

    /// <summary>Words in pictures and their translations, by page: set over the pictures (TRANS-40).</summary>
    public Dictionary<int, List<(ImageText.Line Line, string Translation)>> ImageTexts { get; set; } = [];

    enum Layers { All, Base, Overlay }

    /// <summary>Renders the pages of <paramref name="layouts"/>. <paramref name="translations"/> maps segment ids to
    /// translated text; segments without one keep their original text (partial previews).</summary>
    public Output Render(List<PageLayout> layouts, List<TextSegment> segments, IReadOnlyDictionary<string, string> translations,
                         bool wantMono, bool wantDual, TranslationOptions.DualLayouts dualLayout, string? title)
    {
        var bySegment = segments.GroupBy(s => s.Page).ToDictionary(g => g.Key, g => g.ToList());
        var transplants = new Dictionary<int, List<Transplant>>();
        var removals = new Dictionary<int, PageRemoval>();
        var linkPlaces = new Dictionary<int, Dictionary<int, List<Rect>>>();
        List<Rect> Places(int page, int link)
        {
            if (!linkPlaces.TryGetValue(page, out var byLink)) linkPlaces[page] = byLink = [];
            if (!byLink.TryGetValue(link, out var list)) byLink[link] = list = [];
            return list;
        }
        List<Transplant> TransplantsOf(int page) => transplants.TryGetValue(page, out var l) ? l : transplants[page] = [];

        // Glyphs drawn, for the subsets of the fonts embedded (by glyph id, kept in place).
        var usedGlyphs = new HashSet<ushort>();
        var subsets = new Dictionary<long, byte[]?>();
        byte[]? Subset(PStream stream)
        {
            if (stream.Dict.RawObject("Length1") == null) return ToUnicodeFix.Apply(stream.Data);
            lock (subsets)
            {
                if (!subsets.TryGetValue(stream.Key, out var data)) subsets[stream.Key] = data = FontSubsetter.Subset(stream.Data, usedGlyphs);
                return data;
            }
        }
        // 1. Translations, one overlay page per output page.
        var overlayStream = new MemoryStream();
        using (var document = SKDocument.CreatePdf(overlayStream, new SKDocumentPdfMetadata { Producer = "Folio", Creator = "Folio", EncodingQuality = 101 }))
        {
            var typesetter = new Typesetter(Language);
            foreach (var layout in layouts)
            {
                // The overlay page reaches from (0, 0) to the original's top right corner: drawing at PDF coordinates.
                double pageTop = Math.Max(layout.MediaBox.MaxY, 1), pageRight = Math.Max(layout.MediaBox.MaxX, 1);
                var canvas = document.BeginPage((float)pageRight, (float)pageTop);
                var onPage = bySegment.GetValueOrDefault(layout.Number) ?? [];
                var leads = new Dictionary<int, TextSegment>();
                foreach (var s in onPage.Where(s => s.IsLead)) leads.TryAdd(s.Block, s);
                var pageSegments = onPage.Where(s => !s.IsLead && translations.TryGetValue(s.Id, out var t) && t.Length > 0).ToList();
                var translatedBlocks = pageSegments.Select(s => s.Block).ToHashSet();
                // Operators that also draw text staying in the original must stay.
                var kept = new HashSet<int>();
                for (int index = 0; index < layout.Blocks.Count; index++)
                {
                    if (translatedBlocks.Contains(index)) continue;
                    foreach (var line in layout.Blocks[index].Lines) foreach (var c in line.Chars) kept.UnionWith(c.Glyphs);
                }
                var planned = new List<(TextSegment Segment, Rect Frame, Typesetter.Plan Plan, string Text)>();
                foreach (var original in pageSegments)
                {
                    var segment = original;
                    var text = translations[segment.Id];
                    // A heading run into the paragraph goes before it, its formulas first.
                    if (leads.TryGetValue(segment.Block, out var lead))
                    {
                        int shift = lead.Formulas.Count;
                        var body = Placeholders.Replace(text, n => TextSegment.Placeholder(n + shift));
                        text = Typesetter.LeadStart + (translations.GetValueOrDefault(lead.Id) ?? lead.Source) + Typesetter.LeadEnd + " " + body;
                        segment = new TextSegment
                        {
                            Page = segment.Page, Block = segment.Block, Kind = segment.Kind, Source = segment.Source, IsLead = segment.IsLead,
                            Formulas = [.. lead.Formulas, .. segment.Formulas],
                        };
                    }
                    var frame = Frame(segment.Block, layout);
                    planned.Add((segment, frame, typesetter.MakePlan(text, layout.Blocks[segment.Block], segment.Formulas, frame), text));
                }
                // The cells of a table share one size: the size most of them fit at.
                foreach (var table in layout.Tables)
                {
                    var cells = Enumerable.Range(0, planned.Count).Where(k =>
                    {
                        var block = layout.Blocks[planned[k].Segment.Block];
                        return block.Kind == BlockKind.TableCell && table.InsetBy(-1, -2).Contains(block.Rect.Center);
                    }).ToList();
                    if (cells.Count < 3) continue;
                    var scales = cells.Select(k => planned[k].Plan.Scale).OrderBy(s => s).ToList();
                    double common = scales[scales.Count / 2];
                    foreach (var k in cells.Where(k => planned[k].Plan.Scale > common + 0.001))
                    {
                        var entry = planned[k];
                        planned[k] = (entry.Segment, entry.Frame,
                            typesetter.MakePlan(entry.Text, layout.Blocks[entry.Segment.Block], entry.Segment.Formulas, entry.Frame, common), entry.Text);
                    }
                }
                // Running text is set in stretches of even lines; the rest fills its own space.
                var flowing = planned.Select(p => new PageFlow.Entry { Block = p.Segment.Block, Frame = p.Frame, Text = p.Text, Formulas = p.Segment.Formulas, Plan = p.Plan }).ToList();
                var outcome = PageFlow.LayOut(flowing, layout, typesetter);
                for (int k = 0; k < planned.Count; k++) planned[k] = (planned[k].Segment, flowing[k].Frame, flowing[k].Plan, planned[k].Text);
                var pitches = HarmonizedPitches(planned.Select(p => (p.Plan, layout.Blocks[p.Segment.Block])).ToList());
                // Displayed formulas going along with the text around them are drawn again, like the formulas in lines.
                var moves = outcome.Moves.Where(m => Math.Abs(m.Dy) >= 0.3).ToList();
                foreach (var move in moves)
                    foreach (var index in move.Blocks)
                        foreach (var line in layout.Blocks[index].Lines) foreach (var c in line.Chars) kept.ExceptWith(c.Glyphs);
                var removal = new PageRemoval { Kept = kept };
                foreach (var move in moves)
                {
                    foreach (var index in move.Blocks) removal.Add(layout.Blocks[index]);
                    removal.Rects.Add(move.Span.Rect.InsetBy(-0.5, -move.Span.Size * 0.15));
                    var span = move.Span;
                    span.Links = [];
                    foreach (var index in move.Blocks)
                    {
                        foreach (var line in layout.Blocks[index].Lines)
                            foreach (var c in line.Chars)
                                if (c.Link is { } link && layout.Links.FirstOrDefault(l => l.Index == link) is { } pageLink)
                                {
                                    var list = Places(layout.Number, link);
                                    list.Clear();
                                    list.AddRange(pageLink.Rects.Select(r => r.Offset(0, move.Dy)));
                                }
                        if (Audit != null)
                        {
                            if (!Audit.Moved.TryGetValue(layout.Number, out var moved)) Audit.Moved[layout.Number] = moved = [];
                            moved[index] = move.Dy;
                        }
                    }
                    TransplantsOf(layout.Number).Add(new Transplant(span, new Pt(span.Rect.MinX, span.Baseline + move.Dy), 1));
                }
                for (int k = 0; k < planned.Count; k++)
                {
                    var entry = planned[k];
                    var block = layout.Blocks[entry.Segment.Block];
                    var placement = outcome.Placements.TryGetValue(k, out var p) ? p : (PageFlow.Placement?)null;
                    var pitch = KeepLineSpacing ? Math.Min(entry.Plan.FillPitch, block.Pitch * entry.Plan.Scale) : placement?.Pitch ?? pitches[k];
                    var result = typesetter.Finish(entry.Plan, pitch, entry.Segment.Formulas, KeepLineSpacing ? null : placement?.FirstBaseline);
                    typesetter.Draw(result, canvas, pageTop, usedGlyphs);
                    TransplantsOf(layout.Number).AddRange(result.Transplants);
                    removal.Add(block);
                    foreach (var line in block.Lines)
                        foreach (var c in line.Chars)
                            if (c.Link is { } link && !(linkPlaces.GetValueOrDefault(layout.Number)?.ContainsKey(link) ?? false)) Places(layout.Number, link);
                    foreach (var transplant in result.Transplants)
                        foreach (var span in transplant.Formula.Links)
                            Places(layout.Number, span.Link).Add(span.Rect.Applying(transplant.Transform).InsetBy(-0.5, 0));
                    // Links over running words go with the same stretch of the translation.
                    var held = entry.Segment.Formulas.SelectMany(f => f.AllLinks).Select(l => l.Link).ToHashSet();
                    foreach (var link in block.Lines.SelectMany(l => l.Chars).Where(c => c.Link != null).Select(c => c.Link!.Value).ToHashSet())
                    {
                        if (held.Contains(link)) continue;
                        var list = Places(layout.Number, link);
                        list.Clear();
                        list.AddRange(LinkPlaces.Of(link, block, result.Lines, entry.Plan.FontSize));
                    }
                    Audit?.Record(layout.Number, entry.Segment.Block, placement?.Frame ?? entry.Frame, result, entry.Plan);
                }
                // Figure labels drawn as text: their glyphs leave the page for their translations.
                var figureTexts = ImageTexts.GetValueOrDefault(layout.Number) ?? [];
                foreach (var (line, _) in figureTexts)
                {
                    removal.Kept.ExceptWith(line.Glyphs);
                    removal.Glyphs.UnionWith(line.Glyphs);
                }
                removals[layout.Number] = removal;
                if (figureTexts.Count > 0) ImageText.Draw(figureTexts, Language, canvas, pageTop, usedGlyphs);
                document.EndPage();
            }
            document.Close();
        }
        using var overlay = PdfSource.Open(overlayStream.ToArray());

        byte[] Compose(bool dual, Layers layers = Layers.All)
        {
            var composer = new PdfComposer(Source, _streamCache);
            foreach (var layout in layouts) composer.ReserveOutputPage(layout.Number);
            for (int index = 0; index < layouts.Count; index++)
            {
                var layout = layouts[index];
                if (composer.GeometryOfSourcePage(layout.Number) is not { } geometry || layout.Number > Source.Pages.Count) continue;
                var interpreter = new ContentInterpreter();
                interpreter.Run(Source.Pages[layout.Number - 1]);
                var xobjects = new Dictionary<string, int>();
                var fonts = new Dictionary<string, PdfValue>();
                var content = new StringBuilder();
                var removal = removals.GetValueOrDefault(layout.Number) ?? new PageRemoval();
                var rects = removal.Rects;
                var pendingRuleCheck = new List<Rect>();
                var removed = Enumerable.Range(0, interpreter.Glyphs.Count).Where(i => removal.Removes(interpreter.Glyphs[i], i)).ToHashSet();
                var edits = GlyphEdits(interpreter, removed);
                if (Audit != null && layers == Layers.All && !dual)
                {
                    var entries = Audit.Entries.Where(e => e.Page == layout.Number).ToList();
                    var sources = entries.Select(e => e.Block).Distinct().Select(b => layout.Blocks[b]).Where(b => b.Kind == BlockKind.Paragraph);
                    var frames = entries.SelectMany(e => e.Boxes).Concat(sources.SelectMany(block =>
                        block.Lines.Zip(block.Lines.Skip(1)).Select(pair => pair.First.Rect.Union(pair.Second.Rect).InsetBy(1, 1)))).ToList();
                    for (int i = 0; i < interpreter.Glyphs.Count; i++)
                    {
                        var glyph = interpreter.Glyphs[i];
                        if (!glyph.IsVisible || removed.Contains(i)) continue;
                        var text = glyph.Text?.Trim() ?? "";
                        if (text.Length == 0 || !frames.Any(f => f.InsetBy(0.5, 0.5).Contains(new Pt(glyph.Box.MidX, glyph.Box.MidY)))) continue;
                        Audit.LeftBehind.Add(string.Format(CultureInfo.InvariantCulture, "p{0} \"{1}\" @{2:0},{3:0}", layout.Number, text, glyph.Box.MidX, glyph.Box.MidY));
                    }
                    pendingRuleCheck = frames;
                }
                if (Audit != null) Audit.Conflicts += edits.Values.Count(v => v is EditAction.Replace);
                // Rules that are part of formulas (fraction bars, radicals) move with the formula.
                var droppedRules = new List<int>();
                var pageFormulas = transplants.GetValueOrDefault(layout.Number) ?? [];
                var formulaAreas = pageFormulas.Select(t => t.Formula.Rect.InsetBy(-0.5, -t.Formula.Size * 0.15)).ToList();
                void Drop(GraphicMark mark)
                {
                    for (int op = mark.OpStart; op <= mark.OpEnd; op++) edits[new OpLocation(mark.Location.Stream, op)] = EditAction.DropAction;
                }
                for (int m = 0; m < interpreter.Marks.Count; m++)
                {
                    var mark = interpreter.Marks[m];
                    if (mark.Kind == GraphicMark.MarkKind.Image || mark.IsWhite) continue;
                    if (!(mark.Rect.H < 4 && rects.Any(r => r.InsetBy(-0.5, -0.5).Contains(mark.Rect)) || IsRule(mark.Rect, formulaAreas))) continue;
                    Drop(mark);
                    droppedRules.Add(m);
                }
                // A rule (fraction bar, radical) left in the middle of the text set again.
                if (pendingRuleCheck.Count > 0)
                {
                    for (int m = 0; m < interpreter.Marks.Count; m++)
                    {
                        var mark = interpreter.Marks[m];
                        if (mark.Kind == GraphicMark.MarkKind.Image || mark.IsWhite || mark.Rect.H >= 2 || mark.Rect.W >= 60 || mark.Rect.W <= 1 || droppedRules.Contains(m)) continue;
                        if (!pendingRuleCheck.Any(f => f.InsetBy(0.5, 0.5).Contains(new Pt(mark.Rect.MidX, mark.Rect.MidY)))) continue;
                        Audit?.LeftBehind.Add(string.Format(CultureInfo.InvariantCulture, "p{0} rule {1:0} wide @{2:0},{3:0}", layout.Number, mark.Rect.W, mark.Rect.MidX, mark.Rect.MidY));
                    }
                }
                // Pictures set among the words go with them.
                foreach (var transplant in pageFormulas)
                    foreach (var m in transplant.Formula.Icons.Where(m => m < interpreter.Marks.Count)) Drop(interpreter.Marks[m]);
                // A coloured chip tight around a formula moves with it.
                var chips = new Dictionary<int, int>();
                foreach (var transplant in pageFormulas)
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
                if (layers != Layers.Overlay && composer.PageForm(layout.Number, interpreter, edits) is { } edited)
                {
                    xobjects["E"] = edited;
                    content.Append("q /E Do Q\n");
                }
                bool debugEdited = layers == Layers.Base || Environment.GetEnvironmentVariable("FOLIO_DEBUG_EDITED_ONLY") != null;
                if (!debugEdited && composer.ForeignPageForm(overlay, index + 1, Subset) is { } textForm)
                {
                    xobjects["T"] = textForm;
                    content.Append("q /T Do Q\n");
                }
                // Glyphs taken out that no character stands for, inside a formula's box, go with that formula.
                var pageTransplants = debugEdited ? [] : pageFormulas;
                var claimed = removal.Glyphs.Union(pageTransplants.SelectMany(t => t.Formula.Glyphs)).ToHashSet();
                var orphans = removed.Where(g => !claimed.Contains(g) && interpreter.Glyphs[g].IsVisible).ToHashSet();
                var fontNames = new Dictionary<int, string>();
                var drawnOrphans = new HashSet<int>();
                foreach (var transplant in pageTransplants)
                {
                    var formula = transplant.Formula;
                    var area = formula.Rect.InsetBy(-0.5, -formula.Size * 0.15);
                    var glyphs = new List<int>(formula.Glyphs);
                    var extra = orphans.Where(g => area.Contains(new Pt(interpreter.Glyphs[g].Box.MidX, interpreter.Glyphs[g].Box.MidY))).ToList();
                    glyphs.AddRange(extra);
                    drawnOrphans.UnionWith(extra);
                    if (Audit != null) Audit.FormulaGlyphs += glyphs.Count;
                    var rules = droppedRules.Where(r => IsRule(interpreter.Marks[r].Rect, [area]))
                        .Concat(chips.Where(c => c.Value == (formula.Glyphs.Count > 0 ? formula.Glyphs[0] : -1)).Select(c => c.Key)).ToList();
                    var t = transplant.Transform;
                    content.Append($"q {PdfValue.Format(t.A)} 0 0 {PdfValue.Format(t.D)} {PdfValue.Format(t.Tx)} {PdfValue.Format(t.Ty)} cm\n");
                    static string Matrix(Affine m) => string.Join(" ", new[] { m.A, m.B, m.C, m.D, m.Tx, m.Ty }.Select(PdfValue.Format));
                    foreach (var m in formula.Icons)
                    {
                        if (interpreter.Images.TryGetValue(m, out var image) && composer.Copier.Copy(image.Stream) is PdfValue.RefV reference)
                        {
                            var name = "FolioI" + xobjects.Count;
                            xobjects[name] = reference.Number;
                            content.Append($"q {Matrix(image.Matrix)} cm /{name} Do Q\n");
                        }
                        else if (interpreter.Paths.TryGetValue(m, out var ctm) && interpreter.Streams.TryGetValue(interpreter.Marks[m].Location.Stream, out var stream))
                        {
                            // A shape: its own path, in its own colour.
                            var mark = interpreter.Marks[m];
                            var ops = string.Join("\n", Enumerable.Range(mark.OpStart, mark.OpEnd - mark.OpStart + 1)
                                .Select(o => Encoding.Latin1.GetString(stream.Source, stream.Ops[o].Start, stream.Ops[o].End - stream.Ops[o].Start)));
                            content.Append($"q {Matrix(ctm)} cm {PdfValue.Format(mark.Color.R)} {PdfValue.Format(mark.Color.G)} {PdfValue.Format(mark.Color.B)} rg\n{ops}\nQ\n");
                        }
                    }
                    content.Append(Drawing(glyphs.OrderBy(g => g).ToList(), rules, interpreter, font =>
                    {
                        if (fontNames.TryGetValue(font, out var name)) return name;
                        name = "FolioG" + fontNames.Count;
                        fontNames[font] = name;
                        fonts[name] = composer.Copier.Copy(interpreter.Fonts[font].Dict);
                        return name;
                    }));
                    content.Append("Q\n");
                }
                if (!debugEdited && Audit != null)
                    Audit.LostGlyphs += orphans.Except(drawnOrphans).Count(g => interpreter.Glyphs[g].Text is not { } s || s.Trim().Length > 0);
                int outputPage = composer.ReserveOutputPage(layout.Number);
                var places = linkPlaces.GetValueOrDefault(layout.Number) ?? [];
                var bytes = Encoding.Latin1.GetBytes(content.ToString());
                if (!dual)
                {
                    composer.AddPage(geometry.MediaBox, bytes, xobjects, outputPage, geometry.CropBox, geometry.Rotation, fonts,
                        composer.Links(layout.Number, default, places));
                    continue;
                }
                if (composer.PageForm(layout.Number) is not { } original) continue;
                // The translated page as one form, so it can be placed beside or after the original.
                var resources = new Dictionary<string, PdfValue> { ["XObject"] = PdfValue.Dict(xobjects.ToDictionary(kv => kv.Key, kv => PdfValue.Ref(kv.Value))) };
                if (fonts.Count > 0) resources["Font"] = PdfValue.Dict(fonts);
                int translatedForm = composer.Writer.AddStream(new Dictionary<string, PdfValue>
                {
                    ["Type"] = PdfValue.Name("XObject"), ["Subtype"] = PdfValue.Name("Form"), ["BBox"] = PdfValue.RectValue(geometry.MediaBox), ["Resources"] = PdfValue.Dict(resources),
                }, bytes);
                switch (dualLayout)
                {
                    case TranslationOptions.DualLayouts.sideBySide:
                    {
                        double width = geometry.CropBox.W;
                        var media = new Rect(geometry.CropBox.MinX, geometry.CropBox.MinY, width * 2, geometry.CropBox.H);
                        var both = $"q /O Do Q\nq 1 0 0 1 {PdfValue.Format(width)} 0 cm /M Do Q\n";
                        composer.AddPage(media, Encoding.Latin1.GetBytes(both), new() { ["O"] = original, ["M"] = translatedForm }, outputPage, null, geometry.Rotation, null,
                            [.. composer.Links(layout.Number), .. composer.Links(layout.Number, new Pt(width, 0), places)]);
                        break;
                    }
                    case TranslationOptions.DualLayouts.alternatingPages:
                        composer.AddPage(geometry.MediaBox, "q /O Do Q\n"u8.ToArray(), new() { ["O"] = original }, outputPage, geometry.CropBox, geometry.Rotation, null,
                            composer.Links(layout.Number));
                        composer.AddPage(geometry.MediaBox, "q /M Do Q\n"u8.ToArray(), new() { ["M"] = translatedForm }, null, geometry.CropBox, geometry.Rotation, null,
                            composer.Links(layout.Number, default, places));
                        break;
                }
            }
            return composer.Finish(title);
        }
        return new Output
        {
            Mono = wantMono ? Compose(false) : null,
            Dual = wantDual ? Compose(true) : null,
            Base = AuditLayers ? Compose(false, Layers.Base) : null,
            Overlay = AuditLayers ? Compose(false, Layers.Overlay) : null,
        };
    }

    /// <summary>Whether a thin mark belongs to a formula in one of <paramref name="areas"/>: a fraction's bar, a root's
    /// line, the sides of a big bracket. Its middle is inside, and it hardly reaches out.</summary>
    public static bool IsRule(Rect rect, List<Rect> areas)
    {
        if (Math.Min(rect.W, rect.H) >= 2.5) return false;
        return areas.Any(area => area.InsetBy(-2.5, -0.5).Contains(rect) && area.Contains(new Pt(rect.MidX, rect.MidY)));
    }

    /// <summary>Line spacing for each planned block: each paragraph fills the height of its original, but paragraphs of
    /// one page stay within about ±12% of a common spacing.</summary>
    public static List<double> HarmonizedPitches(List<(Typesetter.Plan Plan, LayoutBlock Block)> plans)
    {
        var ratios = plans.Where(p => p.Block.Kind == BlockKind.Paragraph && p.Plan.Lines.Count >= 2 && p.Plan.Fits)
            .Select(p => p.Plan.FillPitch / p.Plan.FontSize).OrderBy(r => r).ToList();
        if (ratios.Count == 0) return plans.Select(p => p.Plan.FillPitch).ToList();
        double common = ratios[ratios.Count / 2];
        return plans.Select(entry =>
        {
            var plan = entry.Plan;
            if (!(entry.Block.Kind is BlockKind.Paragraph or BlockKind.Caption) || plan.Lines.Count < 2) return plan.FillPitch;
            double lower = common * plan.FontSize * 0.88, upper = common * plan.FontSize * 1.12;
            return Math.Min(Math.Max(plan.FillPitch, lower), upper);
        }).ToList();
    }

    /// <summary>The area a translated block may use: its own lines, plus free space below it (and, for one-line blocks,
    /// to its right) up to the next thing on the page.</summary>
    public static Rect Frame(int index, PageLayout layout)
    {
        var block = layout.Blocks[index];
        var rect = block.Rect;
        double size = block.Size;
        double gap = size * 0.25;
        var obstacles = new List<Rect>();
        for (int k = 0; k < layout.Blocks.Count; k++)
        {
            if (k == index) continue;
            var other = layout.Blocks[k];
            var r = other.Rect;
            double top0 = other.Kind == BlockKind.Formula
                ? other.Lines.SelectMany(l => l.Chars).Where(c => !c.IsSpace).Select(c => c.InkBox.MaxY).DefaultIfEmpty(r.MaxY).Max()
                : other.Lines[0].Baseline + other.Lines[0].Size * 0.8;
            if (top0 < r.MaxY && top0 > r.MinY) r = new Rect(r.MinX, r.MinY, r.W, top0 - r.MinY);
            obstacles.Add(r);
        }
        bool inTable = layout.Tables.Any(t => t.InsetBy(-1, -2).Contains(rect.Center));
        foreach (var g in layout.Graphics.Where(g => g.W * g.H > 1 || g.W > 20 || g.H > 20))
        {
            if (g.Contains(rect) && g.W * g.H > rect.W * rect.H * 4) continue;
            obstacles.Add(g);
        }
        if (!inTable) obstacles.AddRange(layout.Tables);
        var page = layout.CropBox.InsetBy(layout.CropBox.W * 0.03, layout.CropBox.H * 0.03);

        var horizontal = rect.InsetBy(1, 0);
        double lastBaseline = block.Lines[^1].Baseline;
        double belowTop = obstacles.Where(o => o.MaxY <= lastBaseline + size * 0.2 && o.MaxX > horizontal.MinX && o.MinX < horizontal.MaxX)
            .Select(o => o.MaxY).DefaultIfEmpty(page.MinY).Max();
        double maxExtension = block.Kind == BlockKind.TableCell ? size * 0.2 : Math.Max(block.Pitch * 2, rect.H * 0.5);
        double bottom = Math.Max(Math.Min(rect.MinY, belowTop + gap), rect.MinY - maxExtension);
        if (belowTop + gap > rect.MinY) bottom = Math.Min(belowTop + gap, lastBaseline - size * 0.25);
        if (block.Lines.Count > 1)
        {
            var rules = layout.Graphics.Where(g => g.H < 2.5 && g.MaxX > horizontal.MinX && g.MinX < horizontal.MaxX && g.MaxY <= lastBaseline - size * 0.1).ToList();
            if (rules.Count > 0) bottom = Math.Max(bottom, rules.Max(r => r.MaxY) + 0.2);
        }
        double top = rect.MaxY;
        double firstBaseline = block.Lines[0].Baseline;
        if (block.Lines.Count == 1)
        {
            for (int k = 0; k < layout.Blocks.Count; k++)
            {
                if (k == index) continue;
                var other = layout.Blocks[k];
                var low = other.Lines.MinBy(l => l.Baseline);
                if (low == null || low.Baseline <= firstBaseline + size * 0.5 || low.Baseline >= firstBaseline + size * 1.8
                    || other.Rect.MaxX <= horizontal.MinX || other.Rect.MinX >= horizontal.MaxX) continue;
                top = Math.Min(top, Math.Max(low.Baseline - low.Size * 0.14 - size * 0.04, firstBaseline + size * 0.6));
            }
            foreach (var g in layout.Graphics.Where(g => g.H < 2.5 && g.MinX < horizontal.MaxX && g.MaxX > horizontal.MinX
                         && g.MinY > firstBaseline + size * 0.4 && g.MinY < firstBaseline + size * 1.8))
                top = Math.Min(top, Math.Max(g.MinY - size * 0.02, firstBaseline + size * 0.6));
        }
        var frame = new Rect(rect.MinX, bottom, rect.W, top - bottom);

        if (block.Lines.Count == 1)
        {
            var band = new Rect(rect.MinX, rect.MinY + 1, rect.W, Math.Max(rect.H - 2, 0.5));
            var rightEdges = obstacles.Where(o => o.MinX >= rect.MaxX - 0.5 && o.MinY < band.MaxY && o.MaxY > band.MinY).Select(o => o.MinX).ToList();
            var leftEdges = obstacles.Where(o => o.MaxX <= rect.MinX + 0.5 && o.MinY < band.MaxY && o.MaxY > band.MinY).Select(o => o.MaxX).ToList();
            double right = rightEdges.Count > 0 ? rightEdges.Min() : inTable ? rect.MaxX + size * 2 : page.MaxX;
            double limit = inTable ? size * 3 : Math.Max(rect.W, size * 30);
            double maxX = Math.Min(right - gap, rect.MaxX + limit);
            if (maxX > frame.MaxX) frame = new Rect(frame.MinX, frame.MinY, maxX - frame.MinX, frame.H);
            if (block.IsCentered && block.Kind != BlockKind.TableCell)
            {
                double left = leftEdges.Count > 0 ? leftEdges.Max() : page.MinX;
                double grow = Math.Max(0, Math.Min(Math.Min(right - gap - rect.MaxX, rect.MinX - left - gap), limit));
                frame = new Rect(rect.MinX - grow, frame.MinY, rect.W + 2 * grow, frame.H);
            }
            if (block.Kind == BlockKind.TableCell)
            {
                double cellRight = rightEdges.Count > 0 ? rightEdges.Min() : rect.MaxX + size * 2;
                double cellLeft = leftEdges.Count > 0 ? leftEdges.Max() : rect.MinX - size * 2;
                switch (block.CellAlignment)
                {
                    case CellAlignment.Left:
                        frame = new Rect(rect.MinX, frame.MinY, rect.W + Math.Max(0, Math.Min(cellRight - rect.MaxX - size * 0.4, size * 4)), frame.H);
                        break;
                    case CellAlignment.Right:
                    {
                        double grow = Math.Max(0, Math.Min(rect.MinX - cellLeft - size * 0.4, size * 4));
                        frame = new Rect(rect.MinX - grow, frame.MinY, rect.W + grow, frame.H);
                        break;
                    }
                    default:
                    {
                        double grow = Math.Max(0, Math.Min(Math.Min((cellRight - rect.MaxX) / 2, (rect.MinX - cellLeft) / 2), size * 3) - 0.5);
                        frame = new Rect(rect.MinX - grow, frame.MinY, rect.W + 2 * grow, frame.H);
                        break;
                    }
                }
            }
        }
        return frame;
    }

    // MARK: Edits

    /// <summary>Takes the <paramref name="removing"/> glyphs out of the page. A show operator losing all its glyphs is
    /// dropped, unless text after it in the same chain stays; then it is written again with the removed glyphs replaced
    /// by their advance, so every kept glyph stays exactly where it was.</summary>
    public static Dictionary<OpLocation, EditAction> GlyphEdits(ContentInterpreter interpreter, HashSet<int> removing)
    {
        var runs = interpreter.Runs;
        var glyphs = interpreter.Glyphs;
        var affected = new List<(int Run, bool All)>();
        var lastKept = new Dictionary<int, int>();
        for (int r = 0; r < runs.Count; r++)
        {
            var run = runs[r];
            int gone = 0;
            for (int g = run.GlyphStart; g < run.GlyphEnd; g++) if (removing.Contains(g)) gone++;
            int count = run.GlyphEnd - run.GlyphStart;
            if (run.RenderMode >= 4 || gone == 0)
            {
                lastKept[run.Chain] = Math.Max(lastKept.GetValueOrDefault(run.Chain, -1), run.Location.Index);
                continue;
            }
            if (gone < count) lastKept[run.Chain] = Math.Max(lastKept.GetValueOrDefault(run.Chain, -1), run.Location.Index);
            affected.Add((r, gone == count));
        }
        var edits = new Dictionary<OpLocation, EditAction>();
        foreach (var (r, all) in affected)
        {
            var run = runs[r];
            if (all && lastKept.GetValueOrDefault(run.Chain, -1) <= run.Location.Index)
                edits[run.Location] = EditAction.DropAction;
            else if (interpreter.Streams.TryGetValue(run.Location.Stream, out var stream) && run.Location.Index < stream.Ops.Count
                     && RewrittenShow(stream.Ops[run.Location.Index], glyphs, run.GlyphStart, run.GlyphEnd, removing) is { } data)
                edits[run.Location] = new EditAction.Replace(data);
            else
                edits[run.Location] = new EditAction.Hide(run.RenderMode);
        }
        return edits;
    }

    /// <summary>The show operator as a TJ without the removed glyphs: each is replaced by an adjustment of its own
    /// advance. ' and " keep their move to the next line (and " its spacing).</summary>
    public static byte[]? RewrittenShow(ContentOp op, List<Glyph> all, int first, int end, HashSet<int> removing)
    {
        List<ContentOperand> elements;
        switch (op.Name)
        {
            case "TJ":
                if (op.Operands.FirstOrDefault() is not ContentOperand.Array items) return null;
                elements = items.Items;
                break;
            case "Tj":
                if (op.Operands.Count == 0) return null;
                elements = [op.Operands[0]];
                break;
            case "'" or "\"":
                if (op.Operands.Count == 0) return null;
                elements = [op.Operands[^1]];
                break;
            default:
                return null;
        }
        var output = new StringBuilder();
        if (op.Name == "'") output.Append("T*\n");
        if (op.Name == "\"" && op.Operands.Count == 3)
            output.Append($"{PdfValue.Format(op.Operands[0].AsNumber ?? 0)} Tw {PdfValue.Format(op.Operands[1].AsNumber ?? 0)} Tc T*\n");
        var parts = new List<string>();
        double pending = 0;
        var hex = new StringBuilder();
        void FlushString()
        {
            if (hex.Length > 0) { parts.Add("<" + hex + ">"); hex.Clear(); }
        }
        void FlushNumber()
        {
            if (pending != 0) { parts.Add(PdfValue.Format(pending)); pending = 0; }
        }
        var byElement = new Dictionary<int, List<(int Index, Glyph Glyph)>>();
        for (int i = first; i < end; i++)
        {
            var g = all[i];
            if (!byElement.TryGetValue(g.Element, out var list)) byElement[g.Element] = list = [];
            list.Add((i, g));
        }
        for (int e = 0; e < elements.Count; e++)
        {
            switch (elements[e])
            {
                case ContentOperand.Number n:
                    FlushString();
                    pending += n.Value;
                    break;
                case ContentOperand.Str s:
                    var bytes = s.Value;
                    foreach (var (index, g) in byElement.GetValueOrDefault(e) ?? [])
                    {
                        if (removing.Contains(index))
                        {
                            if (g.Adjustment is not { } adjustment) return null;
                            FlushString();
                            pending += adjustment;
                        }
                        else
                        {
                            FlushNumber();
                            if (g.Offset + g.Length > bytes.Length) return null;
                            for (int b = g.Offset; b < g.Offset + g.Length; b++) hex.Append(bytes[b].ToString("X2"));
                        }
                    }
                    break;
            }
        }
        FlushString();
        FlushNumber();
        output.Append('[').Append(string.Join(" ", parts)).Append("] TJ");
        return Encoding.Latin1.GetBytes(output.ToString());
    }

    /// <summary>Content drawing <paramref name="glyphs"/> exactly as they were drawn, and <paramref name="rules"/> as
    /// filled rectangles. <paramref name="fontName"/> names the resource for a font index.</summary>
    public static string Drawing(List<int> glyphs, List<int> rules, ContentInterpreter interpreter, Func<int, string> fontName)
    {
        var output = new StringBuilder();
        string Box(int r)
        {
            var mark = interpreter.Marks[r];
            var rect = mark.Rect;
            if (mark.Kind == GraphicMark.MarkKind.Stroke)
            {
                double w = Math.Max(mark.LineWidth, 0.3);
                rect = rect.InsetBy(rect.H < rect.W ? 0 : -w / 2, rect.H < rect.W ? -w / 2 : 0);
            }
            return $"{PdfValue.Format(mark.Color.R)} {PdfValue.Format(mark.Color.G)} {PdfValue.Format(mark.Color.B)} rg "
                   + $"{PdfValue.Format(rect.MinX)} {PdfValue.Format(rect.MinY)} {PdfValue.Format(rect.W)} {PdfValue.Format(rect.H)} re f\n";
        }
        foreach (var r in rules.Where(r => interpreter.Marks[r].Rect.H >= 4)) output.Append(Box(r));
        int font = -1;
        RGBColor? color = null;
        int mode = -1;
        var drawable = glyphs.Select(g => interpreter.Glyphs[g]).Where(g => g.IsVisible && g.Font >= 0).ToList();
        if (drawable.Count > 0)
        {
            output.Append("BT 0 Tc 0 Tw 100 Tz 0 Ts\n");
            foreach (var g in drawable)
            {
                if (g.Font != font)
                {
                    font = g.Font;
                    output.Append('/').Append(fontName(font)).Append(" 1 Tf\n");
                }
                if (g.Color != color)
                {
                    color = g.Color;
                    var c = $"{PdfValue.Format(g.Color.R)} {PdfValue.Format(g.Color.G)} {PdfValue.Format(g.Color.B)}";
                    output.Append($"{c} rg {c} RG\n");
                }
                int render = Math.Min(g.RenderMode, 2);
                if (render != mode)
                {
                    mode = render;
                    output.Append(render).Append(" Tr\n");
                }
                var m = g.Matrix;
                var code = new StringBuilder();
                for (int k = g.Length - 1; k >= 0; k--) code.Append(((g.Code >> (8 * k)) & 0xFF).ToString("X2"));
                output.Append(string.Join(" ", new[] { m.A, m.B, m.C, m.D, m.Tx, m.Ty }.Select(PdfValue.Format))).Append($" Tm <{code}> Tj\n");
            }
            output.Append("ET\n");
        }
        foreach (var r in rules.Where(r => interpreter.Marks[r].Rect.H < 4)) output.Append(Box(r));
        return output.ToString();
    }
}

/// <summary>Where a link over running words goes when they are translated: the same stretch of the translation.</summary>
public static class LinkPlaces
{
    public static List<Rect> Of(int link, LayoutBlock block, List<(TextLine Line, Pt Origin)> lines, double fontSize)
    {
        int before = 0, inside = 0, after = 0;
        foreach (var line in block.Lines)
            foreach (var c in line.Chars.Where(c => !c.IsSpace))
            {
                if (c.Link == link) { inside++; after = 0; }
                else if (inside == 0) before++;
                else after++;
            }
        int total = before + inside + after;
        if (inside == 0 || total == 0) return [];
        var widths = lines.Select(l => l.Line.NaturalWidth).ToList();
        double length = widths.Sum();
        double start = length * before / total, end = length * (before + inside) / total;
        var result = new List<Rect>();
        double position = 0;
        for (int k = 0; k < lines.Count; k++)
        {
            double from = Math.Max(start, position), to = Math.Min(end, position + widths[k]);
            if (to > from) result.Add(new Rect(lines[k].Origin.X + from - position, lines[k].Origin.Y - fontSize * 0.25, to - from, fontSize * 1.15));
            position += widths[k];
        }
        return result;
    }
}
