import AppKit

/// Menu-bar entries for the reader (READER-03/04): zoom and layout in 显示, plus 前往 and 批注 menus.
enum ReaderMenus {
    static func viewItems() -> [NSMenuItem] {
        let item = MainMenu.item
        var items = [
            item("实际大小", #selector(ReaderWindowController.actualSize(_:)), "0", .command),
            item("放大", #selector(ReaderWindowController.zoomIn(_:)), "+", .command),
            item("缩小", #selector(ReaderWindowController.zoomOut(_:)), "-", .command),
            item("适合页宽", #selector(ReaderWindowController.zoomToFit(_:)), "9", .command),
            .separator(),
            item("单页连续", #selector(ReaderWindowController.setSinglePage(_:)), "", .command),
            item("双页连续", #selector(ReaderWindowController.setTwoPages(_:)), "", .command),
            .separator(),
        ]
        let sidebar = NSMenu(title: "阅读边栏")
        for tab in ReaderSidebarTab.allCases {
            let entry = item(tab.title, #selector(ReaderWindowController.showReaderSidebarTab(_:)),
                             "\(tab.rawValue + 2)", [.command, .option])
            entry.tag = tab.rawValue
            sidebar.addItem(entry)
        }
        items.append(MainMenu.submenu("阅读边栏", sidebar))
        items.append(item("对照阅读", #selector(ReaderWindowController.toggleParallelReading(_:)), "", .command))
        return items
    }

    static func menus() -> [(String, NSMenu)] {
        let item = MainMenu.item
        let go = NSMenu(title: "前往")
        go.addItem(item("上一页", #selector(ReaderWindowController.goToPreviousPage(_:)),
                        String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), [.command, .option]))
        go.addItem(item("下一页", #selector(ReaderWindowController.goToNextPage(_:)),
                        String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), [.command, .option]))
        go.addItem(item("第一页", #selector(ReaderWindowController.goToFirstPage(_:)),
                        String(Character(UnicodeScalar(NSHomeFunctionKey)!)), []))
        go.addItem(item("最后一页", #selector(ReaderWindowController.goToLastPage(_:)),
                        String(Character(UnicodeScalar(NSEndFunctionKey)!)), []))
        go.addItem(.separator())
        go.addItem(item("后退", #selector(ReaderWindowController.goBack(_:)), "[", .command))
        go.addItem(item("前进", #selector(ReaderWindowController.goForward(_:)), "]", .command))
        go.addItem(.separator())
        go.addItem(item("前往页面…", #selector(ReaderWindowController.goToPageNumber(_:)), "g", [.command, .option]))

        let annotate = NSMenu(title: "批注")
        for tool in AnnotationTool.allCases {
            let entry = item(tool.title, #selector(ReaderWindowController.selectTool(_:)), tool.keyEquivalent, [.command, .control])
            entry.tag = tool.rawValue
            entry.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil)
            annotate.addItem(entry)
            if tool == .select { annotate.addItem(.separator()) }
        }
        annotate.addItem(.separator())
        let colors = NSMenu(title: "颜色")
        for (index, color) in AnnotationColor.allCases.enumerated() {
            let entry = item(color.title, #selector(ReaderWindowController.selectColor(_:)), "", .command)
            entry.tag = index
            entry.image = ReaderWindowController.colorSwatch(color)
            colors.addItem(entry)
        }
        annotate.addItem(MainMenu.submenu("颜色", colors))
        annotate.addItem(.separator())
        annotate.addItem(item("添加到笔记", #selector(ReaderWindowController.addSelectionToNote(_:)), "m", [.command, .control]))
        annotate.addItem(item("删除所选批注", #selector(ReaderWindowController.deleteSelectedAnnotation(_:)), "", .command))
        return [("前往", go), ("批注", annotate)]
    }
}
