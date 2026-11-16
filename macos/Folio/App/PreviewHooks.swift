import AppKit
import PDFKit
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
///   -FolioPreviewSheet   tagEditor | tagEdit | zotero | identifier | manualMatch | translate
///   -FolioPreviewDrop    <file count>            shows the Finder drop overlay
///   -FolioPreviewToast   <text>
///   -FolioPreviewOpenReader <title prefix>      opens that item's PDF in a reader tab
///   -FolioTranslateSelfTest <log>               with Select: translate page 1 via the real coordinator
///   -FolioPreviewParallel YES                   with OpenReader: turn on 对照阅读
///   -FolioPreviewReaderSidebar <tab>            with OpenReader: the sidebar on thumbnails | outline | annotations | search
///   -FolioReaderSelfTest <log>                  with OpenReader: scripted annotation/save/position checks
///   -FolioFeatureSelfTest <log>                 with FeatureSample <pdf>, in an empty library: 1.3's eraser, text
///                                               editing, OCR on import and 划词 cache
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
        if let tab = defaults.string(forKey: "FolioPreviewTab").flatMap(InspectorTab.init(rawValue:)) { model.inspectorTab = tab }
        switch defaults.string(forKey: "FolioPreviewSheet") {
        case "tagEditor": model.activeSheet = .tagEditor(tagId: nil, applyTo: [], initialName: "新论文方向")
        case "tagEdit": model.activeSheet = .tagEditor(tagId: s.tags.first?.id, applyTo: [])
        case "zotero": model.activeSheet = .zoteroImport
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
        if defaults.bool(forKey: "FolioPreviewHideInspector") {
            AppDelegate.shared.libraryWindowController.splitViewController.toggleInspector(nil)
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
                }
            }
        }
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
                let window = defaults.string(forKey: "FolioPreviewSettings") != nil ? AppDelegate.shared.settingsWindow?.window
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
            }
        }
        if let paths = defaults.string(forKey: "FolioPreviewSimulateDrop") {
            // "a.pdf|b.pdf": one drop per file, two seconds apart, to exercise repeated drops.
            for (index, path) in paths.split(separator: "|").map(String.init).enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + Double(index) * 2) { SimulatedDrop.run(path: path, model: model) }
            }
        }
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
