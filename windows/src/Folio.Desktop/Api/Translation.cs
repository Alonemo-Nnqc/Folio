using System.Text.Json;
using Folio.Core;
using Folio.Core.Translate;
using Folio.Core.Translate.Services;

namespace Folio.App;

public static partial class Api
{
    static HashSet<string>? _installedAgents;
    static DateTime _agentsCheckedAt;
    static bool _checkingAgents;

    /// <summary>Looks for installed agents again (not more than every few seconds): one installed while Folio runs must not stay
    /// missing until a restart. Finding agents may ask each for its --help: off the interface thread, then the lists are sorted again.</summary>
    static void RefreshAgents()
    {
        if (!_checkingAgents && (_installedAgents == null || DateTime.UtcNow - _agentsCheckedAt > TimeSpan.FromSeconds(5)))
        {
            // Finding agents may ask each for its --help: off the interface thread, then the list is sorted again.
            _installedAgents ??= [];
            _checkingAgents = true;
            Task.Run(() => LocalAgents.Installed().Select(a => a.ServiceId()).ToHashSet()).ContinueWith(t => App.Ui.TryEnqueue(() =>
            {
                _checkingAgents = false;
                _agentsCheckedAt = DateTime.UtcNow;
                if (!t.IsCompletedSuccessfully || t.Result.SetEquals(_installedAgents)) return;
                _installedAgents = t.Result;
                App.Broadcast("translation.servicesChanged", null);
            })).Fire();
        }
    }

    static object JobsState() => M.Translations.ActiveItemIds.ToDictionary(id => id, id =>
    {
        var job = M.Translations.JobOf(id)!;
        return new { fileId = job.FileId, fraction = job.Fraction, stage = job.Stage, preview = job.Preview };
    });

    static HashSet<string> Configured(HashSet<string> agents)
    {
        var settings = M.Settings;
        var store = M.Translations.Secrets;
        var all = settings.TranslationFields;
        var profiles = settings.TranslationProfiles;
        var result = new HashSet<string>(agents);
        foreach (var service in TranslationServiceCatalog.All)
        {
            if (service.Backend is TranslationBackend.Agent) continue;
            var fields = all.GetValueOrDefault(service.Id) ?? [];
            bool hasFields = service.Fields.Any(f => !f.IsSecret && f.Kind != FieldKind.Toggle && !string.IsNullOrEmpty(fields.GetValueOrDefault(f.Option)));
            bool hasKey = service.SecretFields.Any(f => !string.IsNullOrEmpty(store.Get(service.Id, f.Option)));
            bool hasProfiles = profiles.Any(p => p.ServiceId == service.Id);
            if (hasKey || hasProfiles || (hasFields && service.Category != ServiceCategory.Free)) result.Add(service.Id);
        }
        return result;
    }

    /// <summary>The service menu, in the macOS app's groups.</summary>
    static object ServiceGroups()
    {
        var configured = Configured(_installedAgents ?? []);
        var profiles = M.Settings.TranslationProfiles;
        var all = TranslationServiceCatalog.All;
        var rest = all.Where(s => !configured.Contains(s.Id)).ToList();
        object Entry(TranslationService s)
        {
            var names = profiles.Where(p => p.ServiceId == s.Id).Select(p => p.Name).ToList();
            var label = configured.Contains(s.Id) && names.Count > 0 ? s.DisplayName + " · " + Loc.JoinList(names.Take(3)) + (names.Count > 3 ? "…" : "") : s.DisplayName;
            return new { id = s.Id, label };
        }
        return new (string Title, List<TranslationService> Services)[]
        {
            (Loc.S("我的服务"), all.Where(s => configured.Contains(s.Id)).ToList()),
            (Loc.S("免费"), rest.Where(s => s.Category == ServiceCategory.Free).ToList()),
            // Agents not found on this computer are left out; the one in use stays so the menu can show it.
            (Loc.S("本机"), rest.Where(s => s.Category == ServiceCategory.Local || (s.Category == ServiceCategory.Agent && s.Id == M.Settings.TranslationService)).ToList()),
            (Loc.S("大模型 API"), rest.Where(s => s.Category == ServiceCategory.Llm).ToList()),
            (Loc.S("机器翻译 API"), rest.Where(s => s.Category == ServiceCategory.Machine).ToList()),
        }.Where(g => g.Services.Count > 0).Select(g => new { title = g.Title, services = g.Services.Select(Entry) });
    }

