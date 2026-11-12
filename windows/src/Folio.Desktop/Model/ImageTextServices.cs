using System.Runtime.InteropServices.WindowsRuntime;
using Folio.Core;
using Folio.Core.Translate;
using Folio.Core.Translate.Engine;
using Windows.Data.Pdf;
using Windows.Globalization;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage;
using Windows.Storage.Streams;
using OcrLine = Folio.Core.OcrLine;
using OcrWord = Folio.Core.OcrWord;

namespace Folio.App;

/// <summary>翻译图片中的文字 (TRANS-40) on Windows: pictures rendered by Windows.Data.Pdf and read by Windows.Media.Ocr, for
/// Folio.Core's ImageText (the macOS engine uses Core Graphics and Vision).</summary>
static class ImageTextServices
{
    public static ImageText.Services Create() => new(Render, Read) { WordStarts = WordStarts, ReadsLanguage = language => MissingOcr(language) == null };

    /// <summary>Region of the page as shown (its crop box), rendered alone at about scale pixels per point: small labels
    /// sharp enough to read (the whole page at that scale would be far too large).</summary>
    static async Task<ImageText.Bitmap?> Render(string path, int number, Rect crop, Rect region, double scale)
    {
        var storage = await StorageFile.GetFileFromPathAsync(path);
        var pdf = await PdfDocument.LoadFromFileAsync(storage);
        if (number < 1 || number > pdf.PageCount) return null;
        using var page = pdf.GetPage((uint)(number - 1));
        // At most 8000 pixels a side and 40 million in all.
        scale = Math.Min(scale, Math.Min(8000 / Math.Max(Math.Max(region.W, region.H), 1), Math.Sqrt(40_000_000 / Math.Max(region.W * region.H, 1))));
        // The page's own units (device-independent pixels) from the top left of what it shows.
        double dip = page.Size.Width / Math.Max(crop.W, 1);
        uint width = (uint)Math.Max(1, Math.Round(region.W * scale)), height = (uint)Math.Max(1, Math.Round(region.H * scale));
        using var stream = new InMemoryRandomAccessStream();
        await page.RenderToStreamAsync(stream, new PdfPageRenderOptions
        {
            SourceRect = new Windows.Foundation.Rect((region.MinX - crop.MinX) * dip, (crop.MaxY - region.MaxY) * dip, region.W * dip, region.H * dip),
            DestinationWidth = width, DestinationHeight = height, BackgroundColor = Windows.UI.Color.FromArgb(255, 255, 255, 255),
        });
        var decoder = await BitmapDecoder.CreateAsync(stream);
        using var bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Rgba8, BitmapAlphaMode.Premultiplied);
        var bytes = new byte[bitmap.PixelWidth * bitmap.PixelHeight * 4];
        bitmap.CopyToBuffer(bytes.AsBuffer());
        return new ImageText.Bitmap(bytes, bitmap.PixelWidth, bitmap.PixelHeight);
    }

    /// <summary>Where the words of text start, as Windows breaks the language's words (Chinese and Japanese run together).</summary>
    static HashSet<int> WordStarts(string text, string language)
    {
        try
        {
            var tag = language.ToLowerInvariant() switch { "zh" or "zh-cn" or "zh-hans" => "zh-Hans", "zh-tw" or "zh-hant" => "zh-Hant", var other => other };
            var segmenter = new Windows.Data.Text.WordsSegmenter(tag);
            return segmenter.GetTokens(text).Select(t => (int)t.SourceTextSegment.StartPosition).ToHashSet();
        }
        catch { return []; }
    }

    /// <summary>The Windows feature that reads a paper's language, when it is not installed (null when it is, or for a
    /// language Windows has none for): reading English with the Chinese one, say, misreads small or italic labels.</summary>
    public static string? MissingOcr(string language)
    {
        var tag = language.ToLowerInvariant() switch
        {
            "en" => "en-US", "zh" or "zh-cn" or "zh-hans" => "zh-CN", "zh-tw" or "zh-hant" => "zh-TW", "ja" => "ja-JP", "ko" => "ko-KR",
            "fr" => "fr-FR", "de" => "de-DE", "es" => "es-ES", "it" => "it-IT", "pt" => "pt-BR", "ru" => "ru-RU", _ => null,
        };
        if (tag == null) return null;
        var prefix = language.ToLowerInvariant().StartsWith("zh") ? (tag == "zh-TW" ? "zh-Hant" : "zh-Hans") : tag[..2];
        try
        {
            if (OcrEngine.AvailableRecognizerLanguages.Any(l => l.LanguageTag.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))) return null;
        }
        catch { return null; }
        return $"Language.OCR~~~{tag}~0.0.1.0";
    }

    /// <summary>Installs that feature (Windows asks for an administrator's approval). True when it is there afterwards.</summary>
    public static async Task<bool> InstallOcr(string capability)
    {
        var info = new System.Diagnostics.ProcessStartInfo("powershell.exe")
        {
            UseShellExecute = true, Verb = "runas", WindowStyle = System.Diagnostics.ProcessWindowStyle.Hidden,
            Arguments = $"-NoProfile -WindowStyle Hidden -Command \"Add-WindowsCapability -Online -Name '{capability}'\"",
        };
        using var process = System.Diagnostics.Process.Start(info);
        if (process == null) return false;
        await process.WaitForExitAsync();
        return process.ExitCode == 0;
    }

    static async Task<List<OcrLine>> Read(ImageText.Bitmap image, string language)
    {
        var engine = Engine(language);
        using var bitmap = SoftwareBitmap.CreateCopyFromBuffer(image.Rgba.AsBuffer(), BitmapPixelFormat.Rgba8, image.Width, image.Height, BitmapAlphaMode.Premultiplied);
        using var bgra = SoftwareBitmap.Convert(bitmap, BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
        var result = await engine.RecognizeAsync(bgra);
        var lines = new List<OcrLine>();
        foreach (var line in result.Lines)
        {
            var words = line.Words.Select(w => new OcrWord(w.Text, w.BoundingRect.X, w.BoundingRect.Y, w.BoundingRect.Width, w.BoundingRect.Height)).ToList();
            if (words.Count > 0) lines.Add(new OcrLine(words));
        }
        return lines;
    }

    /// <summary>The engine for the paper's language when Windows has it, else Chinese (which reads English too), else the
    /// user's languages.</summary>
    static OcrEngine Engine(string language)
    {
        var tags = language.ToLowerInvariant() switch
        {
            "en" => new[] { "en-US", "en-GB", "en" },
            "zh" or "zh-cn" or "zh-hans" => ["zh-Hans-CN", "zh-Hans", "zh-CN"],
            "zh-tw" or "zh-hant" => ["zh-Hant-TW", "zh-Hant"],
            "ja" => ["ja-JP", "ja"],
            "ko" => ["ko-KR", "ko"],
            _ => [language],
        };
        foreach (var tag in tags.Concat(["zh-Hans-CN", "zh-Hans", "en-US"]))
        {
            try
            {
                var lang = new Language(tag);
                if (OcrEngine.IsLanguageSupported(lang) && OcrEngine.TryCreateFromLanguage(lang) is { } engine) return engine;
            }
            catch (ArgumentException) { }
        }
        return OcrEngine.TryCreateFromUserProfileLanguages()
            ?? throw new InvalidOperationException(Loc.S("Windows 没有可用的文字识别语言包。请在 设置 ▸ 时间和语言 ▸ 语言 中为中文或英文安装“光学字符识别”。"));
    }
}
