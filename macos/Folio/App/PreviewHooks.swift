import AppKit
import PDFKit
import Quartz
import FolioCore
import FolioTranslate
import Foundation

/// Launch-argument hooks that put the window into a given state, so UI can be checked from
/// screenshots without clicking. Read once after the library loads; no effect in normal use.
///
///   -FolioPreviewScope   all | unfiled | trash | group:<name> | tag:<name>
///   -FolioPreviewSelect  <title prefix>          selects the first matching item
///   -FolioPreviewExpand  YES                     expands the selected item
///   -FolioPreviewSearch  <text>                  opens the search field with text
///   -FolioPreviewTab     metadata | annotations | notes   inspector tab
///   -FolioPreviewSheet   tagEditor | tagEdit | zotero | identifier | manualMatch | translate | packageExport |
///                                               packageImport (with -FolioPreviewPackage <file>)
///   -FolioPreviewDrop    <file count>            shows the Finder drop overlay
///   -FolioPreviewToast   <text>
///   -FolioPreviewOpenReader <title prefix>      opens that item's PDF in a reader tab
///   -FolioTranslateSelfTest <log>               with Select: translate page 1 via the real coordinator
///   -FolioPreviewParallel YES                   with OpenReader: turn on 对照阅读
///   -FolioPreviewReaderSidebar <tab>            with OpenReader: the sidebar on thumbnails | outline | annotations | search
///   -FolioReaderSelfTest <log>                  with OpenReader: scripted annotation/save/position checks
///   -FolioFeatureSelfTest <log>                 with FeatureSample <pdf>, in an empty library: 1.3's eraser, text
///                                               editing, OCR on import and 划词 cache
///   -FolioReadingSelfTest <log>                 rings, status scopes and the reader's progress, in a library with papers
///   -FolioPreviewExpandGroups YES               expands every group in the sidebar
///   -FolioPreviewCollapseSidebar YES            hides the sidebar
///   -FolioPreviewHideInspector YES              hides the inspector
///   -FolioPreviewOnboarding <step>              opens the first-run guide on that step (welcome … done)
///   -FolioPreviewTranslatorNotFound YES         with Onboarding translation: as if no pdf2zh_next were installed
///   -FolioPreviewSettings <pane>                opens the Settings window on that pane (general, translation, ai …)
///   -FolioPreviewFocusedSelection YES           list selection drawn as if the list had focus
///   -FolioPreviewSnapshot <png>                 draws the window into a PNG (works while the screen is locked)
///   -FolioPreviewSnapshotDelay <seconds>        when to draw it (default 3)
///   -FolioPreviewSnapshotLog <file>             what Snapshot found (PDF views, overlays, the edit hook), for debugging
///   -FolioPreviewTranslating <title prefix>    shows that item as being translated (42%)
///   -FolioPreviewTranslationProfiles YES        two sample translation configurations (in memory)
///   -FolioPreviewProfileEditor YES              with Settings 翻译: opens 编辑配置…
///   -FolioPreviewGlossary YES                   with Settings 翻译: opens 术语表 ▸ 管理… on a few sample terms
///   -FolioPreviewModelPicker YES                with Settings 翻译: opens the model list (Snapshot draws it)
///   -FolioPreviewWindowHeight 1400              with Settings: a window this tall, to draw all of a long page
///   -FolioPreviewModelFilter high               with ModelPicker: this typed in its search field
///   -FolioPreviewAppearance light               light or dark, whatever the system's is
///   -FolioPreviewNoGlass YES                    plain prominent buttons: a window with a glass one draws blank in Snapshot
///   -FolioPreviewProfileDetail YES              …and the first configuration's details sheet
///   -FolioPreviewSelectionTranslate <text>      with OpenReader: selects that text and translates it (Snapshot also draws
///                                               the popover into <png>.popover.png)
///   -FolioPreviewSelectionBadge YES             …shows the translate button beside the selection instead
///   -FolioPreviewToggleNotes YES                with OpenReader: opens the notes panel
///   -FolioPreviewAnnotations none|note|text|ink|erase|erasehalf|noteshrink|notegrow
///                                               with OpenReader: markup, a note and a text box on page 1, then a
///                                               note's card or a text box open for writing (the clone's file changes)
///   -FolioPreviewEditText <text>                with OpenReader: 编辑 PDF 文字, the caret after that text (on page
///                                               -FolioPreviewEditPage n), -FolioPreviewEditType <text> typed there
enum PreviewHooks {
    private static var defaults: UserDefaults { .standard }

