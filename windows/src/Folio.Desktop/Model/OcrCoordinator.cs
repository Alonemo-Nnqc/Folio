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
    /// <summary>Files the user asked to recognise: every page with a picture is read when none looks like a scan, and what went
    /// wrong is said. The others were queued by themselves after import.</summary>
    readonly HashSet<string> _asked = [];
    /// <summary>Files that have text, with a few scanned pages among it: only pages that turn out to be pages of text are taken.</summary>
    readonly HashSet<string> _mixed = [];
    readonly Dictionary<string, bool> _textless = [];
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

    /// <summary>Whether a file that is no scan has pages without text (a letter or an appendix scanned in, or just a whole-page picture).</summary>
    public async Task<bool> HasPagesWithoutText(string fileId)
    {
        if (!model.Snapshot.Files.TryGetValue(fileId, out var file) || !file.IsPdf) return false;
        var key = $"{fileId}|{file.Sha256}";
        if (_textless.TryGetValue(key, out var known)) return known;
        var path = model.Library.FilePath(file);
        var result = await Task.Run(() => ScannedPdf.HasPagesWithoutText(path));
        _textless[key] = result;
        return result;
    }

    /// <summary>Recognises the scanned pages of a file that otherwise has text, before it is translated. Nothing to read on them
    /// (pictures) is no failure; the pages are not looked at again.</summary>
    public async Task RecognizeScannedPages(string fileId, Action<Progress>? progress = null)
    {
        if (!model.Snapshot.Files.TryGetValue(fileId, out var file)) return;
        if (!_jobs.ContainsKey(fileId)) _mixed.Add(fileId);
        try { await RecognizeAndWait(fileId, progress); }
        catch (NothingFound) { _textless[$"{fileId}|{file.Sha256}"] = false; }
        catch { }
    }

    /// <summary>After import: a scan is recognised by itself.</summary>
    public async void RecognizeIfScanned(string itemId)
    {
        var file = model.Snapshot.FilesOf(itemId).FirstOrDefault(f => f.IsPdf);
        if (file != null && await IsScanned(file.Id)) Recognize(file.Id, asked: false);
    }

    public void Recognize(string fileId, bool asked = true)
    {
        if (asked) _asked.Add(fileId);
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
        Recognize(fileId, asked: false);
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
            bool force = _asked.Contains(fileId);
            bool onlyText = !force && _mixed.Contains(fileId);
            bool poorlyRead = false;
            await Task.Run(() => RecognizeFile(path, temp, force, onlyText, Report, out poorlyRead, cts.Token), cts.Token);
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
            if (poorlyRead) model.Toasts.Show(Loc.S("「%@」是西文扫描件，但 Windows 只装了中文的文字识别，准确度较低。可在 Windows 设置 ▸ 时间和语言 ▸ 语言 中为英文安装“光学字符识别”，再从条目菜单选“识别文字（OCR）”重新识别。", file.FileName), "warning");
            else if (!quiet) model.Toasts.Show(Loc.S("已识别「%@」的文字", file.FileName), "checkmark");
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
            // A file recognised by itself that turned out to have no text on it (photos, plates) is nobody's trouble.
            if (!quiet && (_asked.Contains(fileId) || e is not NothingFound)) model.Toasts.Show(Loc.S("无法识别「%@」的文字：%@", file.FileName, e.Message), "warning");
        }
        finally { _cancel.Remove(fileId); _asked.Remove(fileId); _mixed.Remove(fileId); }
    }

    static void TryDelete(string path) { try { File.Delete(path); } catch { } }

    /// <summary>No text on the pages, or nothing to read.</summary>
    sealed class NothingFound(string message) : InvalidOperationException(message);

    /// <summary>The engines to read with, the likeliest first: Chinese (which reads English too), then the user's languages,
    /// then the others Windows has. A page the first reads nothing on is tried with the next.</summary>
    static List<OcrEngine> Engines()
    {
        var engines = new List<OcrEngine>();
        void Add(OcrEngine? engine)
        {
            if (engine != null && !engines.Any(e => e.RecognizerLanguage.LanguageTag == engine.RecognizerLanguage.LanguageTag)) engines.Add(engine);
        }
        foreach (var tag in new[] { "zh-Hans-CN", "zh-Hans", "zh-CN" })
        {
            var language = new Language(tag);
            if (OcrEngine.IsLanguageSupported(language)) Add(OcrEngine.TryCreateFromLanguage(language));
        }
        Add(OcrEngine.TryCreateFromUserProfileLanguages());
        try { foreach (var language in OcrEngine.AvailableRecognizerLanguages) Add(OcrEngine.TryCreateFromLanguage(language)); } catch { }
        if (engines.Count == 0)
            throw new InvalidOperationException(Loc.S("Windows 没有可用的文字识别语言包。请在 设置 ▸ 时间和语言 ▸ 语言 中为中文或英文安装“光学字符识别”。"));
        return engines.Take(4).ToList();
    }

    static bool IsLatin(OcrEngine engine) => !new[] { "zh", "ja", "ko" }.Any(engine.RecognizerLanguage.LanguageTag.StartsWith);

    /// <summary>Writes temp: the PDF at path with text on the pages that had none.</summary>
    static void RecognizeFile(string path, string temp, bool force, bool onlyText, Action<int, int> progress, out bool poorlyRead, CancellationToken cancel)
    {
        poorlyRead = false;
        var pages = ScannedPdf.PagesNeedingOcr(path, force);
        if (pages.Count == 0) throw new NothingFound(Loc.S("这个 PDF 的页面已经有文字。"));
        var engines = Engines();
        var storage = StorageFile.GetFileFromPathAsync(path).AsTask(cancel).GetAwaiter().GetResult();
        var pdf = PdfDocument.LoadFromFileAsync(storage).AsTask(cancel).GetAwaiter().GetResult();
        var layers = new Dictionary<int, OcrPageResult>();
        Exception? failure = null;
        int latin = 0;
        progress(0, pages.Count);
        for (int i = 0; i < pages.Count; i++)
        {
            cancel.ThrowIfCancellationRequested();
            // One page that cannot be read does not cost the rest of the document its text.
            try
            {
                // Asked for again: what was read before gives way.
                bool anew = force && ScannedPdf.CanBeReadAnew(path, pages[i]);
                var page = RecognizePage(engines, pdf, path, pages[i], anew, cancel);
                if (OcrQuality.Of(page.Lines) is { Letters: >= 200, IsLatin: true }) latin++;
                // (A drawing filling a page of a paper with text keeps its labels to itself.)
                if (!onlyText || ScannedPdf.IsPageOfText(page)) layers[pages[i]] = page;
            }
            catch (Exception e) when (e is not OperationCanceledException) { failure = e; }
            progress(i + 1, pages.Count);
        }
        if (layers.Values.Sum(l => l.Characters) == 0)
        {
            if (failure != null) throw failure;
            // Without the Chinese one, a Chinese scan comes back empty: said as what it is.
            throw new NothingFound(ImageTextServices.MissingOcr("zh") != null
                ? Loc.S("没有在页面上识别到文字。如果这是中文扫描件，请在 Windows 设置 ▸ 时间和语言 ▸ 语言 中为中文安装“光学字符识别”。")
                : Loc.S("没有在页面上识别到文字。"));
        }
        // Mostly Latin letters, and only the readers of other scripts to read them with: said once, after it is done.
        poorlyRead = latin * 2 > layers.Count && !engines.Any(IsLatin);
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

    /// <summary>One page as shown (crop box, rotation), its long side about 2600 pixels whatever size the page says it is, read;
    /// when little comes out, with the other languages, then turned (pages scanned sideways or upside down).</summary>
    static OcrPageResult RecognizePage(List<OcrEngine> engines, PdfDocument pdf, string path, int number, bool anew, CancellationToken cancel)
    {
        using var page = pdf.GetPage((uint)(number - 1));
        var size = page.Size;
        double longSide = Math.Max(Math.Max(size.Width, size.Height), 1);
        double scale = Math.Min(Math.Min(6, 2600 / longSide), (OcrEngine.MaxImageDimension - 1) / longSide);
        uint width = Math.Max(1, (uint)Math.Round(size.Width * scale)), height = Math.Max(1, (uint)Math.Round(size.Height * scale));
        using var stream = new InMemoryRandomAccessStream();
        page.RenderToStreamAsync(stream, new PdfPageRenderOptions { DestinationWidth = width, DestinationHeight = height, BackgroundColor = Windows.UI.Color.FromArgb(255, 255, 255, 255) })
            .AsTask(cancel).GetAwaiter().GetResult();
        var decoder = BitmapDecoder.CreateAsync(stream).AsTask(cancel).GetAwaiter().GetResult();

        (List<OcrLine> Lines, OcrQuality.Reading Text, double Angle, int Width, int Height) Read(OcrEngine engine, BitmapRotation rotation)
        {
            var transform = new BitmapTransform { Rotation = rotation };
            using var bitmap = decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, transform,
                ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage).AsTask(cancel).GetAwaiter().GetResult();
            var result = engine.RecognizeAsync(bitmap).AsTask(cancel).GetAwaiter().GetResult();
            var lines = new List<OcrLine>();
            foreach (var line in result.Lines)
            {
                // Chinese comes back a character (or a few) per word: each its own box, as Vision's.
                var words = line.Words.Where(w => w.Text.Length > 0 && w.BoundingRect.Width > 0 && w.BoundingRect.Height > 0)
                    .Select(w => new OcrWord(w.Text, w.BoundingRect.X, w.BoundingRect.Y, w.BoundingRect.Width, w.BoundingRect.Height)).ToList();
                if (words.Count > 0) lines.Add(OcrQuality.Joined(new OcrLine(words)));
            }
            return (lines, OcrQuality.Of(lines), result.TextAngle ?? 0, bitmap.PixelWidth, bitmap.PixelHeight);
        }

        // The reader for Chinese first: it reads English too. What does not come out as text is read with the others, and turned
        // (pages scanned sideways or upside down); Latin letters, with the reader of a Latin language when Windows has one.
        var best = Read(engines[0], BitmapRotation.None);
        int turn = 0;
        var engine = engines[0];
        bool Better((List<OcrLine> Lines, OcrQuality.Reading Text, double Angle, int Width, int Height) reading) => reading.Text.Score > best.Text.Score * 1.1 + 4;
        if (!best.Text.IsText || Math.Abs(best.Angle) > 45)
            foreach (var (rotation, degrees) in new[] { (BitmapRotation.Clockwise90Degrees, 90), (BitmapRotation.Clockwise270Degrees, 270), (BitmapRotation.Clockwise180Degrees, 180) })
            {
                var reading = Read(engine, rotation);
                if (Better(reading)) { best = reading; turn = degrees; }
                if (best.Text.IsText && turn == degrees) break;
            }
        var upright = turn switch { 90 => BitmapRotation.Clockwise90Degrees, 180 => BitmapRotation.Clockwise180Degrees, 270 => BitmapRotation.Clockwise270Degrees, _ => BitmapRotation.None };
        foreach (var other in engines.Skip(1))
        {
            bool latin = IsLatin(other);
            if (best.Text.IsText && !(latin && best.Text.IsLatin)) continue;
            var reading = Read(other, upright);
            // (A reader of the page's own script: it need not do better by much.)
            if (Better(reading) || (latin && best.Text.IsLatin && reading.Text.IsLatin && reading.Text.Score >= best.Text.Score)) { best = reading; engine = other; }
        }
        // Windows gives the words of a page that tilts where they would be with it straightened about its middle.
        if (Math.Abs(best.Angle) is >= 0.2 and <= 40)
        {
            double angle = best.Angle * Math.PI / 180, cx = best.Width / 2.0, cy = best.Height / 2.0;
            double dx = cx * Math.Cos(angle) + cy * Math.Sin(angle) - cx, dy = -cx * Math.Sin(angle) + cy * Math.Cos(angle) - cy;
            best = best with { Lines = best.Lines.Select(l => new OcrLine(l.Words.Select(w => w with { X = w.X + dx, Y = w.Y + dy }).ToList()) { Angle = angle }).ToList() };
        }
        // What is text on the page already (a footer, a stamp drawn as text) is not put there twice.
        var text = ScannedPdf.TextOn(path, number, best.Width, best.Height, turn, hidden: !anew);
        var kept = best.Lines.Where(line =>
        {
            var box = line.Box;
            return !text.Any(t => t.X > box.MinX && t.X < box.MaxX && t.Y > box.MinY && t.Y < box.MaxY);
        }).ToList();
        return new OcrPageResult(number, best.Width, best.Height, kept) { Turn = turn, Replaces = anew };
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
