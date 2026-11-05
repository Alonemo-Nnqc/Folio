using Folio.Core;
using Folio.Core.Translate;
using Folio.Core.Translate.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Storage.Pickers;

namespace Folio.App;

// The macOS TranslateSheet, TranslationSettingsPane, TranslationProfileRow and TranslationProgressViews.

/// <summary>"翻译…": confirm service, languages and outputs for this run (they become the new defaults).</summary>
static class TranslationSheet
{
    public static async Task Show(AppModel model, List<FileRecord> files)
    {
        if (files.Count == 1)
        {
            await model.Translations.Request(files[0]);
            return;
        }
        var waiting = files.Where(f => model.Translations.JobOf(f.ItemId) == null).ToList();
        if (waiting.Count == 0) return;
        if (await Ask(model, waiting[0], waiting.Count))
            foreach (var file in waiting) await model.Translations.Start(file.Id);
    }

    public static async Task<bool> Ask(AppModel model, FileRecord file, int count = 1)
    {
        var title = model.Snapshot.Items.TryGetValue(file.ItemId, out var item) ? item.Title : file.FileName;
        var content = new StackPanel { Spacing = 4, Width = 480 };
        content.Children.Add(new TextBlock
        {
            Text = count > 1 ? Loc.S("%lld 篇文献", count) : title, TextWrapping = TextWrapping.Wrap, MaxLines = 2,
            Foreground = UI.Brush("FolioSecondaryTextBrush"), Margin = new Thickness(0, 0, 0, 8),
        });
        content.Children.Add(TranslationSettings.ServiceSection(model, compact: true));
        content.Children.Add(TranslationSettings.OptionsSection(model, compact: true));
        content.Children.Add(SettingsWindow.Note(Loc.S("保留原文排版、公式和图表，翻译时就可以对照阅读\n译文会作为新文件加入该条目")));
        var dialog = new ContentDialog
        {
            Title = Loc.S("翻译全文"),
            Content = new ScrollViewer { Content = content, MaxHeight = 560, Padding = new Thickness(0, 0, 12, 0) },
            PrimaryButtonText = Loc.S("开始翻译"),
            CloseButtonText = Loc.S("取消"),
            DefaultButton = ContentDialogButton.Primary,
        };
        return await Dialogs.Custom(dialog) == ContentDialogResult.Primary;
    }
}

/// <summary>设置 ▸ 翻译: the service, the default options and the engine.</summary>
static class TranslationSettings
{
    public static UIElement Page(AppModel model)
    {
        var page = new StackPanel { Spacing = 6, MaxWidth = 640, HorizontalAlignment = HorizontalAlignment.Left };
        page.Children.Add(SettingsWindow.Header(Loc.S("翻译服务")));
        page.Children.Add(ServiceSection(model, compact: false));
        page.Children.Add(OptionsSection(model, compact: false));
        page.Children.Add(SettingsWindow.Header(Loc.S("翻译引擎")));
        var logs = new Button { Content = Loc.S("在资源管理器中显示") };
        logs.Click += (_, _) =>
        {
            Directory.CreateDirectory(TranslationCoordinator.LogsDirectory);
            Shell.Open(TranslationCoordinator.LogsDirectory);
        };
        page.Children.Add(Labeled(Loc.S("翻译日志"), logs));
        page.Children.Add(SettingsWindow.Note(Loc.S("Folio 内置的翻译引擎直接解析 PDF 版面并按原样排入译文，图表内文字和公式保持原样，无需下载任何组件")));
        return page;
    }

