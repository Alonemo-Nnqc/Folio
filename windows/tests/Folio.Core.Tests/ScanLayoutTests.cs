using Folio.Core.Translate;
using Folio.Core.Translate.Engine;
using Folio.Core.Translate.Layout;
using Folio.Core.Translate.Pdf;
using SkiaSharp;

namespace Folio.Core.Tests;

/// <summary>Scans are measured in their picture (as the macOS ScanLayoutTests).</summary>
public class ScanLayoutTests
{
    sealed record Text(string Value, double Y, double X = 72, double Size = 11, bool Bold = false);

    /// <summary>A page as a scanner makes it, and the text layer a recognition would write over it: the words' boxes as rough as they come.</summary>
    sealed class Page
    {
        public List<Text> Texts = [];
        public List<Rect> Rules = [], Shapes = [];
        public const double W = 612, H = 792;
        /// <summary>Degrees the paper lies turned on the glass, counter-clockwise.</summary>
        public double Tilt;
        /// <summary>The boxes follow the tilt (an engine that knows of it) or lie level.</summary>
        public bool TellsTilt = true;

        static SKFont Font(Text t) => new(SKTypeface.FromFamilyName("Times New Roman", t.Bold ? SKFontStyle.Bold : SKFontStyle.Normal), (float)t.Size) { Edging = SKFontEdging.Antialias };

        public PageLayout Layout()
        {
            const double scale = 200.0 / 72;
            using var bitmap = new SKBitmap((int)(W * scale), (int)(H * scale), SKColorType.Rgba8888, SKAlphaType.Opaque);
            using (var canvas = new SKCanvas(bitmap))
            {
                canvas.Clear(new SKColor(245, 245, 245));
                canvas.Scale((float)scale);
                canvas.RotateDegrees((float)-Tilt, (float)W / 2, (float)H / 2);
                using var paint = new SKPaint { Color = new SKColor(20, 20, 20), IsAntialias = true };
                foreach (var r in Rules.Concat(Shapes)) canvas.DrawRect((float)r.MinX, (float)(H - r.MaxY), (float)r.W, (float)r.H, paint);
                foreach (var t in Texts)
                {
                    using var font = Font(t);
                    canvas.DrawText(t.Value, (float)t.X, (float)(H - t.Y), font, paint);
                }
            }
            var path = Path.Combine(Path.GetTempPath(), $"scan-{Guid.NewGuid():N}.pdf");
            try
            {
                using (var stream = File.Create(path))
                using (var document = SKDocument.CreatePdf(stream))
                {
                    var canvas = document.BeginPage((float)W, (float)H);
                    using var image = SKImage.FromBitmap(bitmap);
                    canvas.DrawImage(image, new SKRect(0, 0, (float)W, (float)H));
                    document.EndPage();
                    document.Close();
                }
                // The layer, on an image of one pixel per point.
                double angle = -Tilt * Math.PI / 180, cx = W / 2, cy = H / 2;
                var turn = Affine.Translation(-cx, -cy).Concatenating(Affine.Rotation(angle)).Concatenating(Affine.Translation(cx, cy));
                // The same boxes on an image turned back about its corner.
                var back = turn.Concatenating(Affine.Rotation(-angle));
                var lines = Texts.Select(t =>
                {
                    using var font = Font(t);
                    var words = new List<OcrWord>();
                    int at = 0;
                    foreach (var word in t.Value.Split(' '))
                    {
                        double x0 = t.X + font.MeasureText(t.Value[..at]), x1 = t.X + font.MeasureText(t.Value[..(at + word.Length)]);
                        at += word.Length + 1;
                        // Higher than the type, and by a different bit on every line.
                        double extra = t.Size * (0.1 + 0.25 * Math.Abs(Math.Sin(t.Y)));
                        var rect = new Rect(x0, H - t.Y - t.Size * 0.75 - extra / 2, x1 - x0, t.Size + extra);
                        if (Tilt != 0 && !TellsTilt) rect = rect.Applying(turn);
                        var corner = Tilt != 0 && TellsTilt ? new Pt(rect.MinX, rect.MinY).Applying(back) : new Pt(rect.MinX, rect.MinY);
                        words.Add(new OcrWord(word, corner.X, corner.Y, rect.W, rect.H));
                    }
                    return new OcrLine(words) { Angle = TellsTilt ? angle : 0 };
                }).ToList();
                OcrTextLayer.Write(path, new Dictionary<int, OcrPageResult> { [1] = new(1, W, H, lines) });
                using var source = PdfSource.Open(path);
                Assert.Equal([1], LayoutAnalyzer.RecognizedScans(source, 1));
                var interpreter = new ContentInterpreter();
                interpreter.Run(source.Pages[0]);
                var shown = new ScanPage.Shown(new ImageText.Bitmap(bitmap.Bytes, bitmap.Width, bitmap.Height), new Rect(0, 0, W, H), 0);
                var analyzer = new LayoutAnalyzer();
                analyzer.Scans[1] = ScanPage.Read(source.Pages[0], interpreter, shown);
                return analyzer.Analyze(source, [1])[0];
            }
            finally { File.Delete(path); }
        }