    static func apply(to model: AppModel) {
        let s = model.snapshot
        if let scope = defaults.string(forKey: "FolioPreviewScope") {
            if scope == "unfiled" { model.sidebarSelection = .unfiled }
            else if scope.hasPrefix("status:"), let raw = Int(scope.dropFirst(7)), let status = ReadStatus(rawValue: raw) { model.sidebarSelection = .status(status) }
            else if scope == "trash" { model.sidebarSelection = .trash }
            else if scope.hasPrefix("group:"), let group = s.groupsById.values.first(where: { $0.name == scope.dropFirst(6) }) {
                model.sidebarSelection = .group(group.id)
            } else if scope.hasPrefix("tag:"), let tag = s.tags.first(where: { $0.name == scope.dropFirst(4) }) {
                model.sidebarSelection = .tag(tag.id)
            }
        }
        if let text = defaults.string(forKey: "FolioPreviewSearch") {
            model.search = SearchState(text: text)
        }
        if let prefix = defaults.string(forKey: "FolioPreviewSelect"),
           let id = model.rows.first(where: { s.items[$0]?.title.hasPrefix(prefix) ?? false }) {
            model.selectedItemIDs = [id]
            if defaults.bool(forKey: "FolioPreviewExpand") { model.previewExpandRequest = id }
            if let log = defaults.string(forKey: "FolioTranslateSelfTest") {
                TranslationSelfTest.run(model: model, itemId: id, log: log)
            }
        }
        // `-FolioPreviewSelectCount <n>`: the first n papers of the list, selected together.
        let count = defaults.integer(forKey: "FolioPreviewSelectCount")
        if count > 1 {
            model.selectedItemIDs = Set(model.rows.filter { s.items[$0]?.kind == .regular }.prefix(count))
        }
        if let prefix = defaults.string(forKey: "FolioPreviewTranslating"),
           let item = s.items.values.first(where: { $0.title.hasPrefix(prefix) }), let file = model.defaultFile(of: item.id) {
            model.translations.previewJob(itemId: item.id, fileId: file.id, stage: "翻译段落 34/120", fraction: 0.42)
        }
        if defaults.bool(forKey: "FolioPreviewTranslationProfiles") {
            // Sample configurations of the OpenAI-compatible service, in memory only; the Keychain is not touched.
            let service = "openaicompatible"
            model.settings.translationService = service
            let profiles = [
                TranslationProfile(name: "DeepSeek", serviceID: service,
                                   fields: ["--openai-compatible-base-url": "https://api.deepseek.com/v1", "--openai-compatible-model": "deepseek-chat"]),
                TranslationProfile(name: "Moonshot", serviceID: service,
                                   fields: ["--openai-compatible-base-url": "https://api.moonshot.cn/v1", "--openai-compatible-model": "kimi-k2"]),
                TranslationProfile(name: "本地 vLLM", serviceID: service,
                                   fields: ["--openai-compatible-base-url": "http://localhost:8000/v1", "--openai-compatible-model": "qwen3-8b"]),
            ]
            model.settings.translationProfiles = profiles
            model.settings.selectedTranslationProfiles[service] = profiles[1].id
        }
        if let path = defaults.string(forKey: "FolioPreviewNoteText"), let text = try? String(contentsOfFile: path, encoding: .utf8) {
            // `-FolioPreviewNoteText <file>`: that text as the selected item's note (with -FolioPreviewTab notes).
            DispatchQueue.main.async { model.selectedItemIDs.first.map { try? model.library.setNote(text, for: $0); NotificationCenter.default.post(name: .folioNoteDidChange, object: $0) } }
        }
        // `-FolioPreviewQuickLook <log>`: 快速查看 of what is selected; `-FolioPreviewMarkdownHTML <file>`: the page it shows.
        if let log = defaults.string(forKey: "FolioPreviewQuickLook") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NSApp.activate()
                model.itemListController?.outline.window?.makeKeyAndOrderFront(nil)
                model.itemListController?.outline.window?.makeFirstResponder(model.itemListController?.outline)
                model.itemListController?.toggleQuickLook()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let item = QLPreviewPanel.shared().currentPreviewItem
                    try? "\(QLPreviewPanel.shared().isVisible) \(item?.previewItemURL?.path ?? "none") \(item?.previewItemTitle ?? "")".write(toFile: log, atomically: true, encoding: .utf8)
                }
            }
        }
        if let path = defaults.string(forKey: "FolioPreviewMarkdownHTML"), let id = model.selectedItemIDs.first, let file = model.defaultFile(of: id),
           let text = try? String(contentsOf: model.fileURL(file), encoding: .utf8) {
            try? MarkdownHTML.page(text, title: file.fileName, base: model.fileURL(file).deletingLastPathComponent()).write(toFile: path, atomically: true, encoding: .utf8)
        }
        if let tab = defaults.string(forKey: "FolioPreviewTab").flatMap(InspectorTab.init(rawValue:)) { model.inspectorTab = tab }
        switch defaults.string(forKey: "FolioPreviewSheet") {
        case "tagEditor": model.activeSheet = .tagEditor(tagId: nil, applyTo: [], initialName: "新论文方向")
        case "tagEdit": model.activeSheet = .tagEditor(tagId: s.tags.first?.id, applyTo: [])
        case "zotero": model.activeSheet = .zoteroImport
        case "packageExport": model.activeSheet = .packageExport
        case "packageImport":
            if let path = defaults.string(forKey: "FolioPreviewPackage") { model.activeSheet = .packageImport(URL(filePath: path)) }
            // `-FolioPreviewSheetReturn YES`: and its default button pressed.
            if defaults.bool(forKey: "FolioPreviewSheetReturn") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    for window in NSApp.windows where window.isSheet {
                        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                        characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) { _ = window.performKeyEquivalent(with: event) }
                    }
                }
            }
        case "identifier": model.activeSheet = .identifierAdd
        case "manualMatch": if let id = model.selectedItemIDs.first { model.activeSheet = .manualMatch(itemId: id) }
        case "translate":
            if let id = model.selectedItemIDs.first, let file = model.defaultFile(of: id) { model.activeSheet = .translate(fileIds: [file.id]) }
        default: break
        }
        let drop = defaults.integer(forKey: "FolioPreviewDrop")
        if drop > 0 { model.externalDropCount = drop }
        if let toast = defaults.string(forKey: "FolioPreviewToast") { model.toasts.show(toast, systemImage: "folder.badge.plus") }
        if defaults.bool(forKey: "FolioPreviewExpandGroups") { model.previewExpandAllGroups = true }
        if defaults.bool(forKey: "FolioPreviewCollapseSidebar") {
            AppDelegate.shared.libraryWindowController.splitViewController.toggleSidebar(nil)
        }
        // `-inspectorFloating YES -FolioPreviewFloatingWidth 520`: the right panel floating, that wide.
        let floatingWidth = defaults.double(forKey: "FolioPreviewFloatingWidth")
        if floatingWidth > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { AppDelegate.shared.libraryWindowController.splitViewController.floatingInspector?.setWidth(floatingWidth) } }
        if defaults.bool(forKey: "FolioPreviewHideInspector") {
            AppDelegate.shared.libraryWindowController.splitViewController.toggleInspector(nil)
        }
        // `-FolioPreviewOpenNote YES`: the selected item's note in a document tab; `-FolioPreviewDetach YES` takes that tab out
        // into a window of its own (放回标签页 shows).
        // `-FolioPreviewOpenDocument YES`: the selected item's first Markdown file in a document tab.
        if defaults.bool(forKey: "FolioPreviewOpenDocument"), let id = model.selectedItemIDs.first,
           let file = s.files(of: id).first(where: \.isMarkdown) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { model.openMarkdown(fileId: file.id) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MarkdownPreview.apply(model.markdownTabs.controller(for: file.id)) }
        }
        // `-FolioPreviewDocumentText <file>`: a new document with that file's text, in a tab.
        if let path = defaults.string(forKey: "FolioPreviewDocumentText"), let text = try? String(contentsOfFile: path, encoding: .utf8),
           let created = try? model.library.createMarkdownDocument(title: String(localized: "未命名文档"), inGroup: nil) {
            try? model.library.writeText(text, toFile: created.fileId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { model.openMarkdown(fileId: created.fileId) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { MarkdownPreview.apply(model.markdownTabs.controller(for: created.fileId)) }
        }
        if defaults.bool(forKey: "FolioPreviewOpenNote"), let id = model.selectedItemIDs.first {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                model.openNote(itemId: id)
                if defaults.bool(forKey: "FolioPreviewDetach") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        let window = NSApp.windows.first { $0.windowController is MarkdownWindowController && $0.isVisible }
                        window?.moveTabToNewWindow(nil)
                        window?.makeKeyAndOrderFront(nil)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { FolioWindowController.updateAllReturnButtons() }
                    }
                }
            }
        }
        if let pane = defaults.string(forKey: "FolioPreviewSettings") {
            AppDelegate.shared.showSettings(nil)
            AppDelegate.shared.settingsWindow?.select(pane: pane)
        }
        if let prefix = defaults.string(forKey: "FolioPreviewOpenReader"),
           let item = s.items.values.first(where: { $0.title.hasPrefix(prefix) }), let file = model.defaultFile(of: item.id) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                model.open(fileId: file.id, mode: .reader)
                if defaults.bool(forKey: "FolioPreviewParallel") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        guard let reader = model.readers.reader(for: file.id) else { return }
                        reader.toggleParallelReading(nil)
                        if let log = defaults.string(forKey: "FolioParallelLog") {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { reader.logParallelState(to: log) }
                        }
                    }
                }
                if let log = defaults.string(forKey: "FolioReaderSelfTest") {
                    ReaderSelfTest.run(model: model, fileId: file.id, log: log)
                }
                if let text = defaults.string(forKey: "FolioPreviewSelectionTranslate") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        model.readers.reader(for: file.id)?.previewSelectionTranslation(text, badgeOnly: defaults.bool(forKey: "FolioPreviewSelectionBadge"))
                    }
                }
                if let log = defaults.string(forKey: "FolioPreviewLogAnnotations") {
                    // Which class draws each annotation the file has (NoteAnnotation / TextBoxAnnotation for notes and text boxes).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        guard let document = model.readers.reader(for: file.id)?.pdfView.document else { return }
                        var lines: [String] = []
                        for index in 0..<min(document.pageCount, 3) {
                            for annotation in document.page(at: index)?.annotations ?? [] {
                                let paths = (annotation.paths ?? []).map { "\($0.elementCount)@\(Int($0.bounds.width))x\(Int($0.bounds.height))" }
                                lines.append("page \(index + 1) \(annotation.type ?? "?") \(String(describing: type(of: annotation))) bounds=\(annotation.bounds.integral) display=\(annotation.shouldDisplay) paths=\(paths) \(annotation.contents ?? "")")
                            }
                        }
                        for row in model.readers.reader(for: file.id)?.state.annotations ?? [] {
                            lines.append("row \(row.kind) page \(row.pageIndex + 1) offPage=\(row.isOffPage)")
                        }
                        try? lines.joined(separator: "\n").write(toFile: log, atomically: true, encoding: .utf8)
                    }
                }
                if let name = defaults.string(forKey: "FolioPreviewReaderSidebar"),
                   let tab = ReaderSidebarTab.allCases.first(where: { "\($0)" == name }) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { model.readers.reader(for: file.id)?.state.sidebarTab = tab }
                }
                if let directory = defaults.string(forKey: "FolioPreviewMenuRender") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        model.readers.reader(for: file.id)?.previewRenderMenus(into: directory)
                    }
                }
                if let path = defaults.string(forKey: "FolioPreviewLayerDump") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        model.readers.reader(for: file.id)?.previewLayerDump(path: path)
                    }
                }
                if let log = defaults.string(forKey: "FolioPreviewClickTools") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        model.readers.reader(for: file.id)?.previewClickTools(log: log)
                    }
                }
                if let open = defaults.string(forKey: "FolioPreviewAnnotations") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        model.readers.reader(for: file.id)?.previewAnnotations(open: open)
                    }
                }
                if let after = defaults.string(forKey: "FolioPreviewEditText") {
                    // Edit mode, with the caret after that text on page FolioPreviewEditPage (1-based), and
                    // FolioPreviewEditType typed there: the file of the cloned library changes, as an edit would.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        guard let reader = model.readers.reader(for: file.id) else { return }
                        let pageIndex = max(defaults.integer(forKey: "FolioPreviewEditPage"), 1) - 1
                        if let page = reader.pdfView.document?.page(at: pageIndex) { reader.pdfView.go(to: page) }
                        reader.toggleTextEditing(nil)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            guard let layer = reader.selfTestEditLayer else { return }
                            let block = layer.selfTestEditable.first(where: { $0.page == pageIndex && $0.text.contains(after) })
                            if let log = defaults.string(forKey: "FolioPreviewSnapshotLog") {
                                try? ("edit: \(layer.stateDescription); blocks on page: " + layer.selfTestEditable.filter { $0.page == pageIndex }
                                    .map { String($0.text.prefix(30)) }.joined(separator: " | ") + "; found \(block != nil)\n").write(toFile: log, atomically: true, encoding: .utf8)
                            }
                            guard let block else { return }
                            let opened = layer.selfTestOpen(page: pageIndex, block: block.index, caretAfter: after)
                            if let typed = defaults.string(forKey: "FolioPreviewEditType"), opened {
                                layer.insertText(typed, replacementRange: NSRange(location: NSNotFound, length: 0))
                            }
                            if let log = defaults.string(forKey: "FolioPreviewSnapshotLog"), let handle = FileHandle(forWritingAtPath: log) {
                                handle.seekToEndOfFile()
                                handle.write(Data("opened \(opened) editing \(layer.isEditingBlock) text \(layer.selfTestText?.prefix(80) ?? "-")\n".utf8))
                                handle.closeFile()
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                if let log = defaults.string(forKey: "FolioPreviewSnapshotLog"), let handle = FileHandle(forWritingAtPath: log) {
                                    handle.seekToEndOfFile(); handle.write(Data("3s later editing \(layer.isEditingBlock)\n".utf8)); handle.closeFile()
                                }
                            }
                        }
                    }
                }
                if defaults.bool(forKey: "FolioPreviewToggleNotes") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        model.readers.reader(for: file.id)?.editNote(itemId: item.id)
                    }
                    // `-FolioPreviewHitLog <path>`: which view takes a click on the notes panel's document menu (its header
                    // at the top of the panel, below the toolbar).
                    if let log = defaults.string(forKey: "FolioPreviewHitLog") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            guard let window = NSApp.windows.first(where: { $0.windowController is ReaderWindowController && $0.isVisible }),
                                  let frame = window.contentView?.superview else { return }
                            let top = window.contentLayoutRect.maxY
                            var lines: [String] = []
                            for (fromTop, fromRight) in [(26.0, 240.0), (26.0, 200.0), (26.0, 150.0), (26.0, 80.0), (26.0, 40.0), (70.0, 200.0)] {
                                let point = NSPoint(x: window.frame.width - fromRight, y: window.frame.height - fromTop)
                                let hit = frame.hitTest(point)
                                var chain: [String] = []
                                var view = hit
                                while let v = view, chain.count < 6 { chain.append(String(describing: type(of: v))); view = v.superview }
                                lines.append("top \(fromTop) right \(fromRight): " + chain.joined(separator: " < "))
                            }
                            lines.append("toolbar band to y \(top), window height \(window.frame.height)")
                            try? lines.joined(separator: "\n").write(toFile: log, atomically: true, encoding: .utf8)
                        }
                    }
                }
            }
        }
        if let log = defaults.string(forKey: "FolioPerfProbe") { PerfProbe.start(log: log) }
        if let log = defaults.string(forKey: "FolioFeature14SelfTest") { Feature14SelfTest.run(model: model, log: log) }
        if let log = defaults.string(forKey: "FolioFeatureSelfTest"), let sample = defaults.string(forKey: "FolioFeatureSample") {
            FeatureSelfTest.run(model: model, log: log, sample: URL(fileURLWithPath: sample))
        }
        if let appearance = defaults.string(forKey: "FolioPreviewAppearance") {
            NSApp.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        }
        if let path = defaults.string(forKey: "FolioPreviewSnapshot") {
            let delay = defaults.double(forKey: "FolioPreviewSnapshotDelay")
            let height = defaults.double(forKey: "FolioPreviewWindowHeight")
            if height > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0.5, (delay > 0 ? delay : 3) - 1)) {
                    guard let window = AppDelegate.shared.settingsWindow?.window else { return }
                    window.setContentSize(NSSize(width: window.contentLayoutRect.width, height: height))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (delay > 0 ? delay : 3)) {
                let reader = NSApp.windows.first { $0.windowController is ReaderWindowController && $0.isVisible }
                let document = NSApp.windows.first { $0.windowController is MarkdownWindowController && $0.isVisible }
                let window = defaults.string(forKey: "FolioPreviewSettings") != nil ? AppDelegate.shared.settingsWindow?.window
                    : defaults.bool(forKey: "FolioPreviewOpenNote") || defaults.bool(forKey: "FolioPreviewOpenDocument") || defaults.string(forKey: "FolioPreviewDocumentText") != nil ? document
                    : defaults.string(forKey: "FolioPreviewOpenReader") != nil ? reader : AppDelegate.shared.libraryWindowController.window
                // An open sheet (e.g. 编辑配置…, and a sheet on top of it) is what the window shows.
                var shown = window
                while let sheet = shown?.attachedSheet { shown = sheet }
                if defaults.bool(forKey: "FolioPreviewModelPicker"),
                   let popover = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("Popover") }) { shown = popover }
                if defaults.string(forKey: "FolioPreviewSelectionTranslate") != nil,
                   let popover = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("Popover") && $0.isVisible }),
                   let view = popover.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: path + ".popover.png"))
                }
                guard let view = shown?.contentView?.superview,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                // The PDF views are drawn by hand (see PreviewSnapshot); left in, some would show crisply under the toolbar.
                let pdfViews = PreviewSnapshot.pdfViews(in: view)
                pdfViews.forEach { $0.isHidden = true }
                view.cacheDisplay(in: view.bounds, to: rep)
                pdfViews.forEach { $0.isHidden = false }
                PreviewSnapshot.drawPDFViews(of: view, into: rep)
                if let window = shown { PreviewSnapshot.drawPopovers(over: window, root: view, into: rep) }
                PreviewSnapshot.fillClearViews(of: view, into: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: path))
                // The sidebar comes out blank in its glass: `-FolioPreviewSidebarSnapshot YES` draws its list alone, into <png>.sidebar.png.
                if defaults.bool(forKey: "FolioPreviewSidebarSnapshot"), let outline = model.sidebarController?.outline,
                   let piece = outline.bitmapImageRepForCachingDisplay(in: outline.bounds) {
                    outline.cacheDisplay(in: outline.bounds, to: piece)
                    try? piece.representation(using: .png, properties: [:])?.write(to: URL(filePath: path + ".sidebar.png"))
                }
            }
        }
        if let log = defaults.string(forKey: "FolioReadingSelfTest") { ReadingStatusSelfTest.run(model: model, log: log) }
        if let log = defaults.string(forKey: "FolioPanelSelfTest") { PanelSelfTest.run(model: model, log: log) }
        if let paths = defaults.string(forKey: "FolioPreviewSimulateDrop") {
            // "a.pdf|b.pdf": one drop per file, two seconds apart, to exercise repeated drops.
            for (index, path) in paths.split(separator: "|").map(String.init).enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + Double(index) * 2) { SimulatedDrop.run(path: path, model: model) }
            }
        }
    }
}