    static FrameworkElement Labeled(string title, FrameworkElement control)
    {
        var grid = new Grid { ColumnSpacing = 12, Margin = new Thickness(0, 4, 0, 4) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var label = new TextBlock { Text = title, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap };
        grid.Children.Add(label);
        Grid.SetColumn(control, 1);
        control.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(control);
        return grid;
    }

    // MARK: Service

    /// <summary>Services set up before (a key, an address, saved configurations) and agents found on this computer.</summary>
    static HashSet<string> Configured(AppModel model, HashSet<string> agents)
    {
        var settings = model.Settings;
        var store = model.Translations.Secrets;
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

    static List<(string Title, List<TranslationService> Services)> Groups(HashSet<string> configured)
    {
        var all = TranslationServiceCatalog.All;
        var rest = all.Where(s => !configured.Contains(s.Id)).ToList();
        return new List<(string, List<TranslationService>)>
        {
            (Loc.S("我的服务"), all.Where(s => configured.Contains(s.Id)).ToList()),
            (Loc.S("免费"), rest.Where(s => s.Category == ServiceCategory.Free).ToList()),
            (Loc.S("本机"), rest.Where(s => s.Category == ServiceCategory.Local).ToList()),
            (Loc.S("本机智能体（这台电脑上未找到）"), rest.Where(s => s.Category == ServiceCategory.Agent).ToList()),
            (Loc.S("大模型 API"), rest.Where(s => s.Category == ServiceCategory.Llm).ToList()),
            (Loc.S("机器翻译 API"), rest.Where(s => s.Category == ServiceCategory.Machine).ToList()),
        }.Where(g => g.Item2.Count > 0).ToList();
    }

    static HashSet<string>? _installedAgents;

    /// <summary>The service picker and the fields the chosen service needs. Secrets go to the encrypted secret store.</summary>
    public static FrameworkElement ServiceSection(AppModel model, bool compact)
    {
        var root = new StackPanel { Spacing = 6 };
        var picker = new ComboBox { Header = Loc.S("翻译服务"), MinWidth = 320 };
        var note = SettingsWindow.Note("");
        var body = new StackPanel { Spacing = 6 };
        root.Children.Add(picker);
        root.Children.Add(note);
        root.Children.Add(body);
        bool filling = false;

        void FillPicker()
        {
            filling = true;
            picker.Items.Clear();
            var configured = Configured(model, _installedAgents ?? []);
            var profiles = model.Settings.TranslationProfiles;
            int selected = -1;
            foreach (var (title, services) in Groups(configured))
            {
                picker.Items.Add(new ComboBoxItem { Content = title, IsEnabled = false, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, FontSize = 12 });
                foreach (var service in services)
                {
                    var names = profiles.Where(p => p.ServiceId == service.Id).Select(p => p.Name).ToList();
                    var label = configured.Contains(service.Id) && names.Count > 0
                        ? service.DisplayName + " · " + string.Join("、", names.Take(3)) + (names.Count > 3 ? "…" : "") : service.DisplayName;
                    picker.Items.Add(new ComboBoxItem { Content = label, Tag = service.Id, Padding = new Thickness(20, 6, 8, 6) });
                    if (service.Id == model.Settings.TranslationService) selected = picker.Items.Count - 1;
                }
            }
            picker.SelectedIndex = selected;
            filling = false;
        }

        void Rebuild()
        {
            body.Children.Clear();
            var service = TranslationServiceCatalog.Resolve(model.Settings.TranslationService);
            note.Text = service.Note ?? "";
            note.Visibility = string.IsNullOrEmpty(service.Note) ? Visibility.Collapsed : Visibility.Visible;
            if (TranslationProfiles.SupportsProfiles(service)) body.Children.Add(ProfileRow(model, service, () => { FillPicker(); Rebuild(); }));
            foreach (var field in service.Fields.Where(f => !f.IsAdvanced)) body.Children.Add(FieldRow(model, service, field));
            if (ReasoningRow(model, service) is { } reasoning) body.Children.Add(reasoning);
            if (service.Backend is TranslationBackend.Agent || (!compact && service.Category != ServiceCategory.Free))
                body.Children.Add(StatusRow(model, service, canTest: !compact));
            var advanced = service.Fields.Where(f => f.IsAdvanced && !ReasoningEffort.ManagedOptions.Contains(f.Option)).ToList();
            if (!compact && advanced.Count > 0)
            {
                var panel = new StackPanel { Spacing = 6 };
                foreach (var field in advanced) panel.Children.Add(FieldRow(model, service, field));
                body.Children.Add(new Expander
                {
                    Header = Loc.S("高级"), Content = panel, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
                });
            }
        }

        picker.SelectionChanged += (_, _) =>
        {
            if (filling || picker.SelectedItem is not ComboBoxItem { Tag: string id } || id == model.Settings.TranslationService) return;
            model.Settings.TranslationService = id;
            Rebuild();
        };
        FillPicker();
        Rebuild();
        if (_installedAgents == null)
        {
            // Finding agents may ask each for its --help: off the UI thread, then the list is sorted again.
            _ = Task.Run(() => LocalAgents.Installed().Select(a => a.ServiceId()).ToHashSet()).ContinueWith(t =>
            {
                if (t.IsCompletedSuccessfully) model.RunOnUi(() => { _installedAgents = t.Result; FillPicker(); });
            });
        }
        return root;
    }

    static Dictionary<string, string> Fields(AppModel model, string serviceId) => model.Settings.FieldsOf(serviceId);

    /// <summary>Stores a field and keeps the configuration in use in step.</summary>
    static void SetField(AppModel model, string serviceId, string option, string value)
    {
        var fields = Fields(model, serviceId);
        if (value.Length == 0) fields.Remove(option); else fields[option] = value;
        model.Settings.SetFields(serviceId, fields);
        if (model.Settings.SelectedTranslationProfiles.GetValueOrDefault(serviceId) is { } id)
        {
            var profiles = model.Settings.TranslationProfiles;
            if (profiles.FirstOrDefault(p => p.Id == id) is { } profile)
            {
                profile.Fields = fields.Where(kv => kv.Value.Length > 0).ToDictionary(kv => kv.Key, kv => kv.Value);
                model.Settings.TranslationProfiles = profiles;
            }
        }
    }

    static FrameworkElement FieldRow(AppModel model, TranslationService service, TranslationServiceField field)
    {
        var title = field.IsRequired ? field.Title : Loc.S("%@（选填）", field.Title);
        var value = Fields(model, service.Id).GetValueOrDefault(field.Option) ?? "";
        switch (field.Kind)
        {
            case FieldKind.Secret:
            {
                var stored = model.Translations.Secrets.Get(service.Id, field.Option) ?? "";
                var box = new PasswordBox { Header = title, Password = stored, PlaceholderText = field.Placeholder ?? Loc.S("未填写"), MinWidth = 320 };
                box.PasswordChanged += (_, _) =>
                {
                    if (box.Password == stored) return;
                    stored = box.Password;
                    var store = model.Translations.Secrets;
                    store.Set(stored, service.Id, field.Option);
                    // The configuration in use keeps the same key.
                    if (model.Settings.SelectedTranslationProfiles.GetValueOrDefault(service.Id) is { } id
                        && model.Settings.TranslationProfiles.FirstOrDefault(p => p.Id == id) is { } profile)
                        TranslationProfiles.RecordSecret(stored, field.Option, profile, store);
                };
                return box;
            }
            case FieldKind.Toggle:
                return SettingsWindow.Toggle(title, value == "true", on => SetField(model, service.Id, field.Option, on ? "true" : ""));
            default:
                if (ModelListFetcher.Supports(service.Id, field.Option)) return ModelPicker(model, service, field, title, value);
                var text = new TextBox { Header = title, Text = value, PlaceholderText = field.Placeholder ?? field.DefaultValue ?? "", MinWidth = 320 };
                text.LostFocus += (_, _) => SetField(model, service.Id, field.Option, text.Text.Trim());
                return text;
        }
    }

    /// <summary>The model: typed, or picked from the list the service offers (fetched with the key and address above).</summary>
    static FrameworkElement ModelPicker(AppModel model, TranslationService service, TranslationServiceField field, string title, string value)
    {
        var box = new ComboBox
        {
            Header = title, IsEditable = true, Text = value, PlaceholderText = field.DefaultValue ?? field.Placeholder ?? Loc.S("默认"), MinWidth = 320,
        };
        var status = new TextBlock { FontSize = 12, Foreground = UI.Brush("FolioSecondaryTextBrush"), TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
        bool loading = false;
        void Commit(string text)
        {
            text = text.Trim();
            if (text != (Fields(model, service.Id).GetValueOrDefault(field.Option) ?? "")) SetField(model, service.Id, field.Option, text);
        }
        if (ModelListFetcher.RememberedModels(service.Id, Fields(model, service.Id)) is { } remembered)
            foreach (var m in remembered) box.Items.Add(m);
        box.DropDownOpened += async (_, _) =>
        {
            if (loading) return;
            loading = true;
            status.Text = Loc.S("正在获取模型列表…");
            status.Visibility = Visibility.Visible;
            try
            {
                var models = await ModelListFetcher.Fetch(service.Id, Fields(model, service.Id), model.Translations.Secrets.Secrets(service));
                var typed = box.Text;
                box.Items.Clear();
                foreach (var m in models) box.Items.Add(m);
                box.Text = typed;
                status.Visibility = Visibility.Collapsed;
            }
            catch (Exception e)
            {
                status.Text = e.Message;
            }
            finally { loading = false; }
        };
        box.SelectionChanged += (_, _) => { if (box.SelectedItem is string m) Commit(m); };
        box.TextSubmitted += (_, e) => Commit(e.Text);
        box.LostFocus += (_, _) => Commit(box.Text);
        var panel = new StackPanel { Spacing = 2 };
        panel.Children.Add(box);
        panel.Children.Add(status);
        return panel;
    }

    static FrameworkElement? ReasoningRow(AppModel model, TranslationService service)
    {
        var fields = Fields(model, service.Id);
        switch (ReasoningEffort.GetSupport(service.Id, fields))
        {
            case ReasoningEffort.Support.Choices choices:
            {
                var current = ReasoningEffort.Current(service.Id, fields) ?? choices.Default;
                return SettingsWindow.Choice(service.Backend is TranslationBackend.Agent ? Loc.S("思考强度") : Loc.S("推理强度"),
                    choices.List.Select(c => (c.Value, c.Value == choices.Default && c.Value.Length > 0 ? Loc.S("%@（推荐）", c.Title) : c.Title)), current, value =>
                    {
                        var all = Fields(model, service.Id);
                        ReasoningEffort.Set(value, service.Id, all);
                        model.Settings.SetFields(service.Id, all);
                    });
            }
            case ReasoningEffort.Support.DecidedByModel decided:
                return SettingsWindow.Note(Loc.S("思考强度：%@（由所选模型决定）", decided.Title));
            default:
                return null;
        }
    }

    /// <summary>Where the service stands: the agent found and its version, and what a test with one sentence says.</summary>
    static FrameworkElement StatusRow(AppModel model, TranslationService service, bool canTest)
    {
        var grid = new Grid { ColumnSpacing = 12, Margin = new Thickness(0, 4, 0, 4) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var icon = new ContentPresenter { VerticalAlignment = VerticalAlignment.Center };
        var text = new TextBlock { TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 460 };
        line.Children.Add(icon);
        line.Children.Add(text);
        grid.Children.Add(line);
        void Show(string message, string? glyph, string? color, bool busy = false)
        {
            text.Text = message;
            icon.Content = busy ? new ProgressRing { Width = 14, Height = 14, IsActive = true }
                : glyph != null ? UI.Icon(glyph, 14, color != null ? UI.Hex(color) : null) : null;
        }
        var agent = (service.Backend as TranslationBackend.Agent)?.Which;
        if (agent is { } which)
        {
            Show("", null, null, busy: true);
            var pathOption = service.Fields.FirstOrDefault(f => f.Option.EndsWith("-path"))?.Option;
            var path = pathOption != null ? Fields(model, service.Id).GetValueOrDefault(pathOption) : null;
            _ = Task.Run(() =>
            {
                var found = which.Locate(path);
                var version = found != null ? which.Version(found) : null;
                model.RunOnUi(() =>
                {
                    if (found == null) Show(Loc.S("没有在这台电脑上找到 %@，请先安装并登录", which.Command()), "warning", "#FF9500");
                    else Show(version != null ? Loc.S("已找到 %@（%@）", found, version) : Loc.S("已找到 %@", found), "checkmark", "#34C759");
                });
            });
        }
        else Show(Loc.S("翻译一句话，确认这个服务能用"), null, null);
        if (canTest)
        {
            var test = new Button { Content = Loc.S("测试") };
            test.Click += async (_, _) =>
            {
                test.IsEnabled = false;
                test.Content = Loc.S("测试中…");
                Show(Loc.S("正在翻译一句话…"), null, null, busy: true);
                var outcome = await TranslationServiceTest.Run(service.Id, Fields(model, service.Id), model.Translations.Secrets.Secrets(service),
                                                               model.Settings.TranslationOptions.LangOut);
                Show(outcome.Message, outcome.Succeeded ? "checkmark" : "warning", outcome.Succeeded ? "#34C759" : "#FF9500");
                test.IsEnabled = true;
                test.Content = Loc.S("测试");
            };
            Grid.SetColumn(test, 1);
            test.VerticalAlignment = VerticalAlignment.Center;
            grid.Children.Add(test);
        }
        return grid;
    }

    /// <summary>Saved configurations of the service: pick one to use it, save the current values as one, delete one.</summary>
    static FrameworkElement ProfileRow(AppModel model, TranslationService service, Action changed)
    {
        var settings = model.Settings;
        var profiles = settings.TranslationProfiles.Where(p => p.ServiceId == service.Id).ToList();
        var selectedId = settings.SelectedTranslationProfiles.GetValueOrDefault(service.Id);
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var box = new ComboBox { Header = Loc.S("配置"), MinWidth = 220 };
        box.Items.Add(Loc.S("未保存为配置"));
        foreach (var p in profiles) box.Items.Add(p.Name);
        box.SelectedIndex = selectedId != null && profiles.FindIndex(p => p.Id == selectedId) is >= 0 and var k ? k + 1 : 0;
        box.SelectionChanged += (_, _) =>
        {
            var selected = settings.SelectedTranslationProfiles;
            if (box.SelectedIndex <= 0) selected.Remove(service.Id);
            else
            {
                var profile = profiles[box.SelectedIndex - 1];
                settings.SetFields(service.Id, TranslationProfiles.Apply(profile, service, model.Translations.Secrets));
                selected[service.Id] = profile.Id;
            }
            settings.SelectedTranslationProfiles = selected;
            changed();
        };
        row.Children.Add(box);
        var save = new Button { Content = Loc.S("存为配置…"), VerticalAlignment = VerticalAlignment.Bottom };
        save.Click += async (_, _) =>
        {
            var all = settings.TranslationProfiles;
            var suggested = TranslationProfiles.SuggestedName(service, Fields(model, service.Id), all);
            var name = await Dialogs.Ask(Loc.S("保存为配置"), Loc.S("配置名称"), suggested, Loc.S("保存"));
            if (string.IsNullOrWhiteSpace(name)) return;
            var profile = TranslationProfiles.Capture(name.Trim(), service, Fields(model, service.Id), model.Translations.Secrets);
            all.Add(profile);
            settings.TranslationProfiles = all;
            var selected = settings.SelectedTranslationProfiles;
            selected[service.Id] = profile.Id;
            settings.SelectedTranslationProfiles = selected;
            changed();
        };
        row.Children.Add(save);
        if (box.SelectedIndex > 0)
        {
            var delete = new Button { Content = Loc.S("删除"), VerticalAlignment = VerticalAlignment.Bottom };
            delete.Click += async (_, _) =>
            {
                var profile = profiles[box.SelectedIndex - 1];
                if (!await Dialogs.Confirm(Loc.S("删除配置“%@”？", profile.Name), Loc.S("会删除这个配置保存的地址、模型和 Key。"), Loc.S("删除"), Loc.S("取消"), destructive: true)) return;
                TranslationProfiles.DeleteSecrets(profile, service, model.Translations.Secrets);
                settings.TranslationProfiles = settings.TranslationProfiles.Where(p => p.Id != profile.Id).ToList();
                var selected = settings.SelectedTranslationProfiles;
                selected.Remove(service.Id);
                settings.SelectedTranslationProfiles = selected;
                changed();
            };
            row.Children.Add(delete);
        }
        return row;
    }

    // MARK: Options

    public static FrameworkElement OptionsSection(AppModel model, bool compact)
    {
        var settings = model.Settings;
        var panel = new StackPanel { Spacing = 6 };
        void Update(Action<TranslationOptions> change)
        {
            var options = settings.TranslationOptions;
            change(options);
            settings.TranslationOptions = options;
        }
        var o = settings.TranslationOptions;
        var languages = TranslationOptions.CommonLanguages.Select(l => (l.Code, l.Name)).ToList();
        if (!compact) panel.Children.Add(SettingsWindow.Header(Loc.S("语言")));
        else panel.Children.Add(SettingsWindow.Header(Loc.S("选项")));
        var languageRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        var from = SettingsWindow.Choice(Loc.S("原文语言"), languages, o.LangIn, v => Update(x => x.LangIn = v));
        var to = SettingsWindow.Choice(Loc.S("译文语言"), languages, o.LangOut, v => Update(x => x.LangOut = v));
        from.MinWidth = to.MinWidth = 180;
        languageRow.Children.Add(from);
        languageRow.Children.Add(to);
        panel.Children.Add(languageRow);

        if (!compact) panel.Children.Add(SettingsWindow.Header(Loc.S("输出")));
        FrameworkElement? layout = null;
        panel.Children.Add(SettingsWindow.Choice(Loc.S("生成"), new[]
        {
            (TranslationOptions.OutputKinds.both, Loc.S("纯译文和双语对照")), (TranslationOptions.OutputKinds.mono, Loc.S("仅纯译文")), (TranslationOptions.OutputKinds.dual, Loc.S("仅双语对照")),
        }, o.Outputs, v =>
        {
            Update(x => x.Outputs = v);
            if (layout != null) layout.Visibility = v == TranslationOptions.OutputKinds.mono ? Visibility.Collapsed : Visibility.Visible;
        }));
        layout = SettingsWindow.Choice(Loc.S("双语排版"), new[]
        {
            (TranslationOptions.DualLayouts.sideBySide, Loc.S("原文与译文左右并排")), (TranslationOptions.DualLayouts.alternatingPages, Loc.S("原文页与译文页交替")),
        }, o.DualLayout, v => Update(x => x.DualLayout = v));
        layout.Visibility = o.Outputs == TranslationOptions.OutputKinds.mono ? Visibility.Collapsed : Visibility.Visible;
        panel.Children.Add(layout);
        if (!compact)
        {
            panel.Children.Add(SettingsWindow.Choice(Loc.S("再次翻译"), new[]
            {
                (TranslationOptions.DuplicateHandling.keepBoth, Loc.S("保留两者")), (TranslationOptions.DuplicateHandling.replace, Loc.S("替换旧的译文")),
            }, o.Duplicates, v => Update(x => x.Duplicates = v)));
            panel.Children.Add(SettingsWindow.Note(Loc.S("同一服务和模型再翻译一次时；保留两者时按翻译时间区分，替换的旧译文会移到回收站")));
        }
        panel.Children.Add(SettingsWindow.Field(Loc.S("页码范围（选填）"), o.Pages ?? "", v => Update(x => x.Pages = v.Length == 0 ? null : v), Loc.S("全部，例如 1-3,5")));

        if (!compact) panel.Children.Add(SettingsWindow.Header(Loc.S("翻译内容")));
        panel.Children.Add(SettingsWindow.Toggle(Loc.S("翻译表格"), o.TranslateTables, v => Update(x => x.TranslateTables = v)));
        if (compact) return panel;
        panel.Children.Add(SettingsWindow.Note(Loc.S("逐格翻译表格中的文字；数字和符号保持原样")));
        panel.Children.Add(SettingsWindow.Toggle(Loc.S("翻译参考文献"), o.TranslateReferences, v => Update(x => x.TranslateReferences = v)));
        panel.Children.Add(SettingsWindow.Note(Loc.S("默认保留参考文献列表的原文")));
        var glossary = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var glossaryName = new TextBlock { Text = o.GlossaryFile != null ? System.IO.Path.GetFileName(o.GlossaryFile) : Loc.S("未选择"), VerticalAlignment = VerticalAlignment.Center, Foreground = UI.Brush("FolioSecondaryTextBrush") };
        var choose = new Button { Content = Loc.S("选择…") };
        var clear = new Button { Content = Loc.S("清除"), Visibility = o.GlossaryFile != null ? Visibility.Visible : Visibility.Collapsed };
        choose.Click += async (_, _) =>
        {
            var picker = new FileOpenPicker();
            picker.FileTypeFilter.Add(".csv");
            if (App.Current?.Window is { } window) WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(SettingsWindow.Current ?? (Window)window));
            if (await picker.PickSingleFileAsync() is not { } file) return;
            Update(x => x.GlossaryFile = file.Path);
            glossaryName.Text = file.Name;
            clear.Visibility = Visibility.Visible;
        };
        clear.Click += (_, _) =>
        {
            Update(x => x.GlossaryFile = null);
            glossaryName.Text = Loc.S("未选择");
            clear.Visibility = Visibility.Collapsed;
        };
        glossary.Children.Add(glossaryName);
        glossary.Children.Add(clear);
        glossary.Children.Add(choose);
        panel.Children.Add(Labeled(Loc.S("术语表（选填）"), glossary));
        panel.Children.Add(SettingsWindow.Note(Loc.S("CSV 文件，两列：原文, 译文")));

        panel.Children.Add(SettingsWindow.Header(Loc.S("速度")));
        panel.Children.Add(SettingsWindow.Choice(Loc.S("同时请求数"), new[] { 0, 1, 2, 4, 8, 12, 16 }.Select(n => (n, n == 0 ? Loc.S("自动") : n.ToString())),
            o.Concurrency ?? 0, v => Update(x => x.Concurrency = v == 0 ? null : v)));
        panel.Children.Add(SettingsWindow.Note(Loc.S("付费接口额度较高时调大可以更快；遇到限流时调小")));
        panel.Children.Add(SettingsWindow.Toggle(Loc.S("重新翻译（不使用缓存）"), o.IgnoreCache, v => Update(x => x.IgnoreCache = v)));
        panel.Children.Add(SettingsWindow.Note(Loc.S("默认会复用同一篇论文用同一服务翻译过的段落，重试时更快、更省")));
        return panel;
    }
}

/// <summary>A translation's progress in a list row: the stage, a bar that only fills, and the percentage.</summary>
sealed class TranslationProgressView : StackPanel
{
    readonly AppModel _model;
    readonly string _itemId;
    readonly TextBlock _stage = new() { FontSize = 11, Foreground = UI.Brush("FolioSecondaryTextBrush"), VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 150 };
    readonly TextBlock _percent = new() { FontSize = 11, Foreground = UI.Brush("FolioSecondaryTextBrush"), VerticalAlignment = VerticalAlignment.Center, Width = 32, TextAlignment = TextAlignment.Right };
    readonly Rectangle _fill = new() { Height = 4, RadiusX = 2, RadiusY = 2, HorizontalAlignment = HorizontalAlignment.Left };
    const double BarWidth = 72;

    public TranslationProgressView(AppModel model, string itemId)
    {
        _model = model;
        _itemId = itemId;
        Orientation = Orientation.Horizontal;
        Spacing = 6;
        VerticalAlignment = VerticalAlignment.Center;
        _fill.Fill = UI.Brush("FolioAccentBrush");
        var track = new Grid { Width = BarWidth, Height = 4, VerticalAlignment = VerticalAlignment.Center, CornerRadius = new CornerRadius(2), Background = UI.Brush("FolioSeparatorBrush") };
        track.Children.Add(_fill);
        Children.Add(UI.Icon("translate", 12, UI.Brush("FolioSecondaryTextBrush")));
        Children.Add(_stage);
        Children.Add(track);
        Children.Add(_percent);
        var cancel = UI.IconButton("close", Loc.S("取消翻译"), (_, _) => _model.Translations.Cancel(_itemId), 10);
        Children.Add(cancel);
        Update(itemId);
        Loaded += (_, _) => _model.Translations.ProgressChanged += Update;
        Unloaded += (_, _) => _model.Translations.ProgressChanged -= Update;
    }

    void Update(string itemId)
    {
        if (itemId != _itemId || _model.Translations.JobOf(_itemId) is not { } job) return;
        _stage.Text = job.Stage;
        double fraction = Math.Clamp(job.Fraction ?? 0, 0, 1);
        _fill.Width = BarWidth * fraction;
        _percent.Text = $"{Math.Round(fraction * 100)}%";
        ToolTipService.SetToolTip(this, Loc.S("翻译：%@", job.Stage));
    }
}