    static object ServiceDetail(string serviceId)
    {
        var service = TranslationServiceCatalog.Resolve(serviceId);
        var values = M.Settings.FieldsOf(service.Id);
        var store = M.Translations.Secrets;
        var settings = M.Settings;
        object? reasoning = ReasoningEffort.GetSupport(service.Id, values) switch
        {
            ReasoningEffort.Support.Choices c => new
            {
                kind = "choices", title = service.Backend is TranslationBackend.Agent ? Loc.S("思考强度") : Loc.S("推理强度"), current = ReasoningEffort.Current(service.Id, values) ?? c.Default,
                choices = c.List.Select(x => new { value = x.Value, title = x.Value == c.Default && x.Value.Length > 0 ? Loc.S("%@（推荐）", x.Title) : x.Title }),
            },
            ReasoningEffort.Support.DecidedByModel d => new { kind = "decided", note = Loc.S("思考强度：%@（由所选模型决定）", d.Title) },
            _ => null,
        };
        object Field(TranslationServiceField f) => new
        {
            option = f.Option, title = f.IsRequired ? f.Title : Loc.S("%@（选填）", f.Title), kind = f.Kind.ToString().ToLowerInvariant(), placeholder = f.Placeholder ?? f.DefaultValue ?? (f.IsSecret ? Loc.S("未填写") : ""),
            value = f.IsSecret ? store.Get(service.Id, f.Option) ?? "" : values.GetValueOrDefault(f.Option) ?? "",
            models = ModelListFetcher.Supports(service.Id, f.Option), remembered = ModelListFetcher.Supports(service.Id, f.Option) ? ModelListFetcher.RememberedModels(service.Id, values) : null,
        };
        var profiles = settings.TranslationProfiles.Where(p => p.ServiceId == service.Id).Select(p => new { id = p.Id, name = p.Name }).ToList();
        return new
        {
            id = service.Id, name = service.DisplayName, note = service.Note, category = service.Category.ToString().ToLowerInvariant(), isAgent = service.Backend is TranslationBackend.Agent,
            supportsProfiles = TranslationProfiles.SupportsProfiles(service), profiles, selectedProfile = settings.SelectedTranslationProfiles.GetValueOrDefault(service.Id),
            fields = service.Fields.Where(f => !f.IsAdvanced).Select(Field),
            advanced = service.Fields.Where(f => f.IsAdvanced && !ReasoningEffort.ManagedOptions.Contains(f.Option)).Select(Field),
            reasoning,
        };
    }

    /// <summary>Stores a field and keeps the configuration in use in step.</summary>
    static void SetField(string serviceId, string option, string value)
    {
        var fields = M.Settings.FieldsOf(serviceId);
        if (value.Length == 0) fields.Remove(option); else fields[option] = value;
        M.Settings.SetFields(serviceId, fields);
        if (M.Settings.SelectedTranslationProfiles.GetValueOrDefault(serviceId) is { } id)
        {
            var profiles = M.Settings.TranslationProfiles;
            if (profiles.FirstOrDefault(p => p.Id == id) is { } profile)
            {
                profile.Fields = fields.Where(kv => kv.Value.Length > 0).ToDictionary(kv => kv.Key, kv => kv.Value);
                M.Settings.TranslationProfiles = profiles;
            }
        }
    }

    /// <summary>Services 划词翻译 can use without further setup: set up, free, or agents found on this computer.</summary>
    static List<TranslationService> ReadyServices()
    {
        var configured = Configured(_installedAgents ?? []);
        return TranslationServiceCatalog.All.Where(s => s.Category == ServiceCategory.Free || configured.Contains(s.Id)).ToList();
    }

    static string LanguageName(string code) =>
        TranslationOptions.CommonLanguages.FirstOrDefault(l => string.Equals(l.Code, code, StringComparison.OrdinalIgnoreCase)).Name ?? code;

