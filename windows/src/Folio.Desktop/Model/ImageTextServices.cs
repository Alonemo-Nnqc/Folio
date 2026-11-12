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
    public static ImageText.Services Create() => new(Render, Read);

    /// <summary>The page rendered as shown (its crop box) at about scale pixels per point, cut to region.</summary>
    static async Task<ImageText.Bitmap?> Render(string path, int number, Rect crop, Rect region, double scale)
    {
        var storage = await StorageFile.GetFileFromPathAsync(path);
        var pdf = await PdfDocument.LoadFromFileAsync(storage);
        if (number < 1 || number > pdf.PageCount) return null;
        using var page = pdf.GetPage((uint)(number - 1));
        // OCR reads at most 10 000 pixels a side.
        scale = Math.Min(scale, (OcrEngine.MaxImageDimension - 1) / Math.Max(Math.Max(crop.W, crop.H), 1));
        uint width = (uint)Math.Round(crop.W * scale), height = (uint)Math.Round(crop.H * scale);
        using var stream = new InMemoryRandomAccessStream();
        await page.RenderToStreamAsync(stream, new PdfPageRenderOptions
        {
            DestinationWidth = width, DestinationHeight = height, BackgroundColor = Windows.UI.Color.FromArgb(255, 255, 255, 255),
        });
        var decoder = await BitmapDecoder.CreateAsync(stream);
        using var bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Rgba8, BitmapAlphaMode.Premultiplied);
        var all = new byte[bitmap.PixelWidth * bitmap.PixelHeight * 4];
        bitmap.CopyToBuffer(all.AsBuffer());
        double sx = bitmap.PixelWidth / crop.W, sy = bitmap.PixelHeight / crop.H;
        int x0 = Math.Clamp((int)Math.Floor((region.MinX - crop.MinX) * sx), 0, bitmap.PixelWidth - 1);
        int y0 = Math.Clamp((int)Math.Floor((crop.MaxY - region.MaxY) * sy), 0, bitmap.PixelHeight - 1);
        int w = Math.Clamp((int)Math.Ceiling(region.W * sx), 1, bitmap.PixelWidth - x0), h = Math.Clamp((int)Math.Ceiling(region.H * sy), 1, bitmap.PixelHeight - y0);
        var cut = new byte[w * h * 4];
        for (int y = 0; y < h; y++) System.Buffer.BlockCopy(all, ((y0 + y) * bitmap.PixelWidth + x0) * 4, cut, y * w * 4, w * 4);
        return new ImageText.Bitmap(cut, w, h);
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
