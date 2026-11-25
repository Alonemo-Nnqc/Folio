using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Folio.Core.Translate.Engine;
using Folio.Core.Translate.Layout;
using Folio.Core.Translate.Pdf;
using Folio.Core.Translate.Services;

namespace Folio.Core.Translate;

// Port of macos/.../FolioTranslate/TranslationJob.swift.

public sealed class EngineError(string message) : Exception(message)
{
    public static EngineError Unreadable => new(Loc.S("无法读取这个 PDF 文件。"));
    public static EngineError Encrypted => new(Loc.S("PDF 已加密或受密码保护，无法翻译。"));
    public static EngineError NoText => new(Loc.S("这个 PDF 中没有可翻译的文字（可能是扫描件，需要先进行文字识别）。"));
    /// <summary>The page range typed is not page numbers.</summary>
    public static EngineError UnreadablePages(string typed) => new(PageSelection.UnreadableMessage(typed));
    /// <summary>The page range typed has none of the document's pages (it has <paramref name="count"/>).</summary>
    public static EngineError PagesOutOfRange(string typed, int count) => new(Loc.S("这篇 PDF 共 %lld 页，页码范围「%@」里没有其中的页。", count, typed));
    public static EngineError AlreadyInTarget(string language) => new(Loc.S("这篇论文已经是%@，不需要翻译成%@。可以在翻译设置里换一种译文语言。", language, language));
    public static EngineError TooManyRefused(int count) => new(Loc.S("翻译服务拒绝翻译 %lld 个段落（内容审核）。请换一个翻译服务或模型再试。", count));
    /// <summary>The model's reply ends at its output limit even for a single paragraph.</summary>
    public static EngineError ReplyCutOff => new(Loc.S("模型的回复在输出上限处被截断，连一个段落也放不下。请换用输出上限更高的模型，或调低思考程度。"));
}

/// <summary>Translates one PDF with the native engine: layout analysis, a glossary of the paper's terms, batched
/// requests to the chosen service, and the translated PDFs set in the original layout.</summary>
public sealed class TranslationJob
{
    public TranslationRequest Request { get; }
    public string LogPath { get; }
    readonly CancellationTokenSource _cancel = new();
    /// <summary>The user stopped it. The token above also stops the other batches when one fails: that is a failure, not a cancel.</summary>
    volatile bool _cancelled;
    readonly RateGate _rateGate = new();
    /// <summary>What goes wrong while the job works (shown at once), and when a request last came back.</summary>
    readonly JobActivity _activity = new();

    /// <summary>Where translations are cached and logs written. Tests point it at a scratch folder.</summary>
    public static string SupportDirectory { get; set; } = Path.Combine(AppSettings.Folder, "Translation");

    public TranslationJob(TranslationRequest request, string? logPath = null)
    {
        Request = request;
        LogPath = logPath ?? Path.Combine(SupportDirectory, "logs", $"translate-{DateTime.Now:yyyyMMdd-HHmmss}.log");
    }

    public void Cancel()
    {
        _cancelled = true;
        _cancel.Cancel();
        LocalProcess.TerminateAll();
    }

    public bool IsCancelled => _cancelled;

    /// <summary>Runs the job; events arrive on worker threads. The returned event is the last one (also emitted).</summary>
    public async Task<TranslationEvent> Run(Action<TranslationEvent> emit)
    {
        var log = new TranslationLog(LogPath);
        TranslationEvent result;
        try
        {
            result = await Task.Run(() => RunJob(emit, log, _cancel.Token));
        }
        catch (Exception e) when (IsCancelled || (!_cancel.IsCancellationRequested && (e is OperationCanceledException || e is ProviderError { Kind: ProviderError.Kinds.Cancelled })))
        {
            result = new TranslationEvent.Cancelled();
        }
        catch (Exception e)
        {
            log.Write($"FAILED: {e}");
            result = new TranslationEvent.Failed(Message(e), LogPath);
        }
        log.Write($"end: {result}");
        emit(result);
        return result;
    }

    public static string Message(Exception error) => error switch
    {
        TranslationConfigurationError or EngineError => error.Message,
        ProviderError p => TranslationErrorClassifier.Classify(p.Detail + (p.Host != null ? $" https://{p.Host}/" : "")).Message,
        IOException io when io.HResult is unchecked((int)0x80070070) or unchecked((int)0x80070027) => TranslationErrorClassifier.Classify("disk full").Message,
        OutOfMemoryException => TranslationErrorClassifier.Classify("out of memory").Message,
        _ => TranslationErrorClassifier.Classify(error.Message).Message,
    };

