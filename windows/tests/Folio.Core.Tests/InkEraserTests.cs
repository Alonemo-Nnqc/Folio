using UglyToad.PdfPig.Tokens;

namespace Folio.Core.Tests;

/// <summary>The eraser's geometry (READER-30); the same cases as the macOS FolioCore tests.</summary>
public class InkEraserTests
{
    static bool Close(List<double[]>? actual, double[][] expected, double tolerance = 1e-6) =>
        actual != null && actual.Count == expected.Length
        && actual.Zip(expected).All(p => p.First.Length == p.Second.Length && p.First.Zip(p.Second).All(v => Math.Abs(v.First - v.Second) <= tolerance));

    [Fact]
    public void CutsAStrokeWhereTheEraserCrossesIt() =>
        Assert.True(Close(InkEraser.Erase([[0, 0, 100, 0]], [50, -20, 50, 20], 5), [[0, 0, 45, 0], [55, 0, 100, 0]]));

    [Fact]
    public void UntouchedStrokesGiveNull()
    {
        Assert.Null(InkEraser.Erase([[0, 0, 100, 0]], [50, 10, 60, 10], 5));
        Assert.Null(InkEraser.Erase([[0, 0, 100, 0]], Array.Empty<double>(), 5));
        Assert.Null(InkEraser.Erase([[0, 0, 100, 0]], [50, 0], 0));
    }

    [Fact]
    public void ErasingAlongTheWholeStrokeLeavesNothing() =>
        Assert.Empty(InkEraser.Erase([[0, 0, 40, 5, 100, 0]], [-5, 0, 105, 0], 8)!);

    [Fact]
    public void KeepsTheVerticesOfWhatRemains() =>
        Assert.True(Close(InkEraser.Erase([[0, 0, 20, 20, 40, 0, 60, 20]], [30, -10, 30, 30], 2), [[0, 0, 20, 20, 28, 12], [32, 8, 40, 0, 60, 20]]));

    [Fact]
    public void ShortStubsAreDropped()
    {
        Assert.True(Close(InkEraser.Erase([[0, 0, 100, 0]], [5.5, 0], 5), [[10.5, 0, 100, 0]]));
        Assert.True(Close(InkEraser.Erase([[0, 0, 100, 0]], [5.5, 0], 5, minimumLength: 0), [[0, 0, 0.5, 0], [10.5, 0, 100, 0]]));
    }

    [Fact]
    public void AClickErasesADisc() =>
        Assert.True(Close(InkEraser.Erase([[0, 0, 100, 0]], [50, 3], 5), [[0, 0, 46, 0], [54, 0, 100, 0]]));

    [Fact]
    public void DotsGoWhenCovered()
    {
        Assert.Empty(InkEraser.Erase([[10, 10]], [12, 10], 3)!);
        Assert.Null(InkEraser.Erase([[10, 10]], [20, 10], 3));
    }

    [Fact]
    public void DiagonalCrossingIsExact() =>
        Assert.True(Close(InkEraser.Erase([[-10, -10, 10, 10]], [-50, 0, 50, 0], 5), [[-10, -10, -5, -5], [5, 5, 10, 10]]));

    [Fact]
    public void RoundEndsOfTheTrackErase() =>
        Assert.True(Close(InkEraser.Erase([[103, -20, 103, 20]], [0, 0, 100, 0], 5), [[103, -20, 103, -4], [103, 4, 103, 20]]));

    [Fact]
    public void OnlyTouchedStrokesChangeAndOrderStays()
    {
        double[] a = [0, 0, 100, 0], b = [0, 50, 100, 50], c = [0, 100, 100, 100];
        Assert.True(Close(InkEraser.Erase([a, b, c], [50, 40, 50, 60], 2), [a, [0, 50, 48, 50], [52, 50, 100, 50], c]));
    }

    [Fact]
    public void ErasingPieceByPieceMatchesErasingAtOnce()
    {
        List<double[]> strokes = [[0, 0, 30, 25, 60, 0, 90, 25, 120, 0], [0, 40, 120, 40]];
        double[] track = [10, -10, 35, 30, 70, 45, 100, 10, 115, -5];
        var atOnce = InkEraser.Erase(strokes, track, 4);
        var pieces = Enumerable.Range(0, track.Length / 2 - 1).Select(i => track[(i * 2)..(i * 2 + 4)]);
        var stepwise = InkEraser.Erase(strokes, pieces, 4);
        Assert.True(Close(atOnce, stepwise!.ToArray()));
    }

    [Fact]
    public void RepeatedPointsInAStrokeAreHandled()
    {
        var result = InkEraser.Erase([[0, 0, 0, 0, 50, 0, 50, 0, 100, 0]], [50, -9, 50, 9], 5)!;
        Assert.Equal(2, result.Count);
        Assert.Equal(45, result[0][^2], 6);
        Assert.Equal(55, result[1][0], 6);
    }

    [Fact]
    public void SizesAreEightSixteenThirtyTwo() =>
        Assert.Equal([8.0, 16, 32], new[] { "small", "medium", "large" }.Select(k => InkEraser.Diameters[k]));