        public static readonly string[] Paragraph =
        [
            "Tourism brings income to the town, and with it the need to share the",
            "burden of crowded streets and worn paths among those who visit them.",
            "We describe a model of both, and a plan that keeps them in balance",
            "over the years to come, whatever the weather and the season may be.",
        ];

        public static IEnumerable<Text> Body(double y) => Paragraph.Select((t, k) => new Text(t, y - k * 14));
    }

    static List<int> Paragraphs(PageLayout layout) => layout.Blocks.Where(b => b.Kind == BlockKind.Paragraph && b.Translate).Select(b => b.Lines.Count).ToList();

    [Fact]
    public void SizesAndWeightsAreMeasuredInThePicture()
    {
        var page = new Page { Texts = [new("A Model of Tourism in Small Towns", 690, 140, 20, true), new("1 Introduction", 640, Size: 14, Bold: true), .. Page.Body(610), .. Page.Body(540)] };
        var layout = page.Layout();
        Assert.True(layout.IsScan);
        var title = Assert.Single(layout.Blocks, b => b.Kind == BlockKind.Title);
        Assert.InRange(title.Size, 18.4, 21.6);
        Assert.True(title.Font.IsBold);
        var heading = Assert.Single(layout.Blocks, b => b.Kind == BlockKind.Heading);
        Assert.Equal("1 Introduction", heading.Text);
        Assert.InRange(heading.Size, 12.8, 15.2);
        Assert.Equal([4, 4], Paragraphs(layout));
        Assert.All(layout.Blocks.Where(b => b.Kind == BlockKind.Paragraph), b => { Assert.InRange(b.Size, 10.1, 11.9); Assert.False(b.Font.IsBold); });
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void ATiltedPageIsStraightened(bool tells)
    {
        var page = new Page { Tilt = 1.6, TellsTilt = tells, Texts = [.. Page.Body(640), .. Page.Body(560), .. Page.Body(480)] };
        var layout = page.Layout();
        Assert.InRange(Math.Atan2(layout.Transform.B, layout.Transform.A) * 180 / Math.PI, -1.85, -1.35);
        Assert.Equal([4, 4, 4], Paragraphs(layout));
    }

    [Fact]
    public void DrawingsKeepTheirWords()
    {
        var page = new Page
        {
            Texts = [.. Page.Body(700), new("Visitors", 540, 200, 8), new("Income", 500, 330, 8), new("Figure 1: Visitors and income by year", 420, 210, 10), .. Page.Body(390)],
            Shapes = [new(180, 440, 30, 80), new(250, 440, 30, 110), new(320, 440, 30, 50)],
        };
        var layout = page.Layout();
        foreach (var word in new[] { "Visitors", "Income" }) Assert.Contains(layout.Blocks, b => b.Text == word && b.Kind == BlockKind.Figure && !b.Translate);
        Assert.Contains(layout.Blocks, b => b.Kind == BlockKind.Caption && b.Translate);
        Assert.Equal([4, 4], Paragraphs(layout));
    }

    [Fact]
    public void RowsOfATableStayApartAndItsRulesStay()
    {
        string[] names = ["Number of tourists", "Catering revenue", "Transport costs", "Waste disposal costs"];
        var page = new Page
        {
            Texts = [.. Page.Body(700), new("Symbol", 584, 160, Bold: true), new("Description", 584, 300, Bold: true),
                     .. names.SelectMany((name, k) => new[] { new Text("ABCD"[k].ToString(), 564 - k * 15, 170), new Text(name, 564 - k * 15, 290) })],
            Rules = [new(140, 598, 300, 1.2), new(140, 578, 300, 0.8), new(140, 510, 300, 1.2)],
        };
        var layout = page.Layout();
        foreach (var name in names) Assert.Contains(layout.Blocks, b => b.Text == name && b.Translate && b.Lines.Count == 1);
        var row = layout.Blocks.First(b => b.Text == "Description");
        foreach (var area in TranslationRenderer.ScanAreas(row.Lines[0], layout))
            Assert.All(page.Rules, rule => Assert.False(area.Intersects(rule)));
    }

    [Fact]
    public void FormulasSetApartStay()
    {
        var page = new Page { Texts = [.. Page.Body(700), new("S = a + b × max(c)", 620, 230), new("(3)", 620, 520), .. Page.Body(590)] };
        var layout = page.Layout();
        Assert.Contains(layout.Blocks, b => b.Text.StartsWith("S =") && b.Kind == BlockKind.Formula && !b.Translate);
        Assert.Equal(2, Paragraphs(layout).Count);
    }

    [Fact]
    public void RunningHeadsAreKnownByTheirText()
    {
        Assert.Equal(LayoutAnalyzer.RunningKey("Team # 2505199"), LayoutAnalyzer.RunningKey("Team #2505198"));
        Assert.Equal(LayoutAnalyzer.RunningKey("Page 3 of 25"), LayoutAnalyzer.RunningKey("page 12 of 25"));
        Assert.Equal(2, LayoutAnalyzer.Distance("page#of#", "page#of#ąl"));
        Assert.Equal(0, LayoutAnalyzer.SentenceWords("f（x）=3x+2"));
        Assert.True(LayoutAnalyzer.SentenceWords("where the value of income is known") >= 5);
        Assert.True(LayoutAnalyzer.SentenceWords("本文提出一种方法") >= 3);
    }

    [Fact]
    public void OnlyPagesOfTextAreTakenFromAMixedDocument()
    {
        static OcrPageResult Result(IEnumerable<string> lines) => new(1, 600, 800, lines.Select((t, k) =>
            new OcrLine(t.Split(' ').Select((w, i) => new OcrWord(w, i * 40, k * 20, 38, 12)).ToList())).ToList());
        Assert.True(ScannedPdf.IsPageOfText(Result(Page.Paragraph.Concat(Page.Paragraph))));
        Assert.False(ScannedPdf.IsPageOfText(Result(["Visitors", "Income by year", "2019 2020 2021 2022", "Fig. 3", "North", "South east"])));
    }

    [Fact]
    public void ATurnedLineIsWrittenTurned()
    {
        var line = new OcrLine([new OcrWord("Population", -300, 40, 120, 14)]) { Angle = -Math.PI / 2 };
        Assert.InRange(line.Box.MinX, 39.99, 40.01);
        Assert.InRange(line.Box.W, 13.99, 14.01);
        var content = OcrTextLayer.Content(new OcrPageResult(1, 612, 792, [line]), new OcrTextLayer.PdfRect(0, 0, 612, 792), 0);
        var m = content.Split('\n').First(l => l.Contains(" Tm")).Split(' ').Take(4).Select(v => double.Parse(v, System.Globalization.CultureInfo.InvariantCulture)).ToArray();
        // Upwards on the page.
        Assert.True(Math.Abs(m[0]) < 1e-6 && m[1] > 13 && m[2] < -13 && Math.Abs(m[3]) < 1e-6);
    }

    static OcrLine Line(string text, double y = 0) => new(text.Split(' ').Select((w, i) => new OcrWord(w, i * 60, y, 50, 12)).ToList());

    [Fact]
    public void AReadingThatIsNoTextIsToldFromText()
    {
        Assert.True(OcrQuality.Of(Page.Paragraph.Select(t => Line(t))).IsText);
        Assert.True(OcrQuality.Of(new[] {"视网膜血管的形态变化与糖尿病等疾病密切相关，对辅助诊断具有重要的意义。", "针对现有方法的问题，本文提出一种新的模型，并在公开的数据上进行了实验。"}.Select(t => Line(t))).IsText);
        // A page upside down.
        Assert.False(OcrQuality.Of(new[] {"uonnq!JJS!l)-J0-ono p 北A uo 丿 一00JJ0 SIOPOUI d010", "-ltuoad pou厑 s eq (SSD(I) ，甲 OL •[19 9 Ei7] stlletuop", "-un OJ SVOAMOU 0S0甲 01qmdL10Jd e VWS SS 里 1110卩"}.Select(t => Line(t))).IsText);
    }

    [Fact]
    public void WordsInPiecesComeTogether()
    {
        var line = new OcrLine([new OcrWord("provi", 0, 0, 30, 12), new OcrWord("d", 30.5, 2, 6, 10), new OcrWord("ed", 37, 2, 12, 10), new OcrWord("by", 53, 0, 12, 14)]);
        Assert.Equal("provided by", OcrQuality.Joined(line).Text);
    }

    [Fact]
    public void AskedAgainTheLayerIsReplaced()
    {
        var path = Path.Combine(Path.GetTempPath(), $"again-{Guid.NewGuid():N}.pdf");
        try
        {
            using (var stream = File.Create(path))
            using (var document = SKDocument.CreatePdf(stream))
            using (var bitmap = new SKBitmap(612, 792))
            {
                var canvas = document.BeginPage(612, 792);
                bitmap.Erase(SKColors.LightGray);
                canvas.DrawBitmap(bitmap, 0, 0);
                document.EndPage();
                document.Close();
            }
            OcrPageResult Result(string word, bool replaces) => new(1, 612, 792, Enumerable.Range(0, 4).Select(k => Line($"{word} {word} {word}", 100 + k * 30)).ToList()) { Replaces = replaces };
            OcrTextLayer.Write(path, new Dictionary<int, OcrPageResult> { [1] = Result("misread", false) });
            Assert.True(ScannedPdf.CanBeReadAnew(path, 1));
            Assert.Empty(ScannedPdf.TextOn(path, 1, 612, 792, hidden: false));
            OcrTextLayer.Write(path, new Dictionary<int, OcrPageResult> { [1] = Result("correct", true) });
            using var check = UglyToad.PdfPig.PdfDocument.Open(path);
            Assert.Contains("correct", check.GetPage(1).Text);
            Assert.DoesNotContain("misread", check.GetPage(1).Text);
        }
        finally { File.Delete(path); }
    }
}