    static void InstallTranslation()
    {
        Bridge.On("translation.selectionServices", _ =>
        {
            RefreshAgents();
            var current = M.Settings.SelectionTranslationService is { Length: > 0 } chosen ? TranslationServiceCatalog.Resolve(chosen).Id : M.Settings.TranslationService;
            // The one in use is listed even while agents are still being looked for.
            var ready = ReadyServices();
            if (!ready.Any(s => s.Id == current)) ready.Insert(0, TranslationServiceCatalog.Resolve(current));
            return new
            {
                current, fullText = M.Settings.TranslationService,
                services = ready.Select(s => new { id = s.Id, name = s.DisplayName }),
                from = LanguageName(M.Settings.TranslationOptions.LangIn), to = LanguageName(M.Settings.TranslationOptions.LangOut),
            };
        });
        Bridge.OnAsync("translation.selection", async a =>
        {
            var chosen = a.OptStr("service") is { Length: > 0 } explicitly ? explicitly
                : M.Settings.SelectionTranslationService is { Length: > 0 } stored ? stored : M.Settings.TranslationService;
            var service = TranslationServiceCatalog.Resolve(chosen);
            var options = M.Settings.TranslationOptions;
            var outcome = await SelectionTranslator.Translate(a.Str("text"), service.Id, M.Settings.FieldsOf(service.Id), M.Translations.Secrets.Secrets(service),
                                                              options.LangIn, options.LangOut, M.Settings.SelectionTranslationFallback, id => M.Settings.FieldsOf(id));
            string Name(string id) => TranslationServiceCatalog.Service(id)?.DisplayName ?? id;
            return (object?)new
            {
                ok = outcome.Succeeded, text = outcome.Text, service = outcome.ServiceId, serviceName = Name(outcome.ServiceId),
                notice = outcome.FellBackFrom is { } limited ? Loc.S("%@ 暂时限流，已改用 %@", Name(limited), Name(outcome.ServiceId)) : null,
            };
        });
        Bridge.On("translation.setSelectionService", a =>
        {
            var id = a.Str("id");
            M.Settings.SelectionTranslationService = id == M.Settings.TranslationService ? "" : id;
            return null;
        });
        Bridge.On("translation.services", _ =>
        {
            RefreshAgents();
            return new { groups = ServiceGroups(), current = M.Settings.TranslationService, options = M.Settings.TranslationOptions, languages = TranslationOptions.CommonLanguages.Select(l => new { code = l.Code, name = l.Name }), detail = ServiceDetail(M.Settings.TranslationService) };
        });
        Bridge.On("translation.setService", a => { M.Settings.TranslationService = a.Str("id"); return ServiceDetail(a.Str("id")); });
        Bridge.On("translation.setField", a => { SetField(a.Str("service"), a.Str("option"), a.Str("value").Trim()); return ServiceDetail(a.Str("service")); });
        Bridge.On("translation.setSecret", a =>
        {
            var service = a.Str("service");
            var option = a.Str("option");
            var value = a.Str("value");
            var store = M.Translations.Secrets;
            store.Set(value, service, option);
            // The configuration in use keeps the same key.
            if (M.Settings.SelectedTranslationProfiles.GetValueOrDefault(service) is { } id && M.Settings.TranslationProfiles.FirstOrDefault(p => p.Id == id) is { } profile)
                TranslationProfiles.RecordSecret(value, option, profile, store);
            return null;
        });
        Bridge.On("translation.setReasoning", a =>
        {
            var service = a.Str("service");
            var fields = M.Settings.FieldsOf(service);
            ReasoningEffort.Set(a.Str("value"), service, fields);
            M.Settings.SetFields(service, fields);
            return ServiceDetail(service);
        });
        Bridge.OnAsync("translation.fetchModels", async a =>
        {
            var service = TranslationServiceCatalog.Resolve(a.Str("service"));
            return (object?)await ModelListFetcher.Fetch(service.Id, M.Settings.FieldsOf(service.Id), M.Translations.Secrets.Secrets(service));
        });
        Bridge.OnAsync("translation.status", async a =>
        {
            var service = TranslationServiceCatalog.Resolve(a.Str("service"));
            if (service.Backend is not TranslationBackend.Agent agent) return (object?)null;
            var pathOption = service.Fields.FirstOrDefault(f => f.Option.EndsWith("-path"))?.Option;
            var path = pathOption != null ? M.Settings.FieldsOf(service.Id).GetValueOrDefault(pathOption) : null;
            var which = agent.Which;
            return await Task.Run<object?>(() =>
            {
                var found = which.Locate(path);
                var version = found != null ? which.Version(found) : null;
                return found == null
                    ? new { ok = false, message = Loc.S("没有在这台电脑上找到 %@，请先安装并登录", which.Command()) }
                    : new { ok = true, message = version != null ? Loc.S("已找到 %@（%@）", found, version) : Loc.S("已找到 %@", found) };
            });
        });
        Bridge.OnAsync("translation.test", async a =>
        {
            var service = TranslationServiceCatalog.Resolve(a.Str("service"));
            var outcome = await TranslationServiceTest.Run(service.Id, M.Settings.FieldsOf(service.Id), M.Translations.Secrets.Secrets(service), M.Settings.TranslationOptions.LangOut);
            return (object?)new { ok = outcome.Succeeded, message = outcome.Message };
        });
        Bridge.On("translation.setOptions", a =>
        {
            M.Settings.TranslationOptions = a.Raw("options").Deserialize<TranslationOptions>() ?? new TranslationOptions();
            return null;
        });
        Bridge.On("translation.pickGlossary", _ =>
        {
            if (Pickers.OpenFiles("CSV|*.csv", false).FirstOrDefault() is not { } path) return null;
            var options = M.Settings.TranslationOptions;
            options.GlossaryFile = path;
            M.Settings.TranslationOptions = options;
            return path;
        });
        Bridge.On("translation.revealLogs", _ =>
        {
            Directory.CreateDirectory(TranslationCoordinator.LogsDirectory);
            Shell.OpenPath(TranslationCoordinator.LogsDirectory);
            return null;
        });

        // Configurations.
        Bridge.On("translation.selectProfile", a =>
        {
            var serviceId = a.Str("service");
            var service = TranslationServiceCatalog.Resolve(serviceId);
            var selected = M.Settings.SelectedTranslationProfiles;
            if (a.OptStr("profile") is { Length: > 0 } id && M.Settings.TranslationProfiles.FirstOrDefault(p => p.Id == id) is { } profile)
            {
                M.Settings.SetFields(serviceId, TranslationProfiles.Apply(profile, service, M.Translations.Secrets));
                selected[serviceId] = profile.Id;
            }
            else selected.Remove(serviceId);
            M.Settings.SelectedTranslationProfiles = selected;
            return ServiceDetail(serviceId);
        });
        Bridge.On("translation.suggestProfileName", a =>
        {
            var service = TranslationServiceCatalog.Resolve(a.Str("service"));
            return TranslationProfiles.SuggestedName(service, M.Settings.FieldsOf(service.Id), M.Settings.TranslationProfiles);
        });
        Bridge.On("translation.saveProfile", a =>
        {
            var service = TranslationServiceCatalog.Resolve(a.Str("service"));
            var profile = TranslationProfiles.Capture(a.Str("name").Trim(), service, M.Settings.FieldsOf(service.Id), M.Translations.Secrets);
            var all = M.Settings.TranslationProfiles;
            all.Add(profile);
            M.Settings.TranslationProfiles = all;
            var selected = M.Settings.SelectedTranslationProfiles;
            selected[service.Id] = profile.Id;
            M.Settings.SelectedTranslationProfiles = selected;
            return ServiceDetail(service.Id);
        });
        Bridge.On("translation.deleteProfile", a =>
        {
            var service = TranslationServiceCatalog.Resolve(a.Str("service"));
            if (M.Settings.TranslationProfiles.FirstOrDefault(p => p.Id == a.Str("profile")) is { } profile)
            {
                TranslationProfiles.DeleteSecrets(profile, service, M.Translations.Secrets);
                M.Settings.TranslationProfiles = M.Settings.TranslationProfiles.Where(p => p.Id != profile.Id).ToList();
                var selected = M.Settings.SelectedTranslationProfiles;
                selected.Remove(service.Id);
                M.Settings.SelectedTranslationProfiles = selected;
            }
            return ServiceDetail(service.Id);
        });

        // Jobs.
        Bridge.OnAsync("translation.start", async a =>
        {
            foreach (var id in a.Strs("files")) await M.Translations.Start(id);
        });
        Bridge.On("translation.cancel", a => { M.Translations.Cancel(a.Str("item")); return null; });
    }
}