    async Task<TranslationEvent> RunJob(Action<TranslationEvent> emit, TranslationLog log, CancellationToken cancel)
    {
        var options = Request.Options;
        var reported = new MonotonicProgress(emit);
        _activity.Attach(emit);
        log.Write($"translate {Path.GetFileName(Request.Input)} with {Request.ServiceId} {options.LangIn}→{options.LangOut}");
        var provider = ProviderFactory.Make(Request.ServiceId, Request.FieldValues, Request.Secrets, options.Concurrency);
        log.Write($"model: {provider.ModelName ?? "-"}, {provider.Limits.Concurrency} requests at a time"
                  + (options.Concurrency is { } chosen ? $" (同时请求数 set to {chosen})" : ""));
        if (ModelCheck.Check(Request.ServiceId, Request.FieldValues) is { } check)
        {
            // Said at once, not discovered from a translation that takes an hour (as on the Mac).
            var service = TranslationServiceCatalog.Service(Request.ServiceId)?.DisplayName ?? Request.ServiceId;
            var message = check.Replacement is { } used
                ? Loc.S("设置中的模型“%@”已不在%@的可用模型中，本次改用 %@。可在 设置 ▸ 翻译 中更换。", check.Saved, service, used)
                : Loc.S("设置中的模型“%@”已不在%@的可用模型中，本次使用它的默认模型。可在 设置 ▸ 翻译 中更换。", check.Saved, service);
            log.Write($"saved model {check.Saved} is not offered (offered: {string.Join(", ", check.Offered)}), using {check.Replacement ?? "the default"}");
            emit(new TranslationEvent.Problem(message));
        }

        // 1. Layout.
        emit(new TranslationEvent.Stage(Loc.S("分析版面")));
        PdfSource source;
        try { source = PdfSource.Open(Request.Input); }
        catch (Exception e) when (e.Message.Contains("password", StringComparison.OrdinalIgnoreCase) || e.Message.Contains("encrypt", StringComparison.OrdinalIgnoreCase))
        {
            throw EngineError.Encrypted;
        }
        catch { throw EngineError.Unreadable; }
        using var sourceScope = source;
        var started = Stopwatch.StartNew();
        int pageCount = source.Pages.Count;
        var selection = PageSelection.Parse(options.Pages);
        var selected = selection.Pages(pageCount);
        if (selected.Count == 0)
        {
            // Said as it is: no pages is not a PDF without text.
            log.Write($"pages \"{options.Pages}\" select none of {pageCount}");
            var typed = (options.Pages ?? "").Trim();
            throw selection.Kind == PageSelection.Kinds.Unreadable ? EngineError.UnreadablePages(typed) : EngineError.PagesOutOfRange(typed, pageCount);
        }
        var analyzer = new LayoutAnalyzer(new LayoutAnalyzer.Options { TranslateTables = options.TranslateTables, TranslateReferences = options.TranslateReferences });
        // Scans are measured in a render of each page, and it says which colour the paper is under the words.
        var renders = new Dictionary<int, ScanPage.Shown>();
        if (ImageText.Platform is { } platform)
            foreach (var number in LayoutAnalyzer.RecognizedScans(source, selected.Max()))
            {
                cancel.ThrowIfCancellationRequested();
                var page = source.Pages[number - 1];
                var geometry = PdfComposer.Geometry(page);
                var crop = geometry.CropBox;
                var shown = geometry.Rotation % 180 == 0 ? crop : new Rect(0, 0, crop.H, crop.W);
                try
                {
                    double scale = Math.Min(6, 2400 / Math.Max(Math.Max(crop.W, crop.H), 1));
                    if (await platform.Render(Request.Input, number, shown, shown, scale) is not { } bitmap) continue;
                    var interpreter = new ContentInterpreter();
                    interpreter.Run(page);
                    analyzer.Scans[number] = ScanPage.Read(page, interpreter, new ScanPage.Shown(bitmap, crop, geometry.Rotation));
                    // Half as fine is enough for colours.
                    renders[number] = new ScanPage.Shown(bitmap.Reduced(2), crop, geometry.Rotation);
                }
                catch (Exception e) { log.Write($"page {number}: not rendered, {e.Message}"); }
            }
        var analysed = analyzer.Analyze(source, selected);
        cancel.ThrowIfCancellationRequested();
        var output = options.OnlyIncludeTranslatedPages || selection.Kind == PageSelection.Kinds.All ? selected : Enumerable.Range(1, pageCount).ToList();
        var byNumber = analysed.ToDictionary(l => l.Number);
        var layouts = output.Select(n => byNumber.GetValueOrDefault(n) ?? Untouched(source, n)).OfType<PageLayout>().ToList();
        var segments = SegmentBuilder.Segments(analysed, options.LangOut);
        log.Write(string.Create(CultureInfo.InvariantCulture, $"layout: {analysed.Count} pages, {segments.Count} segments in {started.Elapsed.TotalSeconds:F2} s"));
        reported.Report(0.04);
        if (segments.Count == 0)
        {
            var language = TranslationOptions.CommonLanguages.FirstOrDefault(l => l.Code == options.LangOut).Name ?? options.LangOut;
            throw analysed.Any(l => SegmentBuilder.Segments(l).Count > 0) ? EngineError.AlreadyInTarget(language) : EngineError.NoText;
        }

        // 2. Context and glossary.
        // The user's file first, then Folio's glossary: terms written by the user and terms found in earlier papers.
        var store = GlossaryStore.Shared;
        var fromFile = ReadGlossary(options.GlossaryFile);
        var known = fromFile.Select(g => g.Source.ToLowerInvariant()).ToHashSet();
        var context = new TranslationContext(options.LangIn, options.LangOut, segments.FirstOrDefault(s => s.Kind == BlockKind.Title)?.Source, Summary(segments),
                                             [.. fromFile, .. store.Entries(options.LangOut).Where(g => !known.Contains(g.Source.ToLowerInvariant()))]);
        var glossary = new GlossaryBox(context.Glossary);
        using var termCancel = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        Task? termTask = null;
        if (provider.Limits.UsesContext)
        {
            var excerpt = TermExcerpt(segments);
            termTask = Task.Run(async () =>
            {
                try
                {
                    using var timeout = CancellationTokenSource.CreateLinkedTokenSource(termCancel.Token);
                    timeout.CancelAfter(TimeSpan.FromSeconds(150));
                    var terms = await provider.ExtractTerms(excerpt, context, timeout.Token);
                    glossary.Add(terms);
                    // Kept for the papers after this one (what the glossary already has stays as it is).
                    var learned = options.RememberTerms ? store.Learn(terms, options.LangOut, context.Title) : 0;
                    log.Write($"glossary: {glossary.Entries.Count} terms, {learned} new kept");
                }
                catch (Exception e) { log.Write($"term extraction failed, continuing without: {e.Message}"); }
                glossary.MarkComplete();
            });
        }
        reported.Report(0.06);

        // 3. Translations: the cache first, then the service.
        var cache = new TranslationCache(Path.Combine(SupportDirectory, "cache"), Request.Input, Signature(Request), options.IgnoreCache);
        try
        {
            var state = new TranslationState(segments);
            var continuations = Continuations.Find(segments, analysed);
            var joinedParts = new Dictionary<string, Continuation>();
            foreach (var c in continuations) joinedParts.TryAdd(c.Joined.Id, c);
            var inContinuation = continuations.SelectMany(c => c.Parts).Select(p => p.Id).ToHashSet();
            log.Write($"continued paragraphs: {continuations.Count}");
            foreach (var c in continuations)
                if (cache.Lookup(c.Joined.Source) is { } hit && Continuations.Split(hit, c) is { } pieces)
                    for (int k = 0; k < c.Parts.Count; k++) state.Store(pieces[k], c.Parts[k]);
            foreach (var segment in segments)
            {
                if (segment.Kind == BlockKind.Heading && StandardHeadings.Translate(segment.Source, options.LangOut) is { } heading) state.Store(heading, segment);
                else if (segment.Kind == BlockKind.TableCell && StandardCells.Translate(segment.Source, options.LangOut) is { } cell) state.Store(cell, segment);
                else if (cache.Lookup(segment.Source) is { } hit)
                    state.Store(segment.Kind == BlockKind.Heading ? HeadingNumbers.RestoreSpace(segment.Source, hit) : hit, segment);
            }
            log.Write($"cache: {state.DoneCount} of {segments.Count} segments");
            var renderer = new TranslationRenderer(source, options.LangOut) { PageRenders = renders };
            var previews = new PreviewWriter(renderer, layouts, segments, Request.OutputDirectory, emit);

            // What is left to send: whole paragraphs, the continued ones as one text each. A text the paper has more than
            // once (a table's "Method", a label under each of several figures) is sent once, and its translation set
            // for all of them: less to translate, and never two translations of the same words.
            var units = new List<TextSegment>();
            var sent = new HashSet<string>();
            var firstWithSource = new Dictionary<string, string>();
            var twins = new Dictionary<string, List<TextSegment>>();
            foreach (var segment in segments.Where(s => state.Translation(s) == null))
            {
                if (inContinuation.Contains(segment.Id))
                {
                    var c = continuations.FirstOrDefault(c => c.Parts.Any(p => p.Id == segment.Id));
                    if (c == null || sent.Contains(c.Joined.Id)) continue;
                    if (c.Parts.All(p => state.Translation(p) == null))
                    {
                        sent.Add(c.Joined.Id);
                        units.Add(c.Joined);
                        continue;
                    }
                }
                if (firstWithSource.TryGetValue(segment.Source, out var first))
                {
                    if (!twins.TryGetValue(first, out var same)) twins[first] = same = [];
                    same.Add(segment);
                    continue;
                }
                firstWithSource[segment.Source] = segment.Id;
                units.Add(segment);
            }
            if (twins.Count > 0) log.Write($"repeated texts sent once: {twins.Values.Sum(t => t.Count)}");
            var refusals = new RefusalCount(Math.Max(5, segments.Count / 20));
            var batches = Batches(units, provider.Limits);
            int total = segments.Count;
            int doneChars = state.Characters.Done;
            var estimate = new ProgressEstimate(doneChars, doneChars + units.Sum(u => u.Source.Length), provider.Limits,
                                                ImageText.IsCjk(options.LangOut.ToLowerInvariant()) ? 0.5 : 1.1);
            var serviceName = TranslationServiceCatalog.Service(Request.ServiceId)?.DisplayName ?? Request.ServiceId;
            _activity.Touch();
            var target = new ProgressTarget(() => 0.08 + 0.86 * estimate.Fraction());
            using var tickerStop = new CancellationTokenSource();
            bool layingOut = false;
            var ticker = Task.Run(async () =>
            {
                double shown = target.Value();
                int lastCount = -1;
                string lastWaiting = "";
                bool slowReported = false;
                while (!tickerStop.IsCancellationRequested)
                {
                    double goal = target.Value();
                    shown = Math.Min(goal, shown + Math.Max(0.001, (goal - shown) * 0.2));
                    reported.Report(shown);
                    if (shown <= 0.94 && !Volatile.Read(ref layingOut))
                    {
                        int count = Math.Max(state.DoneCount, Math.Min(total - 1, (int)(total * (shown - 0.08) / 0.86)));
                        double idle = _activity.IdleSeconds;
                        if (idle >= 90 && !slowReported)
                        {
                            // Far slower than a batch should take (10 to 30 s): why, and what to do about it (as on the Mac).
                            slowReported = true;
                            var modelName = provider.ModelName is { } m ? $"（{m}）" : "";
                            log.Write($"slow: nothing back for {(int)idle} s from {provider.ModelName ?? serviceName}");
                            emit(new TranslationEvent.Problem(Loc.S("%@%@已经 %lld 秒没有返回任何一批译文，正常一批只要 10 到 30 秒。多半是模型在长时间思考；可以在 设置 ▸ 翻译 中换用更快的模型。", serviceName, modelName, (int)idle)));
                        }
                        if (idle >= 60)
                        {
                            // Nothing back for a minute: say what it waits for, rather than seem to hang.
                            var waiting = Loc.S("正在等待%@回复（已等 %lld 分钟）", serviceName, (int)(idle / 60));
                            if (waiting != lastWaiting) { lastWaiting = waiting; emit(new TranslationEvent.Stage(waiting)); }
                            lastCount = -1;
                        }
                        else if (count != lastCount)
                        {
                            lastCount = count;
                            lastWaiting = "";
                            emit(new TranslationEvent.Stage(TranslationStageText.Paragraphs(count, total)));
                        }
                    }
                    try { await Task.Delay(200, tickerStop.Token); } catch (OperationCanceledException) { }
                }
            });
            // 3b. Words in pictures, when asked for: read while the text is being translated (not after it), then translated
            // as soon as the paper's terms are known, side by side with the text's batches.
            var imageWork = options.TranslateImageText && ImageText.Platform != null
                ? Task.Run(() => TranslateImageText(source, selected, analysed, provider, context, glossary, cache, log, estimate, refusals, cancel))
                : null;
            try
            {
                // The first batches (title, abstract, introduction: what is read first, and shown first) go at once. The
                // others wait a moment for the paper's terms, so that the whole paper translates a term the same way:
                // without the wait every batch of a short paper would be under way before the terms are known.
                int leading = termTask == null ? batches.Count : Math.Max(1, Math.Min(2, provider.Limits.Concurrency / 2));
                var termsDeadline = DateTime.UtcNow.AddSeconds(provider.Limits.StartupSeconds * 2 + 8);
                // Sets the translation of one segment. A text that came back empty or as it went (still in the source
                // language) is not kept for next time: another run, or another service, may do better.
                void Settle(TextSegment segment, string raw)
                {
                    var translated = segment.Kind == BlockKind.Heading ? HeadingNumbers.RestoreSpace(segment.Source, raw) : raw;
                    state.Store(translated.Length == 0 ? segment.Source : translated, segment);
                    if (!IsUntranslated(translated, segment.Source, options.LangOut)) cache.Store(translated, segment.Source);
                }
                async Task RunBatch(List<TextSegment> batch, bool waitsForTerms)
                {
                    if (waitsForTerms) await glossary.Wait(termsDeadline, cancel);
                    var batchContext = context with { Glossary = glossary.Entries };
                    var texts = await TranslateBatch(batch, provider, batchContext, log, estimate, refusals, cancel);
                    for (int i = 0; i < batch.Count; i++)
                    {
                        var segment = batch[i];
                        var raw = texts[i];
                        var same = twins.GetValueOrDefault(segment.Id) ?? [];
                        if (raw == null)
                        {
                            // Refused by the service's content review: the original stays, and is not cached.
                            foreach (var part in (joinedParts.TryGetValue(segment.Id, out var refused) ? refused.Parts : [segment]).Concat(same)) state.Store(part.Source, part);
                            continue;
                        }
                        if (joinedParts.TryGetValue(segment.Id, out var continuation))
                        {
                            if (Continuations.Split(raw, continuation) is { } pieces)
                            {
                                for (int k = 0; k < continuation.Parts.Count; k++) state.Store(pieces[k], continuation.Parts[k]);
                                if (!IsUntranslated(raw, segment.Source, options.LangOut)) cache.Store(raw, segment.Source);
                            }
                            else
                            {
                                // The translator moved a formula across the break: the parts go on their own.
                                log.Write($"continued paragraph p{segment.Page} not splittable, translating its parts apart");
                                var apart = await TranslateBatch(continuation.Parts, provider, batchContext, log, estimate, refusals, cancel);
                                for (int k = 0; k < continuation.Parts.Count; k++)
                                {
                                    if (apart[k] is { } text) Settle(continuation.Parts[k], text);
                                    else state.Store(continuation.Parts[k].Source, continuation.Parts[k]);
                                }
                            }
                            continue;
                        }
                        Settle(segment, raw);
                        foreach (var twin in same) Settle(twin, raw);
                    }
                }
                var pending = new Queue<List<TextSegment>>(batches);
                var running = new List<Task>();
                int batchesStarted = 0;
                void StartNext()
                {
                    if (pending.Count > 0) running.Add(RunBatch(pending.Dequeue(), batchesStarted++ >= leading));
                }
                for (int i = 0; i < Math.Max(1, provider.Limits.Concurrency); i++) StartNext();
                while (running.Count > 0)
                {
                    var finished = await Task.WhenAny(running);
                    running.Remove(finished);
                    await finished; // rethrows: the job fails, the others are cancelled with it
                    cache.SaveIfNeeded();
                    previews.Update(state.Snapshot(), state.CompletedPages);
                    StartNext();
                }
            }
            catch
            {
                _cancel.Cancel();
                throw;
            }
            finally
            {
                termCancel.Cancel();
            }
            cancel.ThrowIfCancellationRequested();
            if (refusals.Count > 0) emit(new TranslationEvent.Notice(Loc.S("翻译服务拒绝翻译 %lld 个段落（内容审核），这些段落保留了原文。", refusals.Count)));

            if (imageWork != null)
            {
                Volatile.Write(ref layingOut, true);
                emit(new TranslationEvent.Stage(Loc.S("翻译图片中的文字")));
                renderer.ImageTexts = await imageWork;
            }

            // 4. The translated PDFs. Setting the pages takes a moment too; about this long, going by their number.
            Volatile.Write(ref layingOut, true);
            emit(new TranslationEvent.Stage(TranslationStageText.Layout));
            double renderSeconds = 0.5 + layouts.Count * 0.08;
            var renderStarted = Stopwatch.StartNew();
            target.Set(() => 0.94 + 0.05 * (1 - Math.Exp(-renderStarted.Elapsed.TotalSeconds / renderSeconds)));
            await previews.Finish();
            var name = Path.GetFileNameWithoutExtension(Request.Input);
            bool wantMono = options.Outputs != TranslationOptions.OutputKinds.dual, wantDual = options.Outputs != TranslationOptions.OutputKinds.mono;
            var result = renderer.Render(layouts, segments, state.Snapshot(), wantMono, wantDual, options.DualLayout, null);
            Directory.CreateDirectory(Request.OutputDirectory);
            string? monoPath = null, dualPath = null;
            if (result.Mono != null) File.WriteAllBytes(monoPath = Path.Combine(Request.OutputDirectory, name + ".mono.pdf"), result.Mono);
            if (result.Dual != null) File.WriteAllBytes(dualPath = Path.Combine(Request.OutputDirectory, name + ".dual.pdf"), result.Dual);
            log.Write(string.Create(CultureInfo.InvariantCulture, $"done in {started.Elapsed.TotalSeconds:F1} s"));
            tickerStop.Cancel();
            await ticker;
            reported.Report(1);
            return new TranslationEvent.Finished(monoPath, dualPath);
        }
        finally
        {
            cache.Save();
        }
    }

