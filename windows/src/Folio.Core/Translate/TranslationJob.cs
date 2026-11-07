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
    public static EngineError AlreadyInTarget(string language) => new(Loc.S("这篇论文已经是%@，不需要翻译成%@。可以在翻译设置里换一种译文语言。", language, language));
    public static EngineError TooManyRefused(int count) => new(Loc.S("翻译服务拒绝翻译 %lld 个段落（内容审核）。请换一个翻译服务或模型再试。", count));
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
        log.Write($"translate {Path.GetFileName(Request.Input)} with {Request.ServiceId} {options.LangIn}→{options.LangOut}");
        var provider = ProviderFactory.Make(Request.ServiceId, Request.FieldValues, Request.Secrets, options.Concurrency);

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
        var selected = options.PageNumbers(pageCount);
        var analyzer = new LayoutAnalyzer(new LayoutAnalyzer.Options { TranslateTables = options.TranslateTables, TranslateReferences = options.TranslateReferences });
        var analysed = analyzer.Analyze(source, selected);
        cancel.ThrowIfCancellationRequested();
        var output = options.OnlyIncludeTranslatedPages || options.Pages == null ? selected : Enumerable.Range(1, pageCount).ToList();
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
        var context = new TranslationContext(options.LangIn, options.LangOut, segments.FirstOrDefault(s => s.Kind == BlockKind.Title)?.Source, Summary(segments),
                                             ReadGlossary(options.GlossaryFile));
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
                    log.Write($"glossary: {glossary.Entries.Count} terms");
                }
                catch (Exception e) { log.Write($"term extraction failed, continuing without: {e.Message}"); }
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
            var renderer = new TranslationRenderer(source, options.LangOut);
            var previews = new PreviewWriter(renderer, layouts, segments, Request.OutputDirectory, emit);

            // What is left to send: whole paragraphs, the continued ones as one text each.
            var units = new List<TextSegment>();
            var sent = new HashSet<string>();
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
                units.Add(segment);
            }
            var refusals = new RefusalCount(Math.Max(5, segments.Count / 20));
            var batches = Batches(units, provider.Limits);
            int total = segments.Count;
            var (doneChars, totalChars) = state.Characters;
            var estimate = new ProgressEstimate(doneChars, totalChars, provider.Limits);
            var target = new ProgressTarget(() => 0.08 + 0.86 * estimate.Fraction());
            using var tickerStop = new CancellationTokenSource();
            bool layingOut = false;
            var ticker = Task.Run(async () =>
            {
                double shown = target.Value();
                int lastCount = -1;
                while (!tickerStop.IsCancellationRequested)
                {
                    double goal = target.Value();
                    shown = Math.Min(goal, shown + Math.Max(0.001, (goal - shown) * 0.2));
                    reported.Report(shown);
                    if (shown <= 0.94 && !Volatile.Read(ref layingOut))
                    {
                        int count = Math.Max(state.DoneCount, Math.Min(total - 1, (int)(total * (shown - 0.08) / 0.86)));
                        if (count != lastCount)
                        {
                            lastCount = count;
                            emit(new TranslationEvent.Stage(TranslationStageText.Paragraphs(count, total)));
                        }
                    }
                    try { await Task.Delay(200, tickerStop.Token); } catch (OperationCanceledException) { }
                }
            });
            try
            {
                async Task RunBatch(List<TextSegment> batch)
                {
                    var batchContext = context with { Glossary = glossary.Entries };
                    var texts = await TranslateBatch(batch, provider, batchContext, log, estimate, refusals, cancel);
                    for (int i = 0; i < batch.Count; i++)
                    {
                        var segment = batch[i];
                        var raw = texts[i];
                        if (raw == null)
                        {
                            // Refused by the service's content review: the original stays, and is not cached.
                            foreach (var part in joinedParts.TryGetValue(segment.Id, out var refused) ? refused.Parts : [segment]) state.Store(part.Source, part);
                            continue;
                        }
                        if (joinedParts.TryGetValue(segment.Id, out var continuation))
                        {
                            if (Continuations.Split(raw, continuation) is { } pieces)
                            {
                                for (int k = 0; k < continuation.Parts.Count; k++) state.Store(pieces[k], continuation.Parts[k]);
                                cache.Store(raw, segment.Source);
                            }
                            else
                            {
                                // The translator moved a formula across the break: the parts go on their own.
                                log.Write($"continued paragraph p{segment.Page} not splittable, translating its parts apart");
                                var apart = await TranslateBatch(continuation.Parts, provider, batchContext, log, estimate, refusals, cancel);
                                for (int k = 0; k < continuation.Parts.Count; k++)
                                {
                                    state.Store(apart[k] ?? continuation.Parts[k].Source, continuation.Parts[k]);
                                    if (apart[k] is { } text) cache.Store(text, continuation.Parts[k].Source);
                                }
                            }
                            continue;
                        }
                        var translated = segment.Kind == BlockKind.Heading ? HeadingNumbers.RestoreSpace(segment.Source, raw) : raw;
                        state.Store(translated, segment);
                        cache.Store(translated, segment.Source);
                    }
                }
                var pending = new Queue<List<TextSegment>>(batches);
                var running = new List<Task>();
                void StartNext()
                {
                    if (pending.Count > 0) running.Add(RunBatch(pending.Dequeue()));
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

    public static List<List<TextSegment>> Batches(List<TextSegment> segments, ProviderLimits limits)
    {
        var result = new List<List<TextSegment>>();
        var current = new List<TextSegment>();
        int characters = 0;
        foreach (var segment in segments)
        {
            int length = segment.Source.Length;
            if (current.Count > 0 && (characters + length > limits.BatchCharacters || current.Count >= limits.BatchItems))
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
        bool refused = false;
        for (int attempt = 0; attempt < 6; attempt++)
        {
            cancel.ThrowIfCancellationRequested();
            await _rateGate.Wait(cancel);
            int characters = batch.Sum(s => s.Source.Length);
            int request = estimate.Begin(characters);
            try
            {
                var watch = Stopwatch.StartNew();
                var texts = (await provider.Translate(items, context, cancel)).Select(Clean).ToList();
                log.Write(string.Create(CultureInfo.InvariantCulture, $"batch of {batch.Count} ({characters} chars) in {watch.Elapsed.TotalSeconds:F1} s"));
                estimate.Finish(request);
                var broken = Enumerable.Range(0, batch.Count).Where(i => !PlaceholdersIntact(texts[i], batch[i].Source)).ToList();
                if (broken.Count > 0 && provider.Limits.UsesContext)
                {
                    log.Write($"placeholders lost in {broken.Count} of {batch.Count}, asking again");
                    try
                    {
                        var again = (await provider.Translate(broken.Select(i => items[i]).ToList(), context, cancel)).Select(Clean).ToList();
                        for (int k = 0; k < broken.Count && k < again.Count; k++)
                        {
                            int i = broken[k];
                            if (PlaceholderErrors(again[k], batch[i].Source) < PlaceholderErrors(texts[i], batch[i].Source)) texts[i] = again[k];
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
                if (!e.IsRetryable) throw;
                double wait = e.RetryAfter ?? Math.Min(30, Math.Pow(2, attempt) * 1.5);
                if (e.Kind == ProviderError.Kinds.Http && e.Status == 429) await _rateGate.Pause(wait);
                else await Task.Delay(TimeSpan.FromSeconds(wait), cancel);
                // An unreadable reply for a big batch: try smaller ones.
                if (e.Kind == ProviderError.Kinds.InvalidResponse && batch.Count > 1 && attempt >= 1) break;
            }
        }
        if (batch.Count > 1)
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
            if (excerpt.Length + part.Length < 7000) excerpt.Append(Placeholders.Replace(part, _ => "…")).Append('\n');
        return excerpt.ToString();
    }

    /// <summary>A CSV glossary: source,target per line (more columns are ignored).</summary>
    public static List<GlossaryEntry> ReadGlossary(string? path)
    {
        if (string.IsNullOrEmpty(path) || !File.Exists(path)) return [];
        var result = new List<GlossaryEntry>();
        foreach (var line in File.ReadAllLines(path))
        {
            var columns = line.Split(',', 3).Select(c => c.Trim(' ', '"', '\t')).ToList();
            if (columns.Count < 2 || columns[0].Length == 0 || columns[1].Length == 0 || columns[0].ToLowerInvariant() == "source") continue;
            result.Add(new GlossaryEntry(columns[0], columns[1]));
        }
        return result;
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
    public List<GlossaryEntry> Entries { get { lock (_stored) return [.. _stored]; } }

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
sealed class ProgressEstimate(int done, int total, ProviderLimits limits)
{
    sealed record Running(double Characters, DateTime Started);
    readonly object _lock = new();
    readonly Dictionary<int, Running> _running = [];
    int _nextId;
    double _done = done;
    readonly double _total = Math.Max(total, 1);
    readonly double _startup = limits.StartupSeconds;
    double _secondsPerCharacter = limits.SecondsPerCharacter;
    bool _measured;
    double _highest;

    public int Begin(int characters)
    {
        lock (_lock) { _running[++_nextId] = new Running(characters, DateTime.UtcNow); return _nextId; }
    }

    public void Finish(int id)
    {
        lock (_lock)
        {
            if (!_running.Remove(id, out var request)) return;
            _done += request.Characters;
            double rate = Math.Max((DateTime.UtcNow - request.Started).TotalSeconds - _startup, 0.05) / Math.Max(request.Characters, 1);
            _secondsPerCharacter = _measured ? (_secondsPerCharacter + rate) / 2 : rate;
            _measured = true;
        }
    }

    public void Abandon(int id) { lock (_lock) _running.Remove(id); }

    public double Fraction()
    {
        lock (_lock)
        {
            var now = DateTime.UtcNow;
            double sum = _done;
            foreach (var r in _running.Values)
            {
                double expected = _startup + r.Characters * _secondsPerCharacter;
                sum += r.Characters * Share((now - r.Started).TotalSeconds / expected);
            }
            _highest = Math.Max(_highest, Math.Min(sum / _total, 1));
            return _highest;
        }
    }

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
        lock (_lock) return _entries.GetValueOrDefault(Key(source));
    }

    public void Store(string text, string source)
    {
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
