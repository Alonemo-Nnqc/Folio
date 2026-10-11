import AppKit
import FolioCore

/// The menu bar (UI-08). Every item has target nil, so it reaches whichever window controller is in
/// the responder chain — the library window or a reader tab — and is validated there.
enum MainMenu {
    /// Builds dynamic submenus ("添加到", "标签") from the front window's current items.
    private static let itemSubmenus = ItemSubmenuProvider()

    static func install() {
        let main = NSMenu()
        main.addItem(submenu("Folio", appMenu()))
        main.addItem(submenu("文件", fileMenu()))
        main.addItem(submenu("编辑", editMenu()))
        main.addItem(submenu("条目", itemMenu()))
        main.addItem(submenu("显示", viewMenu()))
        for (title, menu) in ReaderMenus.menus() { main.addItem(submenu(title, menu)) }
        let window = windowMenu()
        main.addItem(submenu("窗口", window))
        let help = NSMenu(title: "帮助")
        help.addItem(item("在 Finder 中显示文献库", #selector(AppDelegate.revealLibraryInFinder(_:))))
        main.addItem(submenu("帮助", help))
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
        NSApp.helpMenu = help
    }

    // MARK: Menus

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Folio")
        menu.addItem(item("关于 Folio", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("设置…", #selector(AppDelegate.showSettings(_:)), ","))
        menu.addItem(.separator())
        let services = NSMenu(title: "服务")
        menu.addItem(submenu("服务", services))
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        menu.addItem(item("隐藏 Folio", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("全部显示", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("退出 Folio", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "文件")
        menu.addItem(item("添加文件…", #selector(LibraryWindowController.addFiles(_:)), "o"))
        menu.addItem(item("通过标识符添加…", #selector(LibraryWindowController.addByIdentifier(_:)), "o", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("新建分组", #selector(LibraryWindowController.newGroup(_:)), "n", [.command, .shift]))
        menu.addItem(item("新建子分组", #selector(LibraryWindowController.newSubgroup(_:))))
        menu.addItem(item("新建标签…", #selector(LibraryWindowController.newTag(_:))))
        menu.addItem(.separator())
        menu.addItem(item("关闭", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(.separator())
        menu.addItem(item("从 Zotero 导入…", #selector(LibraryWindowController.importFromZotero(_:))))
        menu.addItem(item("导出 BibTeX…", #selector(FolioWindowController.exportBibTeX(_:)), "e", [.command, .shift]))
        menu.addItem(item("导出笔记…", #selector(FolioWindowController.exportNote(_:))))
        menu.addItem(.separator())
        menu.addItem(item("打印…", #selector(ReaderWindowController.printDocument(_:)), "p"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "编辑")
        menu.addItem(item("撤销", Selector(("undo:")), "z"))
        menu.addItem(item("重做", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("剪切", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("拷贝", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("粘贴", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("删除", #selector(NSText.delete(_:))))
        menu.addItem(item("全选", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())
        menu.addItem(item("移到回收站", #selector(LibraryWindowController.moveToTrash(_:)), "\u{8}"))
        menu.addItem(item("从当前分组移除", #selector(LibraryWindowController.removeFromGroup(_:))))
        menu.addItem(item("恢复", #selector(LibraryWindowController.restoreFromTrash(_:))))
        menu.addItem(item("彻底删除…", #selector(LibraryWindowController.deletePermanently(_:))))
        menu.addItem(item("清空回收站…", #selector(LibraryWindowController.emptyTrash(_:))))
        menu.addItem(.separator())
        let cite = NSMenu(title: "拷贝引用")
        for (index, style) in CitationStyleOption.allCases.enumerated() {
            let entry = item(style.title, #selector(FolioWindowController.copyCitation(_:)),
                             index == 0 ? "c" : "", [.command, .shift])
            entry.tag = index
            cite.addItem(entry)
        }
        menu.addItem(submenu("拷贝引用", cite))
        menu.addItem(.separator())
        let find = NSMenu(title: "查找")
        find.addItem(item("查找…", #selector(LibraryWindowController.focusSearch(_:)), "f"))
        find.addItem(item("查找下一个", #selector(ReaderWindowController.findNext(_:)), "g"))
        find.addItem(item("查找上一个", #selector(ReaderWindowController.findPrevious(_:)), "g", [.command, .shift]))
        find.addItem(.separator())
        find.addItem(item("在全部文献中搜索", #selector(LibraryWindowController.toggleSearchScope(_:))))
        find.addItem(item("搜索包含 PDF 全文", #selector(LibraryWindowController.toggleFulltextSearch(_:))))
        menu.addItem(submenu("查找", find))
        return menu
    }

    private static func itemMenu() -> NSMenu {
        let menu = NSMenu(title: "条目")
        menu.addItem(item("打开", #selector(FolioWindowController.openSelection(_:)), String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))))
        menu.addItem(item("在 Folio 中阅读", #selector(FolioWindowController.openInReader(_:))))
        menu.addItem(item("用预览打开", #selector(FolioWindowController.openWithPreview(_:))))
        menu.addItem(item("快速查看", #selector(FolioWindowController.quickLookSelection(_:)), "y"))
        menu.addItem(item("在 Finder 中显示", #selector(FolioWindowController.revealInFinder(_:)), "r", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(dynamicSubmenu("添加到分组"))
        menu.addItem(dynamicSubmenu("标签"))
        let status = NSMenu(title: "阅读状态")
        for value in ReadStatus.allCases {
            let entry = item(value.displayName, #selector(LibraryWindowController.setReadStatusFromMenu(_:)))
            entry.tag = value.rawValue
            status.addItem(entry)
        }
        menu.addItem(submenu("阅读状态", status))
        let rating = NSMenu(title: "评分")
        for value in 0...5 {
            let entry = item(value == 0 ? "无评分" : String(repeating: "★", count: value),
                             #selector(LibraryWindowController.setRatingFromMenu(_:)))
            entry.tag = value
            rating.addItem(entry)
        }
        menu.addItem(submenu("评分", rating))
        menu.addItem(.separator())
        menu.addItem(item("编辑笔记", #selector(FolioWindowController.editNote(_:)), "n", [.command, .option]))
        menu.addItem(item("翻译全文…", #selector(FolioWindowController.translateDocument(_:)), "t", [.command, .control]))
        menu.addItem(item("取消翻译", #selector(FolioWindowController.cancelTranslation(_:))))
        menu.addItem(.separator())
        menu.addItem(item("添加文件…", #selector(FolioWindowController.attachFiles(_:))))
        menu.addItem(item("重新检索元数据", #selector(FolioWindowController.retrieveMetadata(_:)), "r", [.command, .option]))
        menu.addItem(item("手动匹配…", #selector(FolioWindowController.manualMatch(_:))))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "显示")
        menu.addItem(item("显示/隐藏边栏", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]))
        menu.addItem(item("显示/隐藏检查器", #selector(NSSplitViewController.toggleInspector(_:)), "i", [.command, .option]))
        let inspector = NSMenu(title: "检查器")
        for (index, tab) in InspectorTab.allCases.enumerated() {
            let entry = item(tab.title, #selector(LibraryWindowController.showInspectorTab(_:)))
            entry.tag = index
            inspector.addItem(entry)
        }
        menu.addItem(submenu("检查器", inspector))
        menu.addItem(.separator())
        menu.addItem(item("按自定义顺序排列", #selector(LibraryWindowController.sortManually(_:))))
        menu.addItem(.separator())
        for entry in ReaderMenus.viewItems() { menu.addItem(entry) }
        menu.addItem(.separator())
        menu.addItem(item("显示工具栏", #selector(NSWindow.toggleToolbarShown(_:)), "t", [.command, .option]))
        menu.addItem(item("自定义工具栏…", #selector(NSWindow.runToolbarCustomizationPalette(_:))))
        menu.addItem(.separator())
        menu.addItem(item("显示标签页栏", #selector(NSWindow.toggleTabBar(_:))))
        menu.addItem(item("显示所有标签页", #selector(NSWindow.toggleTabOverview(_:)), "\\", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("进入全屏幕", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "窗口")
        menu.addItem(item("最小化", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("缩放", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("文献库", #selector(AppDelegate.showLibrary(_:)), "l", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("前置全部窗口", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    // MARK: Helpers

    static func item(_ title: String, _ action: Selector?, _ key: String = "",
                     _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        return item
    }

    static func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        menu.title = title
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func dynamicSubmenu(_ title: String) -> NSMenuItem {
        let menu = NSMenu(title: title)
        menu.delegate = itemSubmenus
        menu.autoenablesItems = false
        return submenu(title, menu)
    }
}

/// Fills "添加到分组" and "标签" from the front window's items, using the same entries as the context menu.
final class ItemSubmenuProvider: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let controller = NSApp.keyWindow?.windowController as? FolioWindowController else {
            menu.addItem(disabled("没有选择条目"))
            return
        }
        let model = controller.model
        let context = controller.menuContext()
        guard !context.itemIds.isEmpty, model.sidebarSelection != .trash else {
            menu.addItem(disabled("没有选择条目"))
            return
        }
        let entries = ItemMenuBuilder.entries(for: context, snapshot: model.snapshot, groups: model.groupsForMenus)
        let wanted = menu.title == "标签" ? "标签" : "添加到"
        for case let .submenu(title, _, children) in entries where title == wanted {
            ItemMenuBuilder.populate(menu, with: children, snapshot: model.snapshot) { [weak controller] command in
                controller?.perform(command, context: context)
            }
        }
        if menu.items.isEmpty { menu.addItem(disabled("没有可用的项目")) }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