    static PageLayout? Untouched(PdfSource source, int number)
    {
        if (number < 1 || number > source.Pages.Count) return null;
        var geometry = PdfComposer.Geometry(source.Pages[number - 1]);
        return new PageLayout { Number = number, MediaBox = geometry.MediaBox, CropBox = geometry.CropBox };
    }

    /// <summary>Who translates: the cache is only shared between runs of the same service, model, thinking level and languages.</summary>
    public static string Signature(TranslationRequest request)
    {
        var service = TranslationServiceCatalog.Service(request.ServiceId);
        var field = service?.ModelField;
        var model = field == null ? "" : request.FieldValues.GetValueOrDefault(field.Option) is { Length: > 0 } v ? v : field.DefaultValue ?? "";
        var thinking = "";
        if (ReasoningEffort.GetSupport(request.ServiceId, request.FieldValues) is ReasoningEffort.Support.Choices choices
            && ReasoningEffort.Current(request.ServiceId, request.FieldValues) is { } level && level != choices.Default)
            thinking = $"|thinking={level}";
        return $"{request.ServiceId}|{model}{thinking}|{request.Options.LangIn}|{request.Options.LangOut}|v1";
    }

    /// <summary>Batches of about one size. A short text is cut into as many batches as the service runs at once (down to a
    /// third of its usual size), so that all of them run side by side: four batches where eight could run take twice as long.</summary>
    public static List<List<TextSegment>> Batches(List<TextSegment> segments, ProviderLimits limits)
    {
        int totalCharacters = segments.Sum(s => s.Source.Length);
        int even = (int)Math.Ceiling(totalCharacters / (double)Math.Max(limits.Concurrency, 1));
        int size = Math.Min(limits.BatchCharacters, Math.Max(Math.Max(limits.BatchCharacters / 3, 400), even));
        var result = new List<List<TextSegment>>();
        var current = new List<TextSegment>();
        int characters = 0;
        foreach (var segment in segments)
        {
            int length = segment.Source.Length;
            if (current.Count > 0 && (characters + length > size || current.Count >= limits.BatchItems))
            {
                result.Add(current);
                current = [];
                characters = 0;
            }
            current.Add(segment);
            characters += length;
        }
        if (current.Count > 0) result.Add(current);
        return result;
    }