/// `-FolioReadingSelfTest <log>`: a click on a ring, a status dropped on, the pages a reader shows and its offer at the end.
enum ReadingStatusSelfTest {
    static func run(model: AppModel, log: String) {
        Task {
            var lines: [String] = []
            var failures = 0
            func check(_ ok: Bool, _ name: String) { if !ok { failures += 1 }; lines.append((ok ? "ok   " : "FAIL ") + name) }
            @MainActor func wait(_ seconds: Double = 5, until condition: @MainActor () -> Bool) async {
                let end = Date().addingTimeInterval(seconds)
                while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
            }
            try? await Task.sleep(for: .seconds(1))
            let candidates = model.rows.compactMap { model.snapshot.items[$0] }.filter { $0.kind == .regular }
            @MainActor func pages(_ item: Item) -> Int { model.defaultFile(of: item.id).flatMap { PDFDocument(url: model.fileURL($0)) }?.pageCount ?? 0 }
            guard let item = candidates.max(by: { pages($0) < pages($1) }), let file = model.defaultFile(of: item.id), let list = model.itemListController else {
                try? "FAILED no paper".write(toFile: log, atomically: true, encoding: .utf8)
                return
            }
            @MainActor func status() -> ReadStatus? { model.snapshot.items[item.id]?.readStatus }
            model.setReadStatus(.unread, on: [item.id])
            await wait { status() == .unread }
            let before = model.counts[.status(.reading)] ?? 0
            // The ring in the row, clicked.
            @MainActor func ring() -> ReadingRingButton? {
                guard let row = model.rows.firstIndex(of: item.id) else { return nil }
                for r in 0..<list.outline.numberOfRows {
                    guard let cell = list.outline.view(atColumn: list.outline.column(withIdentifier: ItemColumn.title.identifier), row: r, makeIfNecessary: true) as? TitleCell,
                          cell.label.stringValue.hasPrefix(String(item.title.prefix(12))), row >= 0 else { continue }
                    return cell.ring
                }
                return nil
            }
            check(ring()?.isHidden == false && ring()?.status == .unread, "unread ring in the row")
            ring()?.performClick(nil)
            await wait { status() == .reading }
            check(status() == .reading, "a click: being read")
            check(model.selectedItemIDs.isEmpty, "a click does not select the row")
            check(model.counts[.status(.reading)] == before + 1, "the sidebar counts it")
            model.sidebarSelection = .status(.reading)
            check(model.rows.contains(item.id) && model.rows.count == before + 1, "在读 lists it")
            model.sidebarSelection = .status(.unread)
            check(!model.rows.contains(item.id), "未读 does not")
            model.sidebarSelection = .all
            // Read it through.
            model.open(fileId: file.id, mode: .reader)
            let controller = { @MainActor in NSApp.windows.compactMap { $0.windowController as? ReaderWindowController }.first { $0.targetFileId == file.id } }
            await wait { controller()?.window?.isVisible == true }
            try? await Task.sleep(for: .seconds(1.5))
            guard let reader = controller(), let document = reader.pdfView.document, document.pageCount > 2 else {
                try? (lines + ["FAILED no reader or a paper of \(pages(item)) pages"]).joined(separator: "\n").write(toFile: log, atomically: true, encoding: .utf8)
                return
            }
            let last = document.pageCount - 1
            reader.pdfView.go(to: document.page(at: last)!)
            try? await Task.sleep(for: .seconds(1.6))
            let jumped = model.readingProgress[item.id]?.fraction ?? 0
            check(jumped < 0.6 || document.pageCount < 5, "a jump to the end is not reading it (\(jumped))")
            if document.pageCount >= 5 { check(!reader.offersMarkAsRead, "nor is it offered to be marked read") }
            for page in 0...last {
                reader.pdfView.go(to: document.page(at: page)!)
                try? await Task.sleep(for: .seconds(1.3))
            }
            check((model.readingProgress[item.id]?.fraction ?? 0) > 0.95, "every page seen (\(model.readingProgress[item.id]?.fraction ?? 0))")
            check(reader.offersMarkAsRead, "at the end it is offered")
            check(status() == .reading, "and not marked by itself")
            if let path = UserDefaults.standard.string(forKey: "FolioPreviewSnapshot"), let view = reader.window?.contentView?.superview,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: path + ".offer.png"))
            }
            // The button itself, pressed as the mouse would.
            if let button = reader.readOfferButtonPoint(), let window = reader.window {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: button, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { window.sendEvent(event) }
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }
            await wait { status() == .read }
            check(status() == .read, "a press on 标为已读: read")
            check(!reader.offersMarkAsRead, "and the offer goes")
            reader.window?.close()
            let saved = (try? model.library.readingProgress())?[item.id]?.fraction ?? 0
            check(saved > 0.95, "saved with the library")
            ring()?.performClick(nil)
            await wait { status() == .unread }
            check(status() == .unread, "a click on 已读: unread again")
            lines.append(failures == 0 ? "PASSED" : "FAILED \(failures)")
            try? lines.joined(separator: "\n").write(toFile: log, atomically: true, encoding: .utf8)
        }
    }
}

