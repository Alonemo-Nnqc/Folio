using Folio.Core.Translate;
using Folio.Core.Translate.Pdf;

namespace Folio.Core.Tests;

/// <summary>Text coloured in the page's own colour spaces reads as the colour it shows (the same as the Mac): journals
/// often set black text as full ink of a Separation "Black", which reading <c>1 scn</c> as gray turned white, and its
/// translation invisible.</summary>
public class ColorSpaceTests
{
    static byte[] Pdf(string content)
    {
        const string calc = "{ dup 0 mul exch dup 0 mul exch dup 0 mul exch 1 mul }";
        var objects = new List<string>
        {
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> "
                + "/ColorSpace << /Sep [/Separation /Black /DeviceGray << /FunctionType 2 /Domain [0 1] /C0 [1] /C1 [0] /N 1 >>] "
                + "/Calc [/Separation /Black /DeviceCMYK 6 0 R] /Idx [/Indexed /DeviceRGB 2 <FFFFFF000000FF0000>] "
                + "/None [/Separation /Spot /DeviceGray 99 0 R] /ICC [/ICCBased 7 0 R] >> >> >>",
            $"<< /Length {content.Length} >>\nstream\n{content}\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Times-Roman /Encoding /WinAnsiEncoding /FirstChar 32 /LastChar 126 /Widths ["
                + string.Join(" ", Enumerable.Repeat("500", 95)) + "] >>",
            $"<< /FunctionType 4 /Domain [0 1] /Range [0 1 0 1 0 1 0 1] /Length {calc.Length} >>\nstream\n{calc}\nendstream",
            "<< /N 1 /Length 0 >>\nstream\n\nendstream",
        };
        var sb = new System.Text.StringBuilder("%PDF-1.4\n");
        var offsets = new List<int>();
        for (int i = 0; i < objects.Count; i++)
        {
            offsets.Add(sb.Length);
            sb.Append($"{i + 1} 0 obj\n{objects[i]}\nendobj\n");
        }
        int xref = sb.Length;
        sb.Append($"xref\n0 {objects.Count + 1}\n0000000000 65535 f \n");
        foreach (var offset in offsets) sb.Append($"{offset:D10} 00000 n \n");
        sb.Append($"trailer\n<< /Size {objects.Count + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n");
        return System.Text.Encoding.Latin1.GetBytes(sb.ToString());
    }

    static ContentInterpreter Interpret(string content)
    {
        var source = PdfSource.Open(Pdf(content));
        var interpreter = new ContentInterpreter();
        interpreter.Run(source.Pages[0]);
        return interpreter;
    }

    static List<RGBColor> Colors(string content) => Interpret(content).Glyphs.Select(g => g.Color).ToList();

    [Fact]
    public void FullInkOfASeparationIsBlackNotWhite()
    {
        var c = Colors("BT /F1 10 Tf 50 100 Td /Sep cs 1 scn (A) Tj 0 scn (B) Tj /Sep cs (C) Tj ET");
        Assert.Equal(RGBColor.Black, c[0]);
        Assert.Equal(new RGBColor(1, 1, 1), c[1]);
        // Choosing the space starts at full ink.
        Assert.Equal(RGBColor.Black, c[2]);
    }

    [Fact]
    public void PostScriptTintFunctionsAreFollowed()
    {
        var c = Colors("BT /F1 10 Tf 50 100 Td /Calc cs 1 sc (A) Tj 0.5 sc (B) Tj ET");
        Assert.Equal(RGBColor.Black, c[0]);
        Assert.InRange(c[1].R, 0.499, 0.501);
        Assert.InRange(c[1].G, 0.499, 0.501);
    }

    [Fact]
    public void IndexedAndIccColoursReadTheirTables()
    {
        var c = Colors("BT /F1 10 Tf 50 100 Td /Idx cs 1 scn (A) Tj 2 scn (B) Tj /ICC cs 0 scn (C) Tj 0 0 1 rg (D) Tj ET");
        Assert.Equal(RGBColor.Black, c[0]);
        Assert.Equal(new RGBColor(1, 0, 0), c[1]);
        Assert.Equal(RGBColor.Black, c[2]);
        Assert.Equal(new RGBColor(0, 0, 1), c[3]);
    }

    [Fact]
    public void ASpotColourWithoutItsFunctionIsStillInk()
    {
        Assert.Equal(RGBColor.Black, Colors("BT /F1 10 Tf 50 100 Td /None cs 1 scn (A) Tj ET")[0]);
    }

    [Fact]
    public void PaleTextOnBarePaperIsRedrawnInBlack()
    {
        var interpreter = Interpret("BT /F1 10 Tf 50 100 Td 1 g (A) Tj ET 0 0 1 rg 40 180 100 30 re f BT /F1 10 Tf 50 190 Td 1 g (B) Tj ET");
        // White on the paper: shown in black. White on the blue box: as it is.
        Assert.Equal(RGBColor.Black, interpreter.VisibleColor(interpreter.Glyphs[0]));
        Assert.Equal(new RGBColor(1, 1, 1), interpreter.VisibleColor(interpreter.Glyphs[1]));
    }
}