    /// <summary>One batch, retried on passing failures; a batch that keeps failing is split in halves. Null for a
    /// paragraph the service refused (content review). A translation that lost a formula's placeholder is asked for again.</summary>
    /// <summary>TRANS-40: the words in the pictures of pages, with their translations, by page.</summary>
    async Task<Dictionary<int, List<(ImageText.Line Line, string Translation)>>> TranslateImageText(PdfSource source, List<int> pages, List<PageLayout> layouts,
        ITranslationProvider provider, TranslationContext context, GlossaryBox glossary, TranslationCache cache, TranslationLog log, ProgressEstimate estimate,
        RefusalCount refusals, CancellationToken cancel)
    {
        var lines = new List<ImageText.Line>();
        foreach (var number in pages)
        {
            cancel.ThrowIfCancellationRequested();
            try { lines.AddRange(await ImageText.Recognize(Request.Input, source, number, Request.Options.LangIn, layouts.FirstOrDefault(l => l.Number == number))); }
            catch (Exception e) when (e is not OperationCanceledException) { log.Write($"image text p{number}: {e.Message}"); }
        }
        log.Write($"image text: {lines.Count} lines");
        var result = new Dictionary<int, List<(ImageText.Line, string)>>();
        if (lines.Count == 0) return result;
        // The paper's terms, if they come within a few seconds: labels are not held up long for them.
        for (var deadline = DateTime.UtcNow.AddSeconds(8); provider.Limits.UsesContext && !glossary.IsComplete && DateTime.UtcNow < deadline;)
            await Task.Delay(200, cancel);
        context = context with { Glossary = glossary.Entries };
        // A label set over several lines is translated whole (word order differs between languages) and shared out
        // across its lines again.
        var units = ImageTextUnits.Units(lines).Where(u => !ImageTextUnits.IsName(u.Text)).ToList();
        var withText = lines.Select(l => l.Page).ToHashSet();
        context = context with
        {
            FigureCaptions = layouts.Where(l => withText.Contains(l.Number))
                .SelectMany(l => l.Blocks.Where(b => b.Kind == BlockKind.Caption).Select(b => b.Text.Length > 400 ? b.Text[..400] : b.Text)).Take(12).ToList(),
        };
        // One segment per distinct text (a label repeated in a figure is translated once), in reading order.
        var translations = new Dictionary<string, string>();
        var pending = new List<TextSegment>();
        var seen = new HashSet<string>();
        foreach (var unit in units)
        {
            if (!seen.Add(unit.Text)) continue;
            // A label a service kept as it was is asked again (another service may well translate it).
            if (cache.Lookup(unit.Text) is { } hit && hit != unit.Text) translations[unit.Text] = hit;
            else pending.Add(new TextSegment { Page = 0, Block = -1 - pending.Count, Kind = BlockKind.Figure, Source = unit.Text });
        }
        // The batches side by side, as the text's.
        var batches = Batches(pending, provider.Limits with { BatchItems = Math.Max(provider.Limits.BatchItems, 120) });
        var done = await Task.WhenAll(batches.Select(batch => TranslateBatch(batch, provider, context, log, estimate, refusals, cancel)));
        for (int b = 0; b < batches.Count; b++)
            for (int i = 0; i < batches[b].Count; i++)
            {
                if (done[b][i] is not { Length: > 0 } text) continue;
                translations[batches[b][i].Source] = text;
                if (text != batches[b][i].Source) cache.Store(text, batches[b][i].Source);
            }
        bool cjk = ImageText.IsCjk(Request.Options.LangOut);
        foreach (var unit in units)
        {
            if (!translations.TryGetValue(unit.Text, out var translation) || translation == unit.Text) continue;
            var pieces = ImageTextUnits.Split(translation, unit.Members.Select(m => lines[m].Vertical ? lines[m].Rect.H : lines[m].Rect.W).ToList(), cjk,
                                              Request.Options.LangOut);
            for (int k = 0; k < unit.Members.Count; k++)
            {
                var line = lines[unit.Members[k]];
                if (!result.TryGetValue(line.Page, out var list)) result[line.Page] = list = [];
                list.Add((line, pieces[k]));
            }
        }
        return result;
    }

