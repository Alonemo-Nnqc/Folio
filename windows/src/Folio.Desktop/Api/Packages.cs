using Folio.Core;
using Folio.Core.Translate;
using Microsoft.VisualBasic.FileIO;

namespace Folio.App;

/// <summary>打包导出 and 导入 Folio 包: the library and the settings in one file, for another computer.</summary>
public static partial class Api
{
    static CancellationTokenSource? _packing;

    static void InstallPackages()
    {
        Bridge.On("package.counts", _ =>
        {
            var items = M.Snapshot.Items.Values.Where(i => !i.IsTrashed).Select(i => i.Id).ToHashSet();
            var files = M.Snapshot.Files.Values.Where(f => items.Contains(f.ItemId)).ToList();
            return new { items = items.Count, files = files.Count, bytes = files.Sum(f => f.Size) };
        });
        Bridge.OnAsync("package.export", async a =>
        {
            bool withLibrary = a.Bool("library");
            var name = (withLibrary ? "Folio" : Loc.S("Folio 设置")) + $" {DateTime.Now:yyyy-MM-dd}.{LibraryPackageInfo.Extension}";
            if (Pickers.SaveFile(name, $"{Loc.S("Folio 文献库包")}|*.{LibraryPackageInfo.Extension}") is not { } path) return (object?)null;
            var library = M.Library;
            var password = a.OptStr("password");
            using var cancel = _packing = new CancellationTokenSource();
            var window = a.Window;
            try
            {
                // Documents being written save a moment after typing stops.
                await Task.Delay(800);
                var summary = await Task.Run(() =>
                {
                    var settings = a.Bool("settings") ? SettingsPackage.Data(M.Settings, M.Translations.Secrets, GlossaryStore.Shared, password) : null;
                    return library.ExportPackage(path, Updater.CurrentVersion, withLibrary, settings, Progress(window), cancel.Token);
                });
                return new { path, fileName = Path.GetFileName(path), missing = summary.MissingFiles };
            }
            catch (OperationCanceledException) { return new { cancelled = true }; }
            finally { _packing = null; }
        });
        Bridge.On("package.cancel", _ => { _packing?.Cancel(); return null; });
        Bridge.On("package.pick", _ => Pickers.OpenFiles($"{Loc.S("Folio 文献库包")}|*.{LibraryPackageInfo.Extension}", multiple: false).FirstOrDefault());
        Bridge.OnAsync("package.read", async a =>
        {
            var path = a.Str("path");
            var (package, settings) = await Task.Run(() =>
            {
                var found = new LibraryPackage(path);
                // Settings that cannot be read do not keep the library from being imported.
                SettingsPackage? readable = null;
                try { if (found.Settings is { } data) readable = new SettingsPackage(data); } catch (LibraryException) when (found.HasLibrary) { }
                return (found, readable);
            });
            return (object?)new
            {
                path, fileName = Path.GetFileName(path), app = package.Info.App, exported = Ms(package.Info.Date), hasLibrary = package.HasLibrary,
                items = package.Info.Items, files = package.Info.Files, groups = package.Info.Groups, tags = package.Info.Tags,
                hasSettings = settings != null, hasKeys = settings?.HasSecrets == true,
            };
        });
        Bridge.OnAsync("package.import", async a =>
        {
            var package = new LibraryPackage(a.Str("path"));
            var settings = a.Bool("settings") && package.Settings is { } data ? new SettingsPackage(data) : null;
            Dictionary<string, string>? keys = null;
            if (settings is { HasSecrets: true } && a.OptStr("password") is { Length: > 0 } password)
            {
                keys = await Task.Run(() => settings.Secrets(password));
                if (keys == null) return (object?)new { wrongPassword = true };
            }
            using var cancel = _packing = new CancellationTokenSource();
            var window = a.Window;
            LibraryImportSummary? summary = null;
            try
            {
                if (a.Bool("library") && package.HasLibrary)
                {
                    // Papers and documents that are open may be replaced: they are closed, what is in them is written.
                    M.CloseDocuments();
                    await Task.Delay(800);
                    var library = M.Library;
                    summary = await Task.Run(() => library.ImportPackage(package, Recycle, Progress(window), cancel.Token));
                }
            }
            catch (OperationCanceledException) { return new { cancelled = true }; }
            finally
            {
                _packing = null;
                M.Importer.IndexFulltext();
            }
            settings?.Apply(M.Settings, M.Translations.Secrets, GlossaryStore.Shared, keys);
            return new { library = summary, settings = settings != null };
        });
    }

    static Action<int, int> Progress(HostWindow? window)
    {
        long last = 0;
        return (done, all) =>
        {
            // Not more often than it can be seen.
            if (done < all && Environment.TickCount64 - last < 50) return;
            last = Environment.TickCount64;
            window?.Bridge.Emit("package.progress", new { done, all });
        };
    }

    static void Recycle(string path) => FileSystem.DeleteFile(path, UIOption.OnlyErrorDialogs, RecycleOption.SendToRecycleBin, UICancelOption.ThrowException);

    /// <summary>A package opened from Explorer or dropped on the window.</summary>
    public static void OpenPackage(string path)
    {
        App.Main?.BringForward();
        App.Main?.Bridge.Emit("package.open", path);
    }

    /// <summary>What is to be added to the library; a package is not, it is imported.</summary>
    static List<string> WithoutPackages(List<string> paths)
    {
        var packages = paths.Where(p => Path.GetExtension(p).Equals("." + LibraryPackageInfo.Extension, StringComparison.OrdinalIgnoreCase)).ToList();
        if (packages.Count > 0) OpenPackage(packages[0]);
        return paths.Except(packages).ToList();
    }
}
