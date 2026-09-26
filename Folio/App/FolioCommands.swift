import SwiftUI

/// Menu bar commands (UI-07).
struct FolioCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("添加文件…") { model.chooseFilesToImport() }
                .keyboardShortcut("o")
            Button("通过标识符添加…") { model.activeSheet = .identifierAdd }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("新建分组") { model.createGroup() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("从 Zotero 导入…") { model.activeSheet = .zoteroImport }
            Button("导出 BibTeX…") { model.exportBibTeX() }
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("删除") { model.deleteSelection(command: true) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.selectionCount == 0)
        }
        CommandGroup(after: .sidebar) {
            Button("搜索文献") { model.showSearch() }
                .keyboardShortcut("f")
            Button(model.showInspector ? "隐藏检查器" : "显示检查器") { model.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            Button("按自定义顺序排列") { model.setSort(.manual) }
                .disabled(model.currentSort == .manual)
        }
    }
}