    async Task<List<string?>> TranslateBatch(List<TextSegment> batch, ITranslationProvider provider, TranslationContext context, TranslationLog log,
                                             ProgressEstimate estimate, RefusalCount refusals, CancellationToken cancel)
    {
        var items = batch.Select(s => new TranslationItem(s.Source, s.Kind)).ToList();
        if (provider.Limits.UsesContext)
        {
            var text = string.Join("\n", batch.Select(s => s.Source)).ToLowerInvariant();
            context = context with { Glossary = context.Glossary.Where(g => text.Contains(g.Source.ToLowerInvariant())).Take(80).ToList() };
        }
        Exception? lastError = null;
        bool refused = false, truncated = false;
        const int attemptCount = 5;
        for (int attempt = 0; attempt < attemptCount; attempt++)
        {
            cancel.ThrowIfCancellationRequested();
            await _rateGate.Wait(cancel);
            int characters = batch.Sum(s => s.Source.Length);
            int request = estimate.Begin(characters);
            try
            {
                var watch = Stopwatch.StartNew();
                // A reply read as it arrives says how far it has come, and that the service is alive.
                StreamProgress.Sink = received => { estimate.Received(request, received); _activity.Touch(); };
                List<string> texts;
                try { texts = (await provider.Translate(items, context, cancel)).Select(Clean).ToList(); }
                finally { StreamProgress.Sink = null; }
                log.Write(string.Create(CultureInfo.InvariantCulture, $"batch of {batch.Count} ({characters} chars) in {watch.Elapsed.TotalSeconds:F1} s"));
                estimate.Finish(request);
                _activity.Touch();
                // What a model may get wrong in a text: a formula's placeholder lost or doubled (each has to be there
                // exactly once), nothing given back, or the text given back as it went, untranslated. Such texts get a
                // second chance, and the better of the two answers is kept; failing that, the typesetter puts a missing
                // formula at the end, and a text still untranslated stays as the original.
                var target = context.TargetLanguage;
                var broken = Enumerable.Range(0, batch.Count).Where(i => Defects(texts[i], batch[i].Source, target) > 0).ToList();
                if (broken.Count > 0 && provider.Limits.UsesContext)
                {
                    log.Write($"{broken.Count} of {batch.Count} came back incomplete (placeholders lost, empty or untranslated), asking again");
                    try
                    {
                        var again = (await provider.Translate(broken.Select(i => items[i]).ToList(), context, cancel)).Select(Clean).ToList();
                        for (int k = 0; k < broken.Count && k < again.Count; k++)
                        {
                            int i = broken[k];
                            if (Defects(again[k], batch[i].Source, target) < Defects(texts[i], batch[i].Source, target)) texts[i] = again[k];
                        }
                    }
                    catch (Exception) when (!cancel.IsCancellationRequested) { }
                }
                return texts.Cast<string?>().ToList();
            }
            catch (ProviderError e) when (e.Kind != ProviderError.Kinds.Cancelled)
            {
                estimate.Abandon(request);
                lastError = e;
                log.Write($"attempt {attempt + 1} failed: {e.Detail[..Math.Min(500, e.Detail.Length)]}");
                if (e.Kind == ProviderError.Kinds.Refused) { refused = true; break; }
                // Cut off at the model's output limit: the same batch would be cut off again; smaller ones fit.
                if (e.Kind == ProviderError.Kinds.Truncated)
                {
                    if (batch.Count <= 1) throw EngineError.ReplyCutOff;
                    truncated = true;
                    break;
                }
                if (!e.IsRetryable) throw;
                _activity.Touch();
                // The last attempt: the job ends with the error, no waiting first.
                if (attempt + 1 >= attemptCount) break;
                // Shown now, with what the service said: the job is not stuck, and the user may well fix the cause.
                var said = Message(e);
                _activity.Report(Loc.S("%@（正在第 %lld 次尝试）", said, attempt + 2), said);
                double wait = e.RetryAfter ?? Math.Min(20, Math.Pow(2, attempt) * 1.5);
                if (e.Kind == ProviderError.Kinds.Http && e.Status == 429) await _rateGate.Pause(wait);
                else await Task.Delay(TimeSpan.FromSeconds(wait), cancel);
                // An unreadable reply for a big batch: try smaller ones.
                if (e.Kind == ProviderError.Kinds.InvalidResponse && batch.Count > 1 && attempt >= 1) break;
            }
        }
        // Halves until the paragraph that is the problem is found: a refusal or an unreadable reply. A failure of the
        // service itself is the same for half the text, and is not tried again and again.
        if (batch.Count > 1 && (refused || truncated || lastError is ProviderError { Kind: ProviderError.Kinds.InvalidResponse }))
        {
            int half = batch.Count / 2;
            var first = await TranslateBatch(batch[..half], provider, context, log, estimate, refusals, cancel);
            var second = await TranslateBatch(batch[half..], provider, context, log, estimate, refusals, cancel);
            return [.. first, .. second];
        }
        if (refused)
        {
            log.Write($"refused by the service: p{batch[0].Page} \"{batch[0].Source[..Math.Min(80, batch[0].Source.Length)]}\"");
            if (!refusals.Add()) throw EngineError.TooManyRefused(refusals.Count);
            return [null];
        }
        throw lastError ?? new ProviderError(ProviderError.Kinds.InvalidResponse, "translation failed");
    }

