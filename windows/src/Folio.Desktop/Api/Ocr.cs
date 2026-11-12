using Folio.Core;

namespace Folio.App;

/// <summary>扫描件识别 (OCR-01): the reader's banner, 识别文字（OCR）, and progress for the list and readers.</summary>
public static partial class Api
{
    static object OcrState() => M.Ocr.Jobs.ToDictionary(kv => kv.Key, kv => new { done = kv.Value.Done, total = kv.Value.Total });

    static void InstallOcr()
    {
        Bridge.On("ocr.state", _ => OcrState());
        Bridge.OnAsync("ocr.isScanned", async a => (object?)await M.Ocr.IsScanned(a.Str("file")));
        Bridge.On("ocr.recognize", a =>
        {
            foreach (var id in a.Strs("files")) M.Ocr.Recognize(id);
            return null;
        });
        Bridge.On("ocr.cancel", a => { M.Ocr.Cancel(a.Str("file")); return null; });
        M.Ocr.Changed += () => App.Main?.Bridge.Emit("ocr", OcrState());
        M.Ocr.FileRecognized += id => App.Main?.Bridge.Emit("ocr.recognized", id);
    }
}