    /// <summary>One erase is one incremental update: strokes cut, an annotation with nothing left removed, undone by cutting the end off.</summary>
    [Fact]
    public void ErasesInkInTheFile()
    {
        var copy = Path.Combine(Path.GetTempPath(), $"folio-erase-{Guid.NewGuid():N}.pdf");
        File.WriteAllBytes(copy, TestPdfs.OnePage());
        try
        {
            AnnotationWriter.Add(copy, [
                new NewAnnotation(1, "Ink", "blue", Strokes: [[20, 100, 280, 100]]),
                new NewAnnotation(1, "Ink", "red", Strokes: [[20, 200, 60, 200]]),
                new NewAnnotation(1, "Highlight", "yellow", Quads: [[10, 150, 200, 150, 10, 130, 200, 130]]),
            ]);
            var numbers = AnnotationNumbers(copy);
            Assert.Equal(3, numbers.Count);
            long beforeErase = new FileInfo(copy).Length;
            var (changed, removed) = AnnotationWriter.EraseInk(copy, [
                // Across the first line (width 2, so the eraser reaches 8 + 1 either side of x = 150).
                new InkErasure(1, numbers[0], [[150, 80, 150, 120]], 8),
                // Along all of the second.
                new InkErasure(1, numbers[1], [[10, 200, 70, 200]], 8),
                // Ink only: the highlight under the eraser stays.
                new InkErasure(1, numbers[2], [[100, 140]], 8),
            ]);
            Assert.Equal([numbers[0]], changed);
            Assert.Equal([numbers[1]], removed);
            var left = AnnotationNumbers(copy);
            Assert.Equal([numbers[0], numbers[2]], left);
            var ink = InkList(copy, numbers[0]);
            Assert.Equal(2, ink.Count);
            Assert.Equal([20.0, 100, 141, 100], ink[0]);
            Assert.Equal([159.0, 100, 280, 100], ink[1]);
            Assert.Equal(2, PdfAnnotations.Read(copy).Count);
            // The colour stays; one undo step takes it all back.
            Assert.Equal(AnnotationColors.Hex("blue").ToUpperInvariant(), PdfAnnotations.Read(copy).First(a => a.Kind == "ink").ColorHex);
            AnnotationWriter.TruncateTo(copy, beforeErase);
            Assert.Equal(numbers, AnnotationNumbers(copy));
            Assert.Single(InkList(copy, numbers[0]));
        }
        finally { File.Delete(copy); }
    }

    /// <summary>Ink from other programs keeps its line width and opacity.</summary>
    [Fact]
    public void KeepsWidthAndOpacityOfOtherInk()
    {
        var copy = Path.Combine(Path.GetTempPath(), $"folio-erase-{Guid.NewGuid():N}.pdf");
        File.WriteAllBytes(copy, TestPdfs.OnePage());
        try
        {
            AnnotationWriter.Add(copy, [new NewAnnotation(1, "Ink", "green", Strokes: [[20, 100, 280, 100]])]);
            long number = AnnotationNumbers(copy)[0];
            // As another program would have it: 6 pt wide, half transparent, a gray colour.
            Rewrite(copy, number, body => body.Replace("/BS << /W 2 >>", "/BS << /W 6 >> /CA 0.5").Replace("/C [0.45 0.85 0.4]", "/C [0.3]"));
            AnnotationWriter.EraseInk(copy, [new InkErasure(1, number, [[150, 80, 150, 120]], 4)]);
            var ink = InkList(copy, number);
            // The eraser reaches its radius plus half the line: 4 + 6 / 2 either side of x = 150.
            Assert.Equal(143.0, ink[0][2], 3);
            Assert.Equal(157.0, ink[1][0], 3);
            var text = System.Text.Encoding.Latin1.GetString(File.ReadAllBytes(copy));
            Assert.Contains("/CA 0.5 /ca 0.5", text);
            Assert.Contains("0.3 G 6 w", text);
        }
        finally { File.Delete(copy); }
    }

    static void Rewrite(string path, long number, Func<string, string> change)
    {
        var text = System.Text.Encoding.Latin1.GetString(File.ReadAllBytes(path));
        int start = text.LastIndexOf($"\n{number} 0 obj\n", StringComparison.Ordinal) + $"\n{number} 0 obj\n".Length;
        int end = text.IndexOf("\nendobj", start, StringComparison.Ordinal);
        var body = text[start..end];
        // Same length, so the cross-reference offsets stay right.
        var changed = change(body);
        Assert.True(changed.Length <= body.Length);
        changed = changed.PadRight(body.Length);
        File.WriteAllBytes(path, System.Text.Encoding.Latin1.GetBytes(text[..start] + changed + text[end..]));
    }

    static List<long> AnnotationNumbers(string path)
    {
        using var document = UglyToad.PdfPig.PdfDocument.Open(path);
        var page = document.GetPage(1);
        if (!page.Dictionary.TryGet(NameToken.Annots, out var raw)) return [];
        var annots = raw is IndirectReferenceToken r ? document.Structure.GetObject(r.Data).Data : raw;
        return ((ArrayToken)annots).Data.OfType<IndirectReferenceToken>().Select(t => t.Data.ObjectNumber).ToList();
    }

    static List<double[]> InkList(string path, long number)
    {
        using var document = UglyToad.PdfPig.PdfDocument.Open(path);
        var dict = (DictionaryToken)document.Structure.GetObject(new UglyToad.PdfPig.Core.IndirectReference(number, 0)).Data;
        var list = (ArrayToken)dict.Data["InkList"];
        return list.Data.OfType<ArrayToken>().Select(s => s.Data.OfType<NumericToken>().Select(n => n.Double).ToArray()).ToList();
    }
}