    public static bool PlaceholdersIntact(string text, string source) => PlaceholderErrors(text, source) == 0;

    /// <summary>Every formula placeholder of the source once, none added. {v0} (a break) may move or go.</summary>
    public static int PlaceholderErrors(string text, string source)
    {
        var want = Placeholders.Numbers(source).Where(n => n != 0).GroupBy(n => n).ToDictionary(g => g.Key, g => g.Count());
        var got = Placeholders.Numbers(text).Where(n => n != 0).GroupBy(n => n).ToDictionary(g => g.Key, g => g.Count());
        return want.Keys.Union(got.Keys).Sum(k => Math.Abs(want.GetValueOrDefault(k) - got.GetValueOrDefault(k)));
    }

    /// <summary>How much is wrong with a translation: its placeholder errors, and far more when it is empty or untranslated.</summary>
    public static int Defects(string text, string source, string target) =>
        PlaceholderErrors(text, source) + (IsUntranslated(text, source, target) ? 100 : 0);

    /// <summary>Nothing came back for a text with words in it, or the text came back as it went: a sentence (four words
    /// or more) that is the source again, or, for a language written in another script than the source's (Chinese,
    /// Japanese, Korean), without a single character of that script. Names, numbers and short labels may well stay
    /// as they are, and do not count.</summary>
    public static bool IsUntranslated(string text, string source, string target)
    {
        if (!SegmentBuilder.HasWords(source)) return false;
        var translation = text.Trim();
        if (translation.Length == 0) return true;
        var plain = Placeholders.Replace(source, _ => " ");
        int words = 0, letters = 0;
        foreach (var rune in (plain + " ").EnumerateRunes())
        {
            if (System.Text.Rune.IsLetter(rune)) { letters++; continue; }
            if (letters >= 2) words++;
            letters = 0;
        }
        if (words < 4 || SegmentBuilder.IsInScript(target, plain, 0.3)) return false;
        if (translation == source.Trim()) return true;
        var language = target.ToLowerInvariant();
        if (!(language.StartsWith("zh") || language.StartsWith("ja") || language.StartsWith("ko"))) return false;
        return !translation.EnumerateRunes().Any(r => r.Value is >= 0x3040 and <= 0x30FF or >= 0x3400 and <= 0x4DBF or >= 0x4E00 and <= 0x9FFF or >= 0xAC00 and <= 0xD7AF);
    }

    public static string Clean(string text) => text.Replace("\r", " ").Replace("\n", " ").Trim();

    /// <summary>The abstract: the first long paragraph on the first page.</summary>
    public static string? Summary(List<TextSegment> segments)
    {
        var firstPage = segments.Where(s => s.Page == segments.FirstOrDefault()?.Page && s.Kind == BlockKind.Paragraph).ToList();
        var paragraph = firstPage.FirstOrDefault(s => s.Source.Split(' ').Length >= 60) ?? firstPage.FirstOrDefault();
        return paragraph == null ? null : Placeholders.Replace(paragraph.Source, _ => "…");
    }

    /// <summary>What terms are learnt from: title, abstract, headings and captions.</summary>
    public static string TermExcerpt(List<TextSegment> segments)
    {
        var parts = new List<string>();
        if (segments.FirstOrDefault(s => s.Kind == BlockKind.Title) is { } title) parts.Add(title.Source);
        if (Summary(segments) is { } summary) parts.Add(summary);
        parts.AddRange(segments.Where(s => s.Kind == BlockKind.Heading).Select(s => s.Source));
        parts.AddRange(segments.Where(s => s.Kind == BlockKind.Caption).Select(s => s.Source));
        parts.AddRange(segments.Where(s => s.Kind == BlockKind.Paragraph).Take(6).Select(s => s.Source));
        var excerpt = new StringBuilder();
        foreach (var part in parts)
            if (excerpt.Length + part.Length < 6000) excerpt.Append(Placeholders.Replace(part, _ => "…")).Append('\n');
        return excerpt.ToString();
    }

    /// <summary>A CSV glossary: source,target per line (more columns are ignored; a field with a comma in it is in quotes).</summary>
    public static List<GlossaryEntry> ReadGlossary(string? path)
    {
        if (string.IsNullOrEmpty(path) || !File.Exists(path)) return [];
        var result = new List<GlossaryEntry>();
        foreach (var line in File.ReadAllLines(path))
        {
            var columns = CsvFields(line);
            if (columns.Count < 2 || columns[0].Length == 0 || columns[1].Length == 0 || columns[0].ToLowerInvariant() == "source") continue;
            result.Add(new GlossaryEntry(columns[0], columns[1]));
        }
        return result;
    }

    /// <summary>The fields of a CSV line: split at commas outside quotes, "" inside quotes being a quote.</summary>
    public static List<string> CsvFields(string line)
    {
        var fields = new List<string>();
        var field = new StringBuilder();
        bool quoted = false;
        for (int i = 0; i < line.Length; i++)
        {
            char c = line[i];
            if (c == '"')
            {
                if (quoted && i + 1 < line.Length && line[i + 1] == '"') { field.Append('"'); i++; }
                else quoted = !quoted;
            }
            else if (c == ',' && !quoted) { fields.Add(field.ToString().Trim()); field.Clear(); }
            else field.Append(c);
        }
        fields.Add(field.ToString().Trim());
        return fields;
    }
}

