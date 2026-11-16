namespace Folio.Core.Tests;

/// <summary>Text boxes and pens as the 1.4 reader writes them (the same as the Mac): a text box's colour is its text's,
/// in its default appearance with its size, on no background; a pen keeps its width.</summary>
public class ReaderAnnotationTests
{
    [Fact]
    public void ATextBoxIsItsTextInItsColourAndSize()
    {
        var copy = Path.Combine(Path.GetTempPath(), $"folio-textbox-{Guid.NewGuid():N}.pdf");
        File.WriteAllBytes(copy, TestPdfs.OnePage());
        try
        {
            AnnotationWriter.Add(copy, [new NewAnnotation(1, "FreeText", "red", Rect: [20, 100, 200, 120], Contents: "重点", FontSize: 16)]);
            var text = System.Text.Encoding.Latin1.GetString(File.ReadAllBytes(copy));
            Assert.Contains("/DA (/Helv 16 Tf 1 0.35 0.35 rg)", text);
            // No fill: no /C, no /IC on the box.
            int start = text.IndexOf("/Subtype /FreeText", StringComparison.Ordinal);
            var body = text[start..text.IndexOf(">>\n", start, StringComparison.Ordinal)];
            Assert.DoesNotContain("/IC", body);
            Assert.DoesNotContain("/C [", body);

            // Recoloured: the text's colour changes, its font and size stay.
            long number = InkEraserTests.AnnotationNumbersOf(copy)[0];
            Assert.True(AnnotationWriter.Modify(copy, 1, number, color: "blue"));
            text = System.Text.Encoding.Latin1.GetString(File.ReadAllBytes(copy));
            Assert.Contains("/Helv 16 Tf 0.4 0.7 1 rg", text);
            Assert.DoesNotContain("1 0.35 0.35 rg) /IT", text[text.LastIndexOf("/Subtype /FreeText", StringComparison.Ordinal)..]);

            // Resized to fit its text.
            Assert.True(AnnotationWriter.Modify(copy, 1, number, contents: "重点：两行\n文字", rect: [20, 84, 200, 120]));
            text = System.Text.Encoding.Latin1.GetString(File.ReadAllBytes(copy));
            Assert.Contains("/Rect [20 84 200 120]", text);

            // Written again with a mixed colour and a new size from its bar: one change.
            Assert.True(AnnotationWriter.Modify(copy, 1, number, color: "#336699", contents: "重点", rect: [20, 96, 200, 120], fontSize: 20));
            text = System.Text.Encoding.Latin1.GetString(File.ReadAllBytes(copy));
            Assert.Contains("/Helv 20 Tf 0.2 0.4 0.6 rg", text);
        }
        finally { File.Delete(copy); }
    }

    [Fact]
    public void MixedColoursAreTheirOwn()
    {
        Assert.Equal((0.2, 0.4, 0.6), AnnotationColors.Rgb("#336699"));
        Assert.Equal("#336699", AnnotationColors.Hex("#336699"));
        Assert.Equal(AnnotationColors.Rgb("yellow"), AnnotationColors.Rgb("#XYZ"));
        var copy = Path.Combine(Path.GetTempPath(), $"folio-note-{Guid.NewGuid():N}.pdf");
        File.WriteAllBytes(copy, TestPdfs.OnePage());
        try
        {
            // A note put down and closed without words stays, in its mixed colour.
            AnnotationWriter.Add(copy, [new NewAnnotation(1, "Text", "#336699", Rect: [20, 100, 36, 119.2], Contents: "")]);
            var text = System.Text.Encoding.Latin1.GetString(File.ReadAllBytes(copy));
            Assert.Contains("/Subtype /Text", text);
            Assert.Contains("/C [0.2 0.4 0.6]", text);
        }
        finally { File.Delete(copy); }
    }

    [Fact]
    public void APenKeepsItsWidth()
    {
        var copy = Path.Combine(Path.GetTempPath(), $"folio-pen-{Guid.NewGuid():N}.pdf");
        File.WriteAllBytes(copy, TestPdfs.OnePage());
        try
        {
            AnnotationWriter.Add(copy, [new NewAnnotation(1, "Ink", "black", Strokes: [[20, 100, 280, 100]], Width: 3.5)]);
            var text = System.Text.Encoding.Latin1.GetString(File.ReadAllBytes(copy));
            Assert.Contains("/BS << /W 3.5 >>", text);
            Assert.Contains("0.11 0.11 0.12 RG 3.5 w", text);
        }
        finally { File.Delete(copy); }
    }
}
