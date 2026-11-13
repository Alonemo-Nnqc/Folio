using Folio.Core;
using Windows.Data.Pdf;
using Windows.Globalization;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage;
using Windows.Storage.Streams;
using OcrLine = Folio.Core.OcrLine;
using OcrWord = Folio.Core.OcrWord;

namespace Folio.App;

/// <summary>扫描件识别 (OCR-01) on Windows: the pages without text are rendered by Windows (Windows.Data.Pdf) and read by its
/// OCR (Windows.Media.Ocr, Chinese when its language pack is there, else the user's languages); the words become an
/// invisible text layer (Folio.Core OcrTextLayer) written into a copy, which replaces the file once it is checked. One file
/// at a time, as on the Mac (OCRCoordinator.swift).</summary>
public sealed class OcrCoordinator(AppModel model)
{
    public sealed record Progress(int Done, int Total);

    readonly Dictionary<string, Progress> _jobs = [];
    readonly Queue<string> _queue = new();
    readonly Dictionary<string, CancellationTokenSource> _cancel = [];
    readonly Dictionary<string, bool> _scanned = [];
    readonly Dictionary<string, List<TaskCompletionSource>> _waiters = [];
    readonly Dictionary<string, List<Action<Progress>>> _listeners = [];
    Task? _worker;

    /// <summary>Raised on the UI thread when a job starts, moves on or ends.</summary>
    public event Action? Changed;
    /// <summary>A file's text was recognised and the file replaced: readers load it again.</summary>
    public event Action<string>? FileRecognized;

    public IReadOnlyDictionary<string, Progress> Jobs => _jobs;

    /// <summary>Whether the file is a scan without text (remembered per version of the file).</summary>
    public async Task<bool> IsScanned(string fileId)
    {
        if (!model.Snapshot.Files.TryGetValue(fileId, out var file) || !file.IsPdf) return false;
        var key = $"{fileId}|{file.Sha256}";
        if (_scanned.TryGetValue(key, out var known)) return known;
        var path = model.Library.FilePath(file);
        var result = await Task.Run(() => ScannedPdf.IsScanned(path));
        _scanned[key] = result;
        return result;
    }

    /// <summary>After import: a scan is recognised by itself.</summary>
    public async void RecognizeIfScanned(string itemId)
    {
        var file = model.Snapshot.FilesOf(itemId).FirstOrDefault(f => f.IsPdf);
        if (file != null && await IsScanned(file.Id)) Recognize(file.Id);
    }

    public void Recognize(string fileId)
    {
        if (_jobs.ContainsKey(fileId)) return;
        _jobs[fileId] = new Progress(0, 0);
        _queue.Enqueue(fileId);
        Changed?.Invoke();
        _worker ??= Run();
    }

    /// <summary>Recognises the file (or waits for it) and returns once it has been replaced.</summary>
    public Task RecognizeAndWait(string fileId, Action<Progress>? progress = null)
    {
        var done = new TaskCompletionSource();
        (_waiters.TryGetValue(fileId, out var w) ? w : _waiters[fileId] = []).Add(done);
        if (progress != null) (_listeners.TryGetValue(fileId, out var l) ? l : _listeners[fileId] = []).Add(progress);
        Recognize(fileId);
        return done.Task;
    }

    public void Cancel(string fileId)
    {
        if (_cancel.TryGetValue(fileId, out var cts)) cts.Cancel();
        else if (_jobs.Remove(fileId)) { Finish(fileId, new OperationCanceledException()); Changed?.Invoke(); }
    }

    void Finish(string fileId, Exception? error)
    {
        _listeners.Remove(fileId);
        if (!_waiters.Remove(fileId, out var waiters)) return;
        foreach (var w in waiters) { if (error != null) w.TrySetException(error); else w.TrySetResult(); }
    }

    async Task Run()
    {
        while (_queue.Count > 0)
        {
            var fileId = _queue.Dequeue();
            if (!_jobs.ContainsKey(fileId)) continue;
            await RunOne(fileId);
        }
        _worker = null;
    }

    async Task RunOne(string fileId)
    {
        if (!model.Snapshot.Files.TryGetValue(fileId, out var file)) { _jobs.Remove(fileId); Finish(fileId, new FileNotFoundException()); return; }
        var path = model.Library.FilePath(file);
        var temp = Path.Combine(Path.GetDirectoryName(path)!, $".{Guid.NewGuid():N}.folio-ocr.pdf");
        using var cts = new CancellationTokenSource();
        _cancel[fileId] = cts;
        bool quiet = _waiters.ContainsKey(fileId);
        try
        {
            void Report(int done, int total) => App.Ui.TryEnqueue(() =>
            {
                if (!_jobs.ContainsKey(fileId)) return;
                var p = new Progress(done, total);
                _jobs[fileId] = p;
                foreach (var listener in _listeners.GetValueOrDefault(fileId) ?? []) listener(p);
                Changed?.Invoke();
            });
            await Task.Run(() => RecognizeFile(path, temp, Report, cts.Token), cts.Token);
            Replace(path, temp, Path.Combine(model.Library.Root, ".ocr-backup"), fileId);
            _scanned.Keys.Where(k => k.StartsWith(fileId + "|")).ToList().ForEach(k => _scanned.Remove(k));
            _jobs.Remove(fileId);
            Changed?.Invoke();
            FileRecognized?.Invoke(fileId);
            // Fingerprint and full-text index follow the new file; a paper still without metadata is looked up again.
            model.Importer.RefreshChangedFiles();
            if (model.Snapshot.Items.TryGetValue(file.ItemId, out var item) && item.Kind == ItemKind.Standalone)
                model.Importer.Retrieve(item.Id, model.Snapshot);
            Finish(fileId, null);
            if (!quiet) model.Toasts.Show(Loc.S("已识别「%@」的文字", file.FileName), "checkmark");
        }
        catch (OperationCanceledException e)
        {
            TryDelete(temp);
            _jobs.Remove(fileId);
            Changed?.Invoke();
            Finish(fileId, e);
        }
        catch (Exception e)
        {
            TryDelete(temp);
            _jobs.Remove(fileId);
            Changed?.Invoke();
            Finish(fileId, e);
            if (!quiet) model.Toasts.Show(Loc.S("无法识别「%@」的文字：%@", file.FileName, e.Message), "warning");
        }
        finally { _cancel.Remove(fileId); }
    }