sealed class RefusalCount(int limit)
{
    int _refused;
    public int Count => Volatile.Read(ref _refused);
    /// <summary>Counts one more; false once there are more than the limit.</summary>
    public bool Add() => Interlocked.Increment(ref _refused) <= limit;
}

/// <summary>Holds every request of a job back after the service said it gets too many.</summary>
sealed class RateGate
{
    DateTime _until = DateTime.MinValue;
    readonly object _lock = new();

    public Task Pause(double seconds)
    {
        lock (_lock) { var until = DateTime.UtcNow.AddSeconds(seconds); if (until > _until) _until = until; }
        return Task.CompletedTask;
    }

    public async Task Wait(CancellationToken cancel)
    {
        while (true)
        {
            TimeSpan left;
            lock (_lock) left = _until - DateTime.UtcNow;
            if (left <= TimeSpan.Zero) return;
            await Task.Delay(left, cancel);
        }
    }
}

sealed class GlossaryBox(List<GlossaryEntry> entries)
{
    readonly List<GlossaryEntry> _stored = [.. entries];
    volatile bool _complete;
    public List<GlossaryEntry> Entries { get { lock (_stored) return [.. _stored]; } }

    /// <summary>The paper's terms are in (or could not be had).</summary>
    public bool IsComplete => _complete;
    public void MarkComplete() => _complete = true;

    /// <summary>Returns once the paper's terms are in, at the deadline at the latest (or when the job is cancelled).</summary>
    public async Task Wait(DateTime deadline, CancellationToken cancel)
    {
        while (!_complete && DateTime.UtcNow < deadline && !cancel.IsCancellationRequested)
        {
            try { await Task.Delay(100, cancel); } catch (OperationCanceledException) { return; }
        }
    }

    public void Add(List<GlossaryEntry> terms)
    {
        lock (_stored)
        {
            var known = _stored.Select(e => e.Source.ToLowerInvariant()).ToHashSet();
            _stored.AddRange(terms.Where(t => !known.Contains(t.Source.ToLowerInvariant())));
        }
    }
}

/// <summary>Reports progress that only goes forward, in steps not small enough to flood whoever is listening.</summary>
sealed class MonotonicProgress(Action<TranslationEvent> emit)
{
    double _last;
    readonly object _lock = new();

    public void Report(double value)
    {
        double? next = null;
        lock (_lock)
        {
            double clamped = Math.Min(Math.Max(value, _last), 1);
            if (clamped - _last >= 0.0005 || (clamped >= 1 && _last < 1)) { _last = clamped; next = clamped; }
        }
        if (next is { } n) emit(new TranslationEvent.Progress(n));
    }
}

sealed class ProgressTarget(Func<double> value)
{
    Func<double> _current = value;
    public void Set(Func<double> value) => Volatile.Write(ref _current, value);
    public double Value() => Volatile.Read(ref _current)();
}

/// <summary>How far the translation has come: what is done, plus how far the requests under way should be by now.</summary>
sealed class ProgressEstimate(int done, int total, ProviderLimits limits, double replyPerCharacter = 0.6, Func<DateTime>? clock = null)
{
    sealed class Running(double characters, DateTime started)
    {
        public readonly double Characters = characters;
        public readonly DateTime Started = started;
        public double Received;
    }
    readonly object _lock = new();
    readonly Dictionary<int, Running> _running = [];
    readonly Func<DateTime> _clock = clock ?? (() => DateTime.UtcNow);
    int _nextId;
    double _done = done;
    readonly double _total = Math.Max(total, 1);
    readonly double _startup = limits.StartupSeconds;
    double _secondsPerCharacter = limits.SecondsPerCharacter;
    bool _measured;
    // Characters of reply for each character sent, as replies come in.
    double _replyPerCharacter = replyPerCharacter;
    bool _measuredReply;
    // Replies of this job arrive piece by piece.
    bool _streams;
    double _highest;

    public int Begin(int characters)
    {
        lock (_lock) { _running[++_nextId] = new Running(characters, _clock()); return _nextId; }
    }

    /// <summary>So much of the reply to a request has arrived (it may start over: a part asked for again).</summary>
    public void Received(int id, int characters)
    {
        if (characters <= 0) return;
        lock (_lock)
        {
            _streams = true;
            if (_running.TryGetValue(id, out var request)) request.Received = Math.Max(request.Received, characters);
        }
    }

    public void Finish(int id)
    {
        lock (_lock)
        {
            if (!_running.Remove(id, out var request)) return;
            _done += request.Characters;
            double rate = Math.Max((_clock() - request.Started).TotalSeconds - _startup, 0.05) / Math.Max(request.Characters, 1);
            _secondsPerCharacter = _measured ? (_secondsPerCharacter + rate) / 2 : rate;
            _measured = true;
            if (request.Received > 0 && request.Characters > 0)
            {
                double reply = request.Received / request.Characters;
                _replyPerCharacter = _measuredReply ? (_replyPerCharacter + reply) / 2 : reply;
                _measuredReply = true;
            }
        }
    }

    public void Abandon(int id) { lock (_lock) _running.Remove(id); }

    public double Fraction()
    {
        lock (_lock)
        {
            var now = _clock();
            double sum = _done;
            foreach (var r in _running.Values)
            {
                double expected = _startup + r.Characters * _secondsPerCharacter;
                double byTime = Share((now - r.Started).TotalSeconds / expected);
                // While nothing of a streamed reply has come, time only says that the request is under way.
                double share = _streams ? Math.Min(byTime, 0.15) : byTime;
                if (r.Received > 0) share = Math.Max(share, Math.Min(r.Received / Math.Max(r.Characters * _replyPerCharacter, 1), 0.97));
                sum += r.Characters * share;
            }
            _highest = Math.Max(_highest, Math.Min(sum / _total, 1));
            return _highest;
        }
    }

    /// <summary>How much of a request to count after x times its expected time: steadily up to nine tenths, then ever
    /// more slowly, so a slow one keeps moving without being counted as done.</summary>
    public static double Share(double x) => x <= 1 ? 0.9 * Math.Max(x, 0) : 0.9 + 0.09 * (1 - 1 / (1 + (x - 1) / 1.5));
}

/// <summary>Translations so far, shared by the concurrent batches.</summary>
sealed class TranslationState
{
    readonly object _lock = new();
    readonly Dictionary<string, string> _translations = [];
    readonly int _totalCharacters;
    int _doneCharacters;
    readonly Dictionary<int, int> _remainingByPage;

    public TranslationState(List<TextSegment> segments)
    {
        _totalCharacters = Math.Max(1, segments.Sum(s => s.Source.Length));
        _remainingByPage = segments.GroupBy(s => s.Page).ToDictionary(g => g.Key, g => g.Count());
    }