/// `-FolioPanelSelfTest <log>`: 多选 and the right panel, its floating style, and naming new documents.
enum PanelSelfTest {
    static func run(model: AppModel, log: String) {
        Task {
            var lines: [String] = []
            var failures = 0
            func check(_ ok: Bool, _ name: String) { if !ok { failures += 1 }; lines.append((ok ? "ok   " : "FAIL ") + name) }
            func pause(_ seconds: Double = 0.7) async { try? await Task.sleep(for: .seconds(seconds)) }
            await pause(1)
            let library = AppDelegate.shared.libraryWindowController!
            let split = library.splitViewController
            @MainActor func move(_ point: NSPoint, _ window: NSWindow) {
                if let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) { NSApp.sendEvent(event) }
            }
            /// From point to point along an edge the pointer says it can be dragged, and only there; a press there is the edge's.
            @MainActor func checkEdge(_ window: NSWindow, x: CGFloat, ys: [CGFloat], of owner: NSView, _ name: String) {
                let frame = window.contentView!.superview!
                var wrong: [String] = []
                for y in ys {
                    for dx in stride(from: -EdgePointer.reach + 0.5, through: EdgePointer.reach, by: 1) {
                        move(NSPoint(x: x + dx, y: y), window)
                        if NSCursor.current != EdgePointer.cursor { wrong.append("pointer at \(dx), \(y)") }
                        if frame.hitTest(NSPoint(x: x + dx, y: y)) !== owner { wrong.append("press at \(dx), \(y): \(String(describing: frame.hitTest(NSPoint(x: x + dx, y: y)).map { type(of: $0) }))") }
                    }
                    for dx in [-EdgePointer.reach - 6, EdgePointer.reach + 6] {
                        move(NSPoint(x: x + dx, y: y), window)
                        if NSCursor.current == EdgePointer.cursor { wrong.append("pointer still at \(dx), \(y)") }
                    }
                }
                check(wrong.isEmpty, "\(name): \(wrong.prefix(6))")
            }
            for floating in [false, true] {
                let style = floating ? "floating" : "beside"
                model.settings.inspectorFloating = floating
                await pause()
                check((split.floatingInspector != nil) == floating, "\(style): style applied")
                for open in [true, false] {
                    split.setInspectorOpen(open)
                    await pause()
                    check(split.isInspectorOpen == open, "\(style): \(open ? "opens" : "closes")")
                    model.multiSelectMode = true
                    await pause()
                    check(split.isInspectorOpen, "\(style): 多选 shows it")
                    model.multiSelectMode = false
                    await pause()
                    check(split.isInspectorOpen == open, "\(style): after 多选 it is as it was (\(open ? "open" : "closed"))")
                }
                split.setInspectorOpen(true)
                await pause()
                if let window = library.window {
                    let sidebar = split.splitView.arrangedSubviews[0].frame.maxX
                    checkEdge(window, x: sidebar, ys: [200, 400], of: split.splitView, "\(style): the sidebar's edge")
                    if !floating { checkEdge(window, x: split.splitView.arrangedSubviews[2].frame.minX, ys: [200, 400], of: split.splitView, "beside: the panel's edge") }
                }
                if let panel = split.floatingInspector, let window = library.window, let frame = window.contentView?.superview {
                    let top = frame.bounds.maxY
                    if let grip = frame.hitTest(NSPoint(x: panel.frame.minX, y: 300)) {
                        check(grip is NSControl, "floating: its edge is a control (over the toolbar anything else moves the window): \(type(of: grip))")
                        checkEdge(window, x: panel.frame.minX, ys: [120, 300, top - 26, top - 4], of: grip, "floating: its edge, over the toolbar too")
                    }
                    for y in [top - 26, 300] {
                        let before = panel.frame, at = window.frame
                        func event(_ type: NSEvent.EventType, _ dx: CGFloat) -> NSEvent {
                            NSEvent.mouseEvent(with: type, location: NSPoint(x: before.minX + dx, y: y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                        }
                        for dx in [-10, -30, -60] as [CGFloat] { NSApp.postEvent(event(.leftMouseDragged, dx), atStart: false) }
                        NSApp.postEvent(event(.leftMouseUp, -60), atStart: false)
                        window.sendEvent(event(.leftMouseDown, 0))
                        await pause(0.3)
                        check(abs(panel.frame.width - before.width - 60) < 1 && window.frame == at, "floating: dragged at \(y): \(before.width) → \(panel.frame.width), window \(at) → \(window.frame)")
                    }
                }
                if let panel = split.floatingInspector {
                    let list = split.itemList.view.frame.width
                    panel.setWidth(720)
                    await pause(0.3)
                    check(abs(panel.frame.width - 720) < 2, "floating: 720 wide (\(panel.frame.width), window \(library.window?.frame.width ?? 0), after a layout \({ panel.window?.layoutIfNeeded(); return panel.frame.width }()))")
                    check(split.itemList.view.frame.width == list, "floating: the list keeps its width")
                    panel.setWidth(5000)
                    await pause(0.3)
                    check(panel.frame.width <= split.view.bounds.width * 0.8 + 1, "floating: never most of the window")
                    let middle = panel.convert(NSPoint(x: panel.bounds.midX, y: panel.bounds.maxY - 8), to: nil)
                    let hit = library.window?.contentView?.superview?.hitTest(library.window!.contentView!.superview!.convert(middle, from: nil))
                    check(hit?.isDescendant(of: panel) == true, "floating: clicks on it stay on it")
                    panel.setWidth(420)
                    await pause(0.3)
                    if let frame = library.window?.contentView?.superview {
                        check(abs(panel.frame.maxX - frame.bounds.maxX) < 1 && abs(panel.frame.height - frame.bounds.height) < 1, "floating: the window's right edge, its whole height")
                        let top = frame.hitTest(NSPoint(x: panel.frame.midX, y: frame.bounds.maxY - 20))
                        check(top?.isDescendant(of: panel) == true, "floating: over the toolbar")
                    }
                }
            }
            // Over a page, whose view has a pointer of its own.
            if let item = model.snapshot.items.values.first(where: { $0.title.hasPrefix("UNet++") }), let file = model.defaultFile(of: item.id) {
                model.open(fileId: file.id, mode: .reader)
                await pause(2)
                if let reader = model.readers.reader(for: file.id), let window = reader.window, let frame = window.contentView?.superview {
                    reader.editNote(itemId: item.id)
                    await pause(1)
                    if let panel = frame.subviews.lazy.compactMap({ $0 as? FloatingInspector }).first, panel.isOpen, let grip = frame.hitTest(NSPoint(x: panel.frame.minX, y: 300)) {
                        let top = frame.bounds.maxY
                        check(grip is NSControl, "reader: the panel's edge is a control (\(type(of: grip)))")
                        checkEdge(window, x: panel.frame.minX, ys: [120, 300, 500, top - 26, top - 4], of: grip, "reader: the panel's edge, over the page and the toolbar")
                        for y in [top - 26, 300] {
                            let before = panel.frame, at = window.frame
                            func event(_ type: NSEvent.EventType, _ dx: CGFloat) -> NSEvent {
                                NSEvent.mouseEvent(with: type, location: NSPoint(x: before.minX + dx, y: y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                            }
                            for dx in [-10, -30, -60] as [CGFloat] { NSApp.postEvent(event(.leftMouseDragged, dx), atStart: false) }
                            NSApp.postEvent(event(.leftMouseUp, -60), atStart: false)
                            window.sendEvent(event(.leftMouseDown, 0))
                            await pause(0.3)
                            check(abs(panel.frame.width - before.width - 60) < 1 && window.frame == at, "reader: dragged at \(y): \(before.width) → \(panel.frame.width)")
                        }
                    } else { check(false, "reader: the floating panel is open") }
                    window.close()
                    await pause()
                }
            }
            library.window?.makeKeyAndOrderFront(nil)
            model.settings.inspectorFloating = false
            await pause()
            check(split.floatingInspector == nil && split.isInspectorOpen && split.inspector.view.window != nil, "back beside the list, open")
            split.setInspectorOpen(false)
            // Documents.
            var names: [String] = []
            for _ in 0..<2 {
                library.window?.makeKeyAndOrderFront(nil)
                model.newMarkdownDocument()
                await pause(1.4)
                guard let id = model.selectedItemIDs.first, let file = model.defaultFile(of: id), let tab = model.markdownTabs.controller(for: file.id) else { check(false, "document opened"); continue }
                names.append(model.snapshot.items[id]?.title ?? "")
                check(tab.isNaming, "a new document's name is being typed")
            }
            check(Set(names).count == 2, "two new documents are told apart: \(names)")
            library.window?.makeKeyAndOrderFront(nil)
            await pause()
            if let id = model.selectedItemIDs.first, let file = model.defaultFile(of: id), let list = model.itemListController {
                let began = list.beginRenaming(fileId: file.id)
                check(began || library.window?.isKeyWindow != true, "renamed in its row")
                if began, let editor = library.window?.firstResponder as? NSTextView {
                    editor.insertText("实验记录", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
                    library.window?.makeFirstResponder(list.outline)
                    await pause(1)
                    check(model.snapshot.items[id]?.title == "实验记录" && model.snapshot.files[file.id]?.fileName == "实验记录.md", "title and file renamed")
                }
            }
            lines.append(failures == 0 ? "PASSED" : "FAILED \(failures)")
            try? lines.joined(separator: "\n").write(toFile: log, atomically: true, encoding: .utf8)
        }
    }
}

/// `-FolioPreviewDocumentLine <n>`: the caret at the end of line n and its handles beside it; `-FolioPreviewSlash <text>`:
/// "/" and that text typed there (an empty string shows the whole menu); `-FolioPreviewCite YES`: 引用文献's list.
/// `-FolioMarkdownSelfTest <log>`: scripted checks of the menu, the block tools and moving.
enum MarkdownPreview {
    static func apply(_ controller: MarkdownWindowController?) {
        guard let controller else { return }
        let defaults = UserDefaults.standard
        let view = controller.editor.textView
        let string = view.string as NSString
        let wanted = defaults.integer(forKey: "FolioPreviewDocumentLine")
        if wanted > 0 {
            var location = 0
            for _ in 1..<wanted { location = min(NSMaxRange(string.paragraphRange(for: NSRange(location: location, length: 0))), string.length) }
            let line = string.paragraphRange(for: NSRange(location: location, length: 0))
            let end = line.length > 0 && string.character(at: NSMaxRange(line) - 1) == 10 ? NSMaxRange(line) - 1 : NSMaxRange(line)
            view.window?.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: end, length: 0))
            let rect = view.convert(view.window!.convertFromScreen(view.firstRect(forCharacterRange: NSRange(location: end, length: 0), actualRange: nil)), from: nil)
            view.updateGutter(at: NSPoint(x: view.bounds.midX, y: rect.midY))
        }
        if defaults.bool(forKey: "FolioPreviewTable"), let table = view.blockViews.tables.first {
            table.focus(.end)
            table.hover(at: NSPoint(x: 120, y: 60))
            view.scrollToVisible(table.frame.insetBy(dx: 0, dy: -200))
        }
        if defaults.bool(forKey: "FolioPreviewSelectTable"), let table = view.structure.tables.first { view.selectBlock(table.range) }
        if defaults.bool(forKey: "FolioPreviewSelectAll") { view.window?.makeFirstResponder(view); view.setSelectedRange(NSRange(location: 0, length: string.length)) }
        if defaults.bool(forKey: "FolioPreviewInsertTable") { view.window?.makeFirstResponder(view); view.setSelectedRange(NSRange(location: string.length, length: 0)); view.insertTable(); view.blockViews.tables.first?.hover(at: NSPoint(x: 100, y: 60)) }
        if defaults.bool(forKey: "FolioPreviewCells"), let table = view.blockViews.tables.first { table.focus(.start); table.select(from: table.cell(0, 0), to: NSPoint(x: 150, y: 60)) }
        if defaults.bool(forKey: "FolioPreviewCaret") {
            // The caret is not drawn in a window that is not the key one: a bar where it would be.
            let rect = view.convert(view.window!.convertFromScreen(view.firstRect(forCharacterRange: NSRange(location: view.selectedRange().location, length: 0), actualRange: nil)), from: nil)
            let bar = NSBox(frame: NSRect(x: rect.minX - 1, y: rect.minY, width: 2, height: rect.height))
            bar.boxType = .custom
            bar.borderWidth = 0
            bar.fillColor = .systemRed
            view.addSubview(bar)
        }
        if let text = defaults.string(forKey: "FolioPreviewSlash") {
            view.openMenu(typingSlash: true)
            for character in text { view.insertText(String(character), replacementRange: view.selectedRange()) }
        }
        if defaults.bool(forKey: "FolioPreviewCite") { view.openMenu(typingSlash: true, citing: true) }
        if let log = defaults.string(forKey: "FolioMarkdownSelfTest") { selfTest(controller, log: log) }
        MarkdownEditorTest.run(controller)
    }

    /// What a person does with the menu, the handles and the toolbar, checked against the text it leaves.
    private static func selfTest(_ controller: MarkdownWindowController, log: String) {
        let view = controller.editor.textView
        var lines: [String] = []
        var failures = 0
        func check(_ name: String, _ text: String, _ expected: String) {
            if text == expected { lines.append("ok   \(name)") } else { failures += 1; lines.append("FAIL \(name): \(text.debugDescription) != \(expected.debugDescription)") }
        }
        func set(_ text: String, caret: Int? = nil) {
            view.window?.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
            view.insertText(text, replacementRange: view.selectedRange())
            view.setSelectedRange(NSRange(location: caret ?? (text as NSString).length, length: 0))
        }
        func type(_ text: String) { for c in text { view.insertText(String(c), replacementRange: view.selectedRange()) } }
        func key(_ code: UInt16, _ characters: String) {
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                                            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) { view.keyDown(with: event) }
        }
        let enter = { key(36, "\r") }, down = { key(125, "\u{F701}") }, escape = { key(53, "\u{1B}") }
        set(""); type("/h2"); enter(); check("slash h2", view.string, "## ")
        set("abc"); type("\n/bt1"); enter(); type("题"); check("slash pinyin initials", view.string, "abc\n# 题")
        set(""); type("、renwu"); enter(); check("ideographic comma opens the menu", view.string, "- [ ] ")
        set("甲"); type("、乙"); check("comma in a sentence", view.string, "甲、乙")
        set("and"); type("/or"); enter(); check("slash inside a word", view.string, "and/or\n")
        set(""); type("/"); escape(); check("escape keeps a typed slash", view.string, "/")
        set(""); type("/"); down(); down(); enter(); check("arrow keys", view.string, "## ")
        set("text"); view.openMenu(typingSlash: true); escape(); check("escape takes back a button's slash", view.string, "text")
        set("- item"); type("\n/quote"); enter(); check("list item becomes a quote", view.string, "- item\n> ")
        set(""); type("/代码"); enter(); check("code block", view.string, "```\n\n```\n")
        set("```\nx\n```", caret: 5); view.setBlockStyle(.text); check("code block to text", view.string, "x\n")
        set("1. a\n2. b"); view.setSelectedRange(NSRange(location: 0, length: 9)); view.setBlockStyle(.task); check("numbered to tasks", view.string, "- [ ] a\n- [ ] b")
        set("> - [x] done"); view.setBlockStyle(.heading(3)); check("nested markers to a heading", view.string, "### done")
        set("a\nb\nc"); view.moveBlock(view.block(at: 0), by: 1); check("move down", view.string, "b\na\nc")
        set("a\nb\nc"); view.moveBlock(view.block(at: 4), by: -1); check("move the last line up", view.string, "a\nc\nb")
        set("a\nb\nc"); view.moveBlock(view.block(at: 0), to: 5); check("move to the end", view.string, "b\nc\na")
        set("- a\n  - a1\n- b"); view.moveBlock(view.block(at: 0), by: 1); check("item moves with what is under it", view.string, "- b\n- a\n  - a1")
        set("p\n```\nx\n```\nq"); view.moveBlock(view.block(at: 0), by: 1); check("past a whole code block", view.string, "```\nx\n```\np\nq")
        set("| a |\n| - |\n| 1 |\nq"); view.undoManager?.removeAllActions(); view.undoManager?.beginUndoGrouping(); view.moveBlock(view.block(at: 6), by: 1); check("a table moves whole", view.string, "q\n| a |\n| - |\n| 1 |")
        view.undoManager?.endUndoGrouping(); view.undoManager?.undo(); check("undo a move", view.string, "| a |\n| - |\n| 1 |\nq")
        set("a\nb"); view.duplicateBlock(view.block(at: 0)); check("duplicate", view.string, "a\na\nb")
        set("a\nb"); view.deleteBlock(view.block(at: 2)); check("delete the last line", view.string, "a")
        set("a\nb"); view.deleteBlock(view.block(at: 0)); check("delete the first line", view.string, "b")
        set("a"); view.addLine(below: view.block(at: 0)); type("h1"); enter(); check("plus adds a line and the menu", view.string, "a\n# ")
        set("see "); view.openMenu(typingSlash: true, citing: true); type("unet"); enter()
        check("cite", view.string.hasPrefix("see [") && view.string.contains("](folio://open?item=") ? "yes" : view.string, "yes")
        set("# A\n## B `x`\n```\n# no\n```\n### [C](u)"); check("outline", controller.editor.headings.map { "\($0.level)\($0.title)" }.joined(separator: "|"), "1A|2B x|3C")
        set("深度学习 deep learning's 2024"); check("word count", "\(controller.editor.wordCount)", "7")
        func indicator(_ name: String) {
            view.layoutSubtreeIfNeeded()
            let found = view.subviews.first { $0.className.contains("InsertionIndicator") }
            let rect = view.firstRect(forCharacterRange: view.selectedRange(), actualRange: nil)
            lines.append("     caret \(name): \(found.map { NSStringFromRect($0.frame) } ?? "none") first \(Int(rect.width))x\(Int(rect.height))")
        }
        for (name, text) in [("text", "abc"), ("bullet at the end", "- "), ("bullet", "- \n"), ("heading", "## "), ("quote", "x\n> "), ("task", "- [ ] "), ("code", "```\n\n```")] {
            set(text, caret: name == "code" ? 4 : name == "bullet" ? 2 : nil)
            indicator(name)
        }
        // Lists, quotes, headings: their symbols are passed over and taken away as one.
        func ret() { view.insertNewline(nil) }
        func back() { view.deleteBackward(nil) }
        func caret(_ name: String, _ expected: Int) { check(name, "\(view.selectedRange().location)", "\(expected)") }
        set("- a"); ret(); type("b"); check("item continues", view.string, "- a\n- b")
        set("- a\n- "); ret(); check("an empty item ends the list", view.string, "- a\n")
        set("- a\n  - "); ret(); check("an empty nested item goes out one level", view.string, "- a\n- ")
        set("1. a\n2. b\n3. c", caret: 4); ret(); type("x"); check("numbers follow", view.string, "1. a\n2. x\n3. b\n4. c")
        set("- a\n- b"); view.insertTab(nil); check("tab nests", view.string, "- a\n  - b"); view.insertBacktab(nil); check("shift-tab un-nests", view.string, "- a\n- b")
        set("1. a\n2. b"); view.insertTab(nil); check("tab nests under a number", view.string, "1. a\n   1. b")
        set("- a", caret: 2); view.insertTab(nil); check("a first item has nothing to nest under", view.string, "- a")
        set("- a\n- b\n  - c", caret: 6); view.insertTab(nil); check("what is under an item goes along", view.string, "- a\n  - b\n    - c")
        set("- a", caret: 2); back(); check("backspace takes the bullet", view.string, "a"); caret("caret after the bullet went", 0)
        set("- a\n  - b", caret: 8); back(); check("backspace un-nests first", view.string, "- a\n- b")
        set("# T", caret: 2); back(); check("backspace takes the heading", view.string, "T")
        set("> q"); ret(); type("r"); check("quote continues", view.string, "> q\n> r"); ret(); ret(); type("t"); check("an empty quoted line ends the quote", view.string, "> q\n> r\nt")
        set("> q", caret: 2); back(); check("backspace takes the quote", view.string, "q")
        set("> > q", caret: 4); back(); check("backspace takes one level of quote", view.string, "> q")
        set("> - a"); ret(); type("b"); check("list in a quote", view.string, "> - a\n> - b")
        set("- a"); view.insertLineBreak(nil); type("b"); check("a further line of an item", view.string, "- a\n  b")
        set("- a\n  b", caret: 6); back(); check("backspace joins it again", view.string, "- ab")
        set("x\n- a", caret: 4); view.moveLeft(nil); caret("left from an item's text goes to the line above", 1)
        set("x\n- a", caret: 1); view.moveRight(nil); caret("right goes to the item's text", 4)
        set("x\n- a", caret: 5); view.moveToBeginningOfLine(nil); caret("beginning of an item", 4)
        set("- a", caret: 3); view.toggleTask(at: 0); check("not a task", view.string, "- a")
        set("- [ ] a"); view.toggleTask(at: 0); check("task done", view.string, "- [x] a"); ret(); type("b"); check("the next task is open", view.string, "- [x] a\n- [ ] b")
        set(""); type("[] x"); check("brackets make a task", view.string, "- [ ] x")
        set(""); type("》 x"); check("the Chinese bracket makes a quote", view.string, "> x")
        set("a\n- b", caret: 1); view.deleteForward(nil); check("delete joins without the bullet", view.string, "ab")
        set("a\n---\nb", caret: 6); back(); check("backspace after a rule takes it", view.string, "a\nb")
        set("a\n---\nb", caret: 1); view.moveRight(nil); caret("a rule is passed over", 6)
        // Code blocks.
        set(""); type("```py"); ret(); type("x"); check("a fence closes itself", view.string, "```py\nx\n```\n")
        set("a\n```\nx\n```\nb", caret: 1); view.moveRight(nil); caret("into the code", 6)
        set("a\n```\nx\n```\nb", caret: 7); view.moveRight(nil); caret("out of the code", 12)
        set("a\n```\nx\n```\nb", caret: 12); view.moveLeft(nil); caret("back into the code", 7)
        set("a\n```\nx\n```\nb", caret: 12); back(); check("backspace after code selects it", "\(view.selectedRange())", "{2, 9}"); back(); check("and again deletes it", view.string, "a\nb")
        set("a\n\n| x |\n| --- |\n| 1 |\n\nb", caret: 23); back(); back(); check("backspace twice after a table deletes it, with one of the empty lines", view.string, "a\n\nb")
        set("a\n| x |\n| --- |\n| 1 |\nb"); view.setSelectedRange(NSRange(location: 0, length: 5)); check("a selection takes a table whole", "\(view.selectedRange())", "{0, 21}"); back(); check("and deletes it whole", view.string, "\nb")
        set("a\n```\nx\n```\nb"); view.setSelectedRange(NSRange(location: 0, length: 7)); back(); check("a selection takes a code block whole", view.string, "\nb")
        set("a\n```\nxy\n```\nb"); view.setSelectedRange(NSRange(location: 6, length: 2)); back(); check("inside a code block it takes what it is", view.string, "a\n```\n\n```\nb")
        set("a\n\n| x |\n| --- |\n| 1 |"); view.deleteBlock(view.block(at: 5)); check("the last block goes with the line above it", view.string, "a\n")
        set("| x | y |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |\n\nz", caret: 0)
        if let table = view.blockViews.tables.first {
            // Dragged with the mouse from a cell to another.
            func at(_ row: Int, _ column: Int) -> NSPoint { table.cellCenter(row, column) }
            func drag(_ from: (Int, Int), _ to: (Int, Int)) {
                func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
                    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                }
                NSApp.postEvent(event(.leftMouseDragged, at(to.0, to.1)), atStart: false)
                NSApp.postEvent(event(.leftMouseUp, at(to.0, to.1)), atStart: false)
                table.cell(from.0, from.1).mouseDown(with: event(.leftMouseDown, at(from.0, from.1)))
            }
            drag((1, 0), (1, 1)); check("a row's cells dragged over", "\(table.selected.map { "\($0.rows) \($0.columns)" } ?? "none")", "1...1 0...1")
            check("copied as a table", table.selectedText ?? "", "1\t2")
            table.cell(1, 0).doCommand(by: #selector(NSResponder.deleteBackward(_:))); check("a whole row deleted", view.string, "| x | y |\n| --- | --- |\n| 3 | 4 |\n\nz")
            drag((0, 0), (0, 0)); check("a click selects no cells", "\(table.selected == nil)", "true")
            drag((1, 1), (0, 1)); table.cell(0, 1).doCommand(by: #selector(NSResponder.deleteBackward(_:))); check("a whole column deleted", view.string, "| x |\n| --- |\n| 3 |\n\nz")
            drag((0, 0), (1, 0)); table.cell(0, 0).doCommand(by: #selector(NSResponder.deleteBackward(_:))); check("all cells: the table goes", view.string, "z")
        }
        set("甲乙\n\n| x | y |\n| --- | --- |\n| 1 | 2 |\n\nz", caret: 0)
        if let table = view.blockViews.tables.first {
            // Dragged with the mouse from a line onto the table, and from below it.
            func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            func place(_ location: Int) -> NSPoint {
                let rect = view.window!.convertFromScreen(view.firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil))
                return NSPoint(x: rect.minX + 1, y: rect.midY)
            }
            for (name, from, expected) in [("above", place(1), "{1, 36}"), ("below", place(37), "{4, 33}")] {
                let to = table.cellCenter(1, 1)
                NSApp.postEvent(event(.leftMouseDragged, to), atStart: false)
                NSApp.postEvent(event(.leftMouseUp, to), atStart: false)
                view.mouseDown(with: event(.leftMouseDown, from))
                check("dragged onto a table from \(name)", "\(view.selectedRange())", expected)
            }
        }
        set("| x | y |\n| --- | --- |\n| 1 | 2 |\n\nz", caret: 0)
        view.blockViews.focusTable(0, at: .start)
        if let cell = view.window?.firstResponder as? MarkdownCellView {
            cell.selectAll(nil); cell.selectAll(nil); check("⌘A twice selects the table", "\(view.window?.firstResponder === view) \(view.selectedRange())", "true {0, 33}")
            back(); check("Delete takes it", view.string, "z")
        }
        set("```\n\n```", caret: 4); back(); check("backspace in an empty block takes it", view.string, "\n")
        set("```\nif x:\n```", caret: 9); ret(); type("y"); check("code indents after a colon", view.string, "```\nif x:\n    y\n```\n"); back(); back(); check("backspace takes the indent", view.string, "```\nif x:\n\n```\n")
        set("```\na\nb\n```", caret: 4); view.setSelectedRange(NSRange(location: 4, length: 3)); view.insertTab(nil); check("tab indents code", view.string, "```\n    a\n    b\n```\n"); view.insertBacktab(nil); check("shift-tab takes it back", view.string, "```\na\nb\n```\n")
        set("```\nx\n```", caret: 5); view.moveDown(nil); type("y"); check("down leaves a block at the end", view.string, "```\nx\n```\ny")
        set("```\ndef f(x):\n    return x\n```", caret: 5)
        if let code = view.structure.codes.first { check("language found", code.language(in: view.string as NSString).id ?? "", "python"); view.setLanguage("swift", of: code); check("language set", String(view.string.prefix(9)), "```swift\n") }
        check("highlighter", CodeHighlighter.shared.tokens("return 1", language: "python").map(\.kind).joined(separator: " "), "keyword number")
        // Tables.
        set("a\n\n| x | y |\n| --- | :-: |\n| 1 | 2\\|3 |\n\nb", caret: 0)
        check("table read", "\(view.structure.tables.first?.table.rows ?? [])", "[[\"x\", \"y\"], [\"1\", \"2|3\"]]")
        if let table = view.blockViews.tables.first {
            view.blockViews.focusTable(0, at: .end)
            let cell = view.window?.firstResponder as? MarkdownCellView
            check("the last cell has the keyboard", "\(cell?.row ?? -1),\(cell?.column ?? -1)", "1,1")
            cell?.insertText("!", replacementRange: cell!.selectedRange())
            check("typed in a cell", view.string, "a\n\n| x | y |\n| --- | :---: |\n| 1 | 2\\|3! |\n\nb")
            cell?.doCommand(by: #selector(NSResponder.insertTab(_:)))
            check("tab adds a row", view.string, "a\n\n| x | y |\n| --- | :---: |\n| 1 | 2\\|3! |\n|  |  |\n\nb")
            check("its first cell is next", "\((view.window?.firstResponder as? MarkdownCellView)?.row ?? -1)", "2")
            table.insertColumn(at: 1)
            check("column added", String(view.string.dropFirst(3).prefix(14)), "| x |  | y |\n|")
            (view.window?.firstResponder as? MarkdownCellView)?.doCommand(by: #selector(NSResponder.moveUp(_:)))
            check("up leaves the table", "\(view.window?.firstResponder === view) \(view.selectedRange().location)", "true 2")
            if let first = view.blockViews.tables.first { first.focus(.start); if let cell = view.window?.firstResponder as? MarkdownCellView { first.paste([["p", "q"], ["r", "s"]], at: cell) } }
            check("cells pasted", view.string, "a\n\n| p | q | y |\n| --- | --- | :---: |\n| r | s | 2\\|3! |\n|  |  |  |\n\nb")
            view.blockViews.tables.first?.removeTable()
            check("table removed", view.string, "a\n\nb")
        }
        set("| a | b |\n| --- | --- |\n| 1 | 2 |\n\nz", caret: 0)
        view.undoManager?.removeAllActions()
        view.blockViews.focusTable(0, at: .start)
        if let cell = view.window?.firstResponder as? MarkdownCellView {
            view.undoManager?.beginUndoGrouping()
            cell.insertText("X", replacementRange: NSRange(location: 1, length: 0)); cell.insertText("Y", replacementRange: NSRange(location: 2, length: 0))
            view.undoManager?.endUndoGrouping()
            check("cell typed", String(view.string.prefix(11)), "| aXY | b |")
            view.undoManager?.undo(); check("cell undone", String(view.string.prefix(9)), "| a | b |")
            view.undoManager?.redo(); check("cell redone", String(view.string.prefix(11)), "| aXY | b |")
        }
        set(""); view.insertTable(); check("a new table is written in", "\(view.window?.firstResponder is MarkdownCellView)", "true")
        lines.append(failures == 0 ? "PASSED" : "FAILED \(failures)")
        try? lines.joined(separator: "\n").write(toFile: log, atomically: true, encoding: .utf8)
    }
}

/// What `cacheDisplay` leaves out of a window: PDFKit draws its pages in tiled layers, which come out blank. The
/// visible pages of each PDF view are drawn into the snapshot where the view shows them (annotations included), under
/// the window's toolbar, and Folio's own views over a PDF (editing frames…) are drawn again on top.
enum PreviewSnapshot {
    static func drawPDFViews(of root: NSView, into rep: NSBitmapImageRep) {
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        let cg = context.cgContext
        for pdfView in descendants(of: root).compactMap({ $0 as? PDFView }) where !pdfView.isHiddenOrHasHiddenAncestor {
            guard let window = pdfView.window else { continue }
            // Not under the toolbar and tab bar: what shows there is the window's own.
            // Not under the toolbar and tab bar: what shows there is the window's own. Rows just below them that came
            // out black (the edge of the scroll pocket) belong to the PDF view too.
            var unobscured = root.convert(window.contentLayoutRect, from: nil)
            let column = Int(pdfView.convert(pdfView.bounds, to: root).midX * CGFloat(rep.pixelsWide) / root.bounds.width)
            let perPoint = CGFloat(rep.pixelsHigh) / root.bounds.height
            let top = unobscured.maxY
            while unobscured.maxY < min(root.bounds.maxY, top + 12),
                  let color = rep.colorAt(x: column, y: Int((root.bounds.maxY - unobscured.maxY - 0.5) * perPoint)),
                  color.alphaComponent < 0.1 || color.redComponent + color.greenComponent + color.blueComponent < 0.05 {
                unobscured.size.height += 0.5
            }
            let area = pdfView.convert(pdfView.visibleRect, to: root).intersection(unobscured)
            guard !area.isEmpty else { continue }
            cg.saveGState()
            cg.clip(to: area)
            // System colours resolve in the window's appearance; outside it they draw nothing.
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                cg.setFillColor(NSColor.windowBackgroundColor.cgColor)
                cg.fill(area)
                cg.setFillColor(pdfView.backgroundColor.cgColor)
                cg.fill(area)
            }
            if let log = UserDefaults.standard.string(forKey: "FolioPreviewSnapshotLog") {
                let line = "view \(pdfView.convert(pdfView.bounds, to: root)) scale \(pdfView.scaleFactor) pages " + pdfView.visiblePages.map { "\(pdfView.convert(pdfView.convert($0.bounds(for: pdfView.displayBox), from: $0), to: root))" }.joined(separator: " ") + "\n"
                if let handle = FileHandle(forWritingAtPath: log) { handle.seekToEndOfFile(); handle.write(Data(line.utf8)); handle.closeFile() } else { try? line.write(toFile: log, atomically: true, encoding: .utf8) }
            }
            for page in pdfView.visiblePages {
                let box = page.bounds(for: pdfView.displayBox)
                let frame = pdfView.convert(pdfView.convert(box, from: page), to: root)
                guard frame.intersects(area) else { continue }
                if pdfView.pageShadowsEnabled {
                    cg.saveGState()
                    cg.setShadow(offset: CGSize(width: 0, height: -1), blur: 4, color: NSColor.black.withAlphaComponent(0.25).cgColor)
                    cg.setFillColor(.white); cg.fill(frame)
                    cg.restoreGState()
                }
                cg.setFillColor(.white)
                cg.fill(frame)
                cg.saveGState()
                cg.translateBy(x: frame.minX, y: frame.minY)
                let rotated = page.rotation % 180 != 0
                cg.scaleBy(x: frame.width / (rotated ? box.height : box.width), y: frame.height / (rotated ? box.width : box.height))
                page.draw(with: pdfView.displayBox, to: cg)
                cg.restoreGState()
            }
            // The selected text, as the view shows it.
            if let selection = pdfView.currentSelection {
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    cg.setFillColor(NSColor.selectedTextBackgroundColor.withAlphaComponent(0.55).cgColor)
                }
                cg.setBlendMode(.multiply)
                for page in selection.pages {
                    for line in selection.selectionsByLine() where line.pages.contains(page) {
                        cg.fill(pdfView.convert(pdfView.convert(line.bounds(for: page), from: page), to: root))
                    }
                }
                cg.setBlendMode(.normal)
            }
            cg.restoreGState()
            if let log = UserDefaults.standard.string(forKey: "FolioPreviewSnapshotLog"), let handle = FileHandle(forWritingAtPath: log) {
                handle.seekToEndOfFile()
                handle.write(Data(("subviews: " + descendants(of: pdfView).map { "\(String(reflecting: type(of: $0))) \($0.visibleRect)" }.joined(separator: ", ") + "\n").utf8))
                handle.closeFile()
            }
            // Folio's views inside the PDF view (frames of the paragraphs being edited, the translate button…).
            // (SwiftUI views of Folio's too: the text box's bar.)
            let ours = { (view: NSView) in String(reflecting: type(of: view)).contains("Folio.") }
            for view in descendants(of: pdfView) where ours(view) && (view.superview === pdfView || !(view.superview.map(ours) ?? false)) && !view.isHiddenOrHasHiddenAncestor {
                // Only what shows: the edit layer is as tall as the whole document.
                let shown = view.visibleRect
                guard !shown.isEmpty, let piece = view.bitmapImageRepForCachingDisplay(in: shown) else { continue }
                view.cacheDisplay(in: shown, to: piece)
                if let log = UserDefaults.standard.string(forKey: "FolioPreviewSnapshotLog") {
                    try? piece.representation(using: .png, properties: [:])?.write(to: URL(filePath: log + ".overlay.png"))
                    if let handle = FileHandle(forWritingAtPath: log) { handle.seekToEndOfFile(); handle.write(Data("overlay \(shown) -> \(view.convert(shown, to: root)) editing \((view as? PDFTextEditMode)?.isEditingBlock ?? false)\n".utf8)); handle.closeFile() }
                }
                let frame = view.convert(shown, to: root)
                cg.saveGState()
                cg.clip(to: area)
                piece.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                cg.restoreGState()
            }
        }
    }

    /// Popovers shown over the window (划词翻译's translation, its button), drawn where they are on screen.
    static func drawPopovers(over window: NSWindow, root: NSView, into rep: NSBitmapImageRep) {
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        for popover in NSApp.windows where popover.isVisible && popover !== window
            && String(describing: type(of: popover)).contains("Popover") && popover.frame.intersects(window.frame) {
            // The content only: the popover's glass frame comes out as coloured noise.
            guard let view = popover.contentView, let piece = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: piece)
            let onScreen = popover.convertToScreen(view.convert(view.bounds, to: nil))
            let frame = NSRect(x: onScreen.minX - window.frame.minX, y: onScreen.minY - window.frame.minY,
                               width: onScreen.width, height: onScreen.height)
            // A plain rounded card behind it, as the popover's material would be.
            let card = NSBezierPath(roundedRect: frame, xRadius: 14, yRadius: 14)
            context.cgContext.saveGState()
            context.cgContext.setShadow(offset: CGSize(width: 0, height: -6), blur: 24, color: NSColor.black.withAlphaComponent(0.22).cgColor)
            popover.effectiveAppearance.performAsCurrentDrawingAppearance { NSColor.windowBackgroundColor.setFill() }
            card.fill()
            context.cgContext.restoreGState()
            NSColor.black.withAlphaComponent(0.1).setStroke()
            card.lineWidth = 0.5
            card.stroke()
            context.cgContext.saveGState()
            card.addClip()
            piece.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            context.cgContext.restoreGState()
        }
    }

    /// Views behind glass (the sidebar's list, segmented controls on glass) come out clear: each scroll view, segmented
    /// control and the like whose middle is clear is drawn again on its own, over the background its material would show;
    /// whatever is still clear gets the window's background.
    static func fillClearViews(of root: NSView, into rep: NSBitmapImageRep) {
        guard let window = root.window, let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        let cg = context.cgContext
        func clear(at point: NSPoint) -> Bool {
            let x = Int(point.x * CGFloat(rep.pixelsWide) / root.bounds.width)
            let y = Int((root.bounds.height - point.y) * CGFloat(rep.pixelsHigh) / root.bounds.height)
            guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return false }
            return (rep.colorAt(x: x, y: y)?.alphaComponent ?? 1) < 0.05
        }
        let dark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let sidebar = dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.955, alpha: 1)
        // Lists and controls that came out clear (in the sidebar's glass container…): drawn again on their own.
        let candidates = descendants(of: root).filter { view in
            (view is NSScrollView || view is NSSegmentedControl) && !view.isHiddenOrHasHiddenAncestor
                && !sequence(first: view, next: { $0.superview }).contains { $0 is PDFView }
        }
        for view in candidates {
            let frame = view.convert(view.bounds, to: root)
            guard frame.width > 4, clear(at: NSPoint(x: frame.midX, y: frame.midY)) else { continue }
            if view is NSScrollView {
                cg.saveGState()
                cg.setBlendMode(.destinationOver)
                cg.setFillColor(sidebar.cgColor)
                cg.fill(view.superview.map { $0.convert($0.bounds, to: root) } ?? frame)
                cg.restoreGState()
            }
            guard let piece = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: piece)
            piece.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            cg.setBlendMode(.destinationOver)
            cg.setFillColor(NSColor.windowBackgroundColor.cgColor)
            cg.fill(root.bounds.insetBy(dx: 12, dy: 12))
            cg.setBlendMode(.normal)
        }
    }

    static func pdfViews(in root: NSView) -> [PDFView] {
        descendants(of: root).compactMap { $0 as? PDFView }.filter { !$0.isHiddenOrHasHiddenAncestor }
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