    static void TryDelete(string path) { try { File.Delete(path); } catch { } }

    /// <summary>The engine: Chinese (which reads English too) when its language pack is installed, else the user's languages.</summary>
    static OcrEngine Engine()
    {
        foreach (var tag in new[] { "zh-Hans-CN", "zh-Hans", "zh-CN" })
        {
            var language = new Language(tag);
            if (OcrEngine.IsLanguageSupported(language) && OcrEngine.TryCreateFromLanguage(language) is { } engine) return engine;
        }
        return OcrEngine.TryCreateFromUserProfileLanguages()
            ?? throw new InvalidOperationException(Loc.S("Windows 没有可用的文字识别语言包。请在 设置 ▸ 时间和语言 ▸ 语言 中为中文或英文安装“光学字符识别”。"));
    }

    /// <summary>Writes temp: the PDF at path with text on the pages that had none.</summary>
    static void RecognizeFile(string path, string temp, Action<int, int> progress, CancellationToken cancel)
    {
        var pages = ScannedPdf.PagesNeedingOcr(path);
        if (pages.Count == 0) throw new InvalidOperationException(Loc.S("这个 PDF 的页面已经有文字。"));
        var engine = Engine();
        var storage = StorageFile.GetFileFromPathAsync(path).AsTask(cancel).GetAwaiter().GetResult();
        var pdf = PdfDocument.LoadFromFileAsync(storage).AsTask(cancel).GetAwaiter().GetResult();
        var layers = new Dictionary<int, OcrPageResult>();
        progress(0, pages.Count);
        for (int i = 0; i < pages.Count; i++)
        {
            cancel.ThrowIfCancellationRequested();
            layers[pages[i]] = RecognizePage(engine, pdf, pages[i], cancel);
            progress(i + 1, pages.Count);
        }
        if (layers.Values.Sum(l => l.Characters) == 0) throw new InvalidOperationException(Loc.S("没有在页面上识别到文字。"));
        File.Copy(path, temp, true);
        OcrTextLayer.Write(temp, layers);
        // Still the same document: as many pages, and every one opens.
        using (var check = UglyToad.PdfPig.PdfDocument.Open(temp))
        using (var original = UglyToad.PdfPig.PdfDocument.Open(path))
        {
            if (check.NumberOfPages != original.NumberOfPages) throw new InvalidOperationException(Loc.S("识别结果无法写入这个 PDF。"));
            foreach (var n in layers.Keys) _ = check.GetPage(n).Text;
        }
    }

    /// <summary>One page as shown (crop box, rotation), its long side about 2400 pixels (OCR's own limit is 10 000), read.</summary>
    static OcrPageResult RecognizePage(OcrEngine engine, PdfDocument pdf, int number, CancellationToken cancel)
    {
        using var page = pdf.GetPage((uint)(number - 1));
        var size = page.Size;
        double longSide = Math.Max(size.Width, size.Height);
        double scale = Math.Clamp(2400 / Math.Max(longSide, 1), 1, Math.Min(4, (OcrEngine.MaxImageDimension - 1) / Math.Max(longSide, 1)));
        uint width = (uint)Math.Round(size.Width * scale), height = (uint)Math.Round(size.Height * scale);
        using var stream = new InMemoryRandomAccessStream();
        page.RenderToStreamAsync(stream, new PdfPageRenderOptions { DestinationWidth = width, DestinationHeight = height, BackgroundColor = Windows.UI.Color.FromArgb(255, 255, 255, 255) })
            .AsTask(cancel).GetAwaiter().GetResult();
        var decoder = BitmapDecoder.CreateAsync(stream).AsTask(cancel).GetAwaiter().GetResult();
        using var bitmap = decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied).AsTask(cancel).GetAwaiter().GetResult();
        var result = engine.RecognizeAsync(bitmap).AsTask(cancel).GetAwaiter().GetResult();
        var lines = new List<OcrLine>();
        foreach (var line in result.Lines)
        {
            var words = new List<OcrWord>();
            foreach (var word in line.Words)
            {
                var r = word.BoundingRect;
                // Chinese comes back a character (or a few) per word: each its own box, as Vision's.
                words.Add(new OcrWord(word.Text, r.X, r.Y, r.Width, r.Height));
            }
            if (words.Count > 0) lines.Add(new OcrLine(words));
        }
        return new OcrPageResult(number, bitmap.PixelWidth, bitmap.PixelHeight, lines);
    }

    /// <summary>The original goes to the backup folder first, the new file takes its place, and the backup is removed once that worked.</summary>
    static void Replace(string path, string temp, string backupFolder, string name)
    {
        Directory.CreateDirectory(backupFolder);
        var backup = Path.Combine(backupFolder, name + ".pdf");
        File.Copy(path, backup, true);
        try { File.Move(temp, path, true); }
        catch
        {
            if (!File.Exists(path)) File.Copy(backup, path);
            throw;
        }
        TryDelete(backup);
        try { if (!Directory.EnumerateFileSystemEntries(backupFolder).Any()) Directory.Delete(backupFolder); } catch { }
    }
}