    public void Store(string text, TextSegment segment)
    {
        lock (_lock)
        {
            if (!_translations.TryAdd(segment.Id, text)) return;
            _doneCharacters += segment.Source.Length;
            _remainingByPage[segment.Page] = _remainingByPage.GetValueOrDefault(segment.Page, 1) - 1;
        }
    }

    public string? Translation(TextSegment segment) { lock (_lock) return _translations.GetValueOrDefault(segment.Id); }
    public Dictionary<string, string> Snapshot() { lock (_lock) return new(_translations); }
    public int DoneCount { get { lock (_lock) return _translations.Count; } }
    public (int Done, int Total) Characters { get { lock (_lock) return (_doneCharacters, _totalCharacters); } }
    public HashSet<int> CompletedPages { get { lock (_lock) return _remainingByPage.Where(kv => kv.Value <= 0).Select(kv => kv.Key).ToHashSet(); } }
}

/// <summary>Writes preview PDFs while the translation runs: when more pages are done, at most every few seconds, one at a time.</summary>
sealed class PreviewWriter(TranslationRenderer renderer, List<PageLayout> layouts, List<TextSegment> segments, string directory, Action<TranslationEvent> emit)
{
    readonly object _lock = new();
    int _shownPages;
    DateTime _lastWrite = DateTime.MinValue;
    Task? _running;
    int _counter;
    readonly CancellationTokenSource _stop = new();
    readonly int _pages = segments.Select(s => s.Page).Distinct().Count();

    public void Update(Dictionary<string, string> translations, HashSet<int> pagesDone)
    {
        lock (_lock)
        {
            if (pagesDone.Count <= _shownPages || _running != null || (DateTime.UtcNow - _lastWrite).TotalSeconds <= 3 || pagesDone.Count >= _pages) return;
            _shownPages = pagesDone.Count;
            _lastWrite = DateTime.UtcNow;
            _counter++;
            var path = Path.Combine(directory, $"preview-{_counter}.pdf");
            var previous = _counter > 2 ? Path.Combine(directory, $"preview-{_counter - 2}.pdf") : null;
            _running = Task.Run(() =>
            {
                try
                {
                    var output = renderer.Render(layouts, segments, translations, true, false, TranslationOptions.DualLayouts.sideBySide, null);
                    Directory.CreateDirectory(directory);
                    if (output.Mono != null && !_stop.IsCancellationRequested)
                    {
                        File.WriteAllBytes(path, output.Mono);
                        if (!_stop.IsCancellationRequested) emit(new TranslationEvent.Preview(path));
                    }
                    if (previous != null) try { File.Delete(previous); } catch { }
                }
                catch { }
                finally { lock (_lock) _running = null; }
            });
        }
    }

    public async Task Finish()
    {
        Task? task;
        lock (_lock) task = _running;
        _stop.Cancel();
        if (task != null) await task;
    }
}

/// <summary>Earlier translations of the same text, per document and translator, kept on disk.</summary>
sealed class TranslationCache
{
    readonly string _path;
    readonly bool _ignore;
    readonly Dictionary<string, string> _entries = [];
    int _dirty;
    readonly object _lock = new();

    public TranslationCache(string directory, string document, string signature, bool ignore)
    {
        _ignore = ignore;
        using var hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        hasher.AppendData(Encoding.UTF8.GetBytes(signature));
        long size = 0;
        try
        {
            using var stream = File.OpenRead(document);
            size = stream.Length;
            var buffer = new byte[Math.Min(1 << 20, size)];
            int read = stream.ReadAtLeast(buffer, buffer.Length, false);
            hasher.AppendData(buffer, 0, read);
        }
        catch { }
        hasher.AppendData(Encoding.UTF8.GetBytes(size.ToString()));
        var key = Convert.ToHexStringLower(hasher.GetHashAndReset()[..12]);
        _path = Path.Combine(directory, key + ".json");
        try { _entries = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(_path)) ?? []; } catch { }
        Prune(directory);
    }

    static string Key(string text) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text))[..16]);

    public string? Lookup(string source)
    {
        if (_ignore) return null;
        // An empty entry (kept by earlier versions when a service gave nothing back) is no translation.
        lock (_lock) return _entries.GetValueOrDefault(Key(source)) is { Length: > 0 } hit ? hit : null;
    }

    public void Store(string text, string source)
    {
        if (text.Length == 0) return;
        lock (_lock) { _entries[Key(source)] = text; _dirty++; }
    }

    public void SaveIfNeeded()
    {
        bool due;
        lock (_lock) due = _dirty >= 20;
        if (due) Save();
    }

    public void Save()
    {
        string json;
        lock (_lock) { _dirty = 0; json = JsonSerializer.Serialize(_entries); }
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            var temp = _path + ".tmp";
            File.WriteAllText(temp, json);
            File.Move(temp, _path, true);
        }
        catch { }
    }

    /// <summary>Caches unused for 60 days go.</summary>
    static void Prune(string directory)
    {
        try
        {
            var limit = DateTime.UtcNow.AddDays(-60);
            foreach (var file in Directory.EnumerateFiles(directory))
                if (File.GetLastWriteTimeUtc(file) < limit) File.Delete(file);
        }
        catch { }
    }
}

/// <summary>The job's log: what was sent, how long it took, what failed (never keys).</summary>
sealed class TranslationLog
{
    readonly string _path;
    readonly object _lock = new();

    public TranslationLog(string path)
    {
        _path = path;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, "");
        }
        catch { }
    }

    public void Write(string line)
    {
        lock (_lock)
        {
            try { File.AppendAllText(_path, $"{DateTime.Now:HH:mm:ss.fff} {line}\n"); } catch { }
        }
    }
}

/// <summary>What goes wrong while a job works, shown at once (the same thing not more than every 20 seconds), and when a
/// request last came back (or failed): a minute without either, and the progress says what it waits for.</summary>
sealed class JobActivity
{
    readonly object _lock = new();
    Action<TranslationEvent>? _emit;
    readonly Dictionary<string, DateTime> _shown = [];
    DateTime _last = DateTime.UtcNow;

    public void Attach(Action<TranslationEvent> emit) { lock (_lock) { _emit = emit; _last = DateTime.UtcNow; } }

    public void Touch() { lock (_lock) _last = DateTime.UtcNow; }

    public double IdleSeconds { get { lock (_lock) return (DateTime.UtcNow - _last).TotalSeconds; } }

    /// <summary>Shows message, unless the same thing (key) was shown in the last 20 seconds.</summary>
    public void Report(string message, string? key = null)
    {
        key ??= message;
        Action<TranslationEvent>? send;
        lock (_lock)
        {
            if (_shown.TryGetValue(key, out var at) && (DateTime.UtcNow - at).TotalSeconds < 20) return;
            _shown[key] = DateTime.UtcNow;
            send = _emit;
        }
        send?.Invoke(new TranslationEvent.Problem(message));
    }
}
