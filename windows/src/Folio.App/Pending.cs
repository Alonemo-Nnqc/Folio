using Folio.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Folio.App;

// Placeholders replaced as the remaining macOS modules are ported (translation engine, AI integration, Zotero import).

static class ZoteroImportSheet
{
    public static Task Show(AppModel model)
    {
        model.Toasts.Show(Loc.S("Zotero 导入正在移植中"), "library");
        return Task.CompletedTask;
    }
}
