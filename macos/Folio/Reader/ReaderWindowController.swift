import AppKit
import FolioCore
import FolioTranslate
import PDFKit
import SwiftUI

/// One paper in its own native tab (READER-01…10). The PDF is shown with PDFKit — the engine
/// Preview uses — and annotations are written back into the file in standard form.
final class ReaderWindowController: FolioWindowController, NSToolbarDelegate, NSSearchFieldDelegate, PDFDocumentDelegate, NSMenuDelegate {
    let fileId: String
    private(set) var itemId: String
    let state: ReaderState
    let pdfView = ReaderPDFView()
    private let editor: AnnotationEditor
    private let content: ReaderContentViewController
    private let split = SmoothSplitViewController()
    private var notesPane: PaneContainerController!
    private var sidebarItem: NSSplitViewItem!
    private var notesItem: NSSplitViewItem!
    private var notesHost: NSHostingController<ReaderNotesPanel>!
    /// The document the notes panel shows (the note or a Markdown attachment), chosen from the toolbar above it.
    private let notesChoice = ItemDocumentChoice()
    private var notesMenuHost: NSHostingView<ItemDocumentsMenu>?
    private var notesCollapseObservation: NSKeyValueObservation?
    private var notesFocusRequest = 0
    private var observers: [ObservationLoop] = []
    private var selectionTranslation: SelectionTranslationController!
    private var keyMonitor: Any?
    private weak var toolGroup: NSToolbarItemGroup?
    /// The colour panel, while it picks a tool's or an annotation's colour.
    private let colorPanel = ColorPanelBridge()
    private weak var searchItem: NSSearchToolbarItem?
    private weak var textEditItem: NSToolbarItem?
    /// 编辑 PDF 文字 (EDIT-01), while it is on.
    private var textEditMode: PDFTextEditMode?

    private var fileURL: URL
    private var saveTask: Task<Void, Never>?
    private var positionTask: Task<Void, Never>?
    private var isDirty = false
    /// Modification date of the file as last read or written by this reader (to notice outside edits).
    private var knownModificationDate: Date?
    private var restoredPosition = false
    private var findHits: [PDFSelection] = []
    /// A page requested before the view was ready; it wins over the remembered position.
    private var pendingPageIndex: Int?

    init?(model: AppModel, fileId: String) {
        guard let file = model.snapshot.files[fileId] else { return nil }
        self.fileId = fileId
        itemId = file.itemId
        fileURL = model.fileURL(file)
        var colors: [AnnotationTool: String] = [:]
        for tool in AnnotationTool.allCases {
            if let key = model.settings.annotationToolColors[tool.key] { colors[tool] = key }
        }
        state = ReaderState(colors: colors, customColors: model.settings.annotationCustomColors,
                            eraserSize: InkEraser.Size(rawValue: model.settings.readerEraserSize) ?? .medium)
        editor = AnnotationEditor(state: state)
        content = ReaderContentViewController(pdfView: pdfView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.tabbingIdentifier = LibraryWindowController.tabbingIdentifier
        window.tabbingMode = .preferred
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setAccessibilityIdentifier("readerWindow")
        super.init(model: model, window: window)
        configurePDFView()
        buildSplit()
        configureToolbar()
        guard loadDocument() else { return nil }
        window.representedURL = fileURL
        updateTitle()
        startObserving()
        configureScanBanner()
        content.readOffer.accept = { [weak self] in
            guard let self else { return }
            self.model.setReadStatus(.read, on: [self.itemId])
        }
    }

    // MARK: Scans (OCR-01)

    /// A scan without text gets a banner offering to recognise it; the file is reloaded once that is done.
    private func configureScanBanner() {
        let banner = content.scanBanner
        banner.recognize = { [weak self] in
            guard let self else { return }
            self.model.ocr.recognize(fileId: self.fileId)
        }
        banner.cancel = { [weak self] in
            guard let self else { return }
            self.model.ocr.cancel(fileId: self.fileId)
        }
        banner.dismiss = { banner.dismissed = true }
        observers.append(ObservationLoop { [weak self] in
            guard let self else { return }
            let progress = self.model.ocr.jobs[self.fileId]
            if banner.progress != progress { banner.progress = progress }
        })
        NotificationCenter.default.addObserver(self, selector: #selector(fileRecognized(_:)), name: .folioFileRecognized, object: nil)
        checkIfScanned()
    }

    @objc private func fileRecognized(_ notification: Notification) {
        guard notification.userInfo?["fileId"] as? String == fileId else { return }
        reloadIfChangedOnDisk()
        content.scanBanner.isScan = false
    }

    private func checkIfScanned() {
        Task { [weak self] in
            guard let self else { return }
            let scan = await self.model.ocr.isScanned(fileId: self.fileId)
            self.content.scanBanner.isScan = scan
        }
    }

    @objc func recognizeText(_ sender: Any?) {
        model.ocr.recognize(fileId: fileId)
    }

    // MARK: Editing the PDF's text (EDIT-01)

    var isEditingPDFText: Bool { textEditMode != nil }
    var textEditState: String { textEditMode?.stateDescription ?? "off" }

    @objc func toggleTextEditing(_ sender: Any?) {
        if let mode = textEditMode {
            mode.finish()
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; mode.animator().alphaValue = 0 }, completionHandler: { mode.removeFromSuperview() })
            textEditMode = nil
            pdfView.editLayer = nil
            window?.invalidateCursorRects(for: pdfView)
            updateEditItem()
            return
        }
        // Annotations waiting to be saved go into the file first: the editor reads the file.
        guard save() else { return }
        state.tool = .select
        pdfView.selectAnnotation(nil)
        pdfView.clearSelection()
        let mode = PDFTextEditMode(pdfView: pdfView)
        mode.data = { [weak self] in self.flatMap { try? Data(contentsOf: $0.fileURL, options: .alwaysMapped) } }
        mode.commit = { [weak self] data, page, name in self?.applyEdit(data, page: page, actionName: name) ?? false }
        mode.showMessage = { [weak self] text in self?.model.toasts.show(text, systemImage: "square.and.pencil") }
        mode.alphaValue = 0
        mode.attach()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; mode.animator().alphaValue = 1 }
        textEditMode = mode
        pdfView.editLayer = mode
        mode.reload()
        updateEditItem()
    }

    /// The edit layer, for the self-test.
    var selfTestEditLayer: PDFTextEditMode? { textEditMode }

    private func updateEditItem() {
        textEditItem?.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: textEditItem?.label)
        if #available(macOS 26, *) { textEditItem?.style = isEditingPDFText ? .prominent : .plain }
    }

    /// Writes an edit of page `page` into the file and shows that page again (the rest of the document stays as it is
    /// on screen); undo puts the file as it was.
    private func applyEdit(_ data: Data, page: Int, actionName: String) -> Bool {
        guard let old = try? Data(contentsOf: fileURL) else { return false }
        guard write(data, page: page) else { return false }
        window?.undoManager?.registerUndo(withTarget: self) { $0.restoreEdit(old, redo: data, page: page, actionName: actionName) }
        window?.undoManager?.setActionName(actionName)
        return true
    }

    private func restoreEdit(_ data: Data, redo: Data, page: Int, actionName: String) {
        guard write(data, page: page) else { return }
        window?.undoManager?.registerUndo(withTarget: self) { $0.restoreEdit(redo, redo: data, page: page, actionName: actionName) }
        window?.undoManager?.setActionName(actionName)
        textEditMode?.pageChanged(page)
    }

    /// The file replaced atomically by `data`, in which only page `page` changed: that page is shown again in place (no
    /// reload of the document, no jump).
    private func write(_ data: Data, page: Int) -> Bool {
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            model.toasts.show(String(localized: "无法保存修改：\(error.localizedDescription)"), systemImage: "exclamationmark.triangle")
            return false
        }
        isDirty = false
        knownModificationDate = Self.modificationDate(fileURL)
        if !swapPage(page, from: data) { reloadKeepingPlace() }
        model.importer.refreshChangedFiles()
        return true
    }

    /// Page `index` of the document on screen replaced by the same page of `data`, where the reader is.
    private func swapPage(_ index: Int, from data: Data) -> Bool {
        guard let document = pdfView.document, let fresh = PDFDocument(data: data), fresh.pageCount == document.pageCount else { return false }
        fresh.delegate = self
        guard let page = fresh.page(at: index), let old = document.page(at: index) else { return false }
        let destination = pdfView.currentDestination
        let destinationIndex = destination?.page.map { document.index(for: $0) }
        let point = destination?.point
        let scale = pdfView.scaleFactor, autoScales = pdfView.autoScales
        let wasCurrent = pdfView.currentPage === old
        document.removePage(at: index)
        document.insert(page, at: index)
        if autoScales { pdfView.autoScales = true } else { pdfView.scaleFactor = scale }
        if let destinationIndex, let point, let target = document.page(at: destinationIndex) {
            pdfView.go(to: PDFDestination(page: target, at: point))
        } else if wasCurrent {
            pdfView.go(to: page)
        }
        refreshAnnotationRows()
        return true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    // MARK: Setup

    private func configurePDFView() {
        pdfView.editor = editor
        editor.pdfView = pdfView
        pdfView.displaysPageBreaks = true
        pdfView.pageShadowsEnabled = model.settings.readerPageShadows
        editor.author = model.settings.annotationAuthor
        pdfView.setAccessibilityIdentifier("readerPDFView")
        editor.onChange = { [weak self] in self?.documentChanged() }
        editor.onAddToNote = { [weak self] text, page in self?.addToNote(text, pageIndex: page) }
        editor.onCopyAsCitation = { [weak self] text, page in self?.copyAsCitation(text, pageIndex: page) }
        editor.onMixColor = { [weak self] annotation in
            guard let self else { return }
            self.colorPanel.show(initial: AnnotationEditor.color(of: annotation).withAlphaComponent(1)) { [weak self] color in
                self?.editor.mixed(color, for: annotation)
            }
        }
        editor.onRememberColor = { [weak self] color in self?.remember(custom: color) }
        // The text box's bar: the next box is written the same way.
        editor.onTextStyle = { [weak self] color, size in
            guard let self else { return }
            if let color {
                self.state.colors[.text] = color.key
                self.model.settings.annotationToolColors[AnnotationTool.text.key] = color.key
            }
            if let size { self.model.settings.textBoxFontSize = Double(size) }
        }
        editor.onTranslateSelection = { [weak self] in self?.selectionTranslation.translateCurrentSelection() }
        selectionTranslation = SelectionTranslationController(model: model, pdfView: pdfView)
        selectionTranslation.onAddToNote = { [weak self] source, translation, page in
            self?.addTranslationToNote(source: source, translation: translation, pageIndex: page)
        }
        pdfView.onMouseDown = { [weak self] in self?.selectionTranslation.mouseWentDown() }
        pdfView.onSelectionFinished = { [weak self] in self?.selectionTranslation.selectionFinished() }
        pdfView.eraserSizeMenu = { [weak self] in self?.eraserSizeMenu() }
        pdfView.onEraserSizeStep = { [weak self] step in self?.stepEraserSize(by: step) }
        pdfView.onLeaveEditing = { [weak self] in if self?.isEditingPDFText == true { self?.toggleTextEditing(nil) } }
        // 划词翻译's shortcut, while this reader is the key window.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, self.model.settings.selectionTranslationEnabled,
                  self.model.settings.selectionTranslationShortcut.matches(event),
                  !(self.window?.firstResponder is NSTextView) else { return event }
            return self.selectionTranslation.translateCurrentSelection() ? nil : event
        }
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged(_:)), name: .PDFViewPageChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged(_:)), name: .PDFViewScaleChanged, object: pdfView)
    }

    private func buildSplit() {
        let sidebar = NSHostingController(rootView: ReaderSidebarView(state: state, pdfView: pdfView, actions: sidebarActions))
        sidebarItem = NSSplitViewItem(sidebarWithViewController: PaneContainerController(child: sidebar, edge: .leading))
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = true
        let main = NSSplitViewItem(viewController: content)
        main.minimumThickness = 360
        notesHost = NSHostingController(rootView: ReaderNotesPanel(model: model, itemId: itemId, focusRequest: 0, choice: notesChoice))
        notesPane = PaneContainerController(child: notesHost, edge: .trailing)
        notesPane.backdrop.baseColor = .windowBackgroundColor
        notesPane.backdrop.drawsBlur = false
        notesItem = NSSplitViewItem(inspectorWithViewController: notesPane)
        notesItem.minimumThickness = 260
        notesItem.maximumThickness = 480
        notesItem.canCollapse = true
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(main)
        split.addSplitViewItem(notesItem)
        // The panel's document menu and its 在标签页中打开 button are in the toolbar above it, there while it is open.
        notesCollapseObservation = notesItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateNotesToolbarItems() }
        }
        // The pages keep their scale while the panes beside them slide, and fit the new width at the end.
        split.onFloatingInspectorMade = { [weak self] panel in
            guard let self else { return }
            let menu = NSHostingView(rootView: ItemDocumentsMenu(model: self.model, itemId: self.itemId, choice: self.notesChoice, titleFont: Self.notesMenuFont))
            let open = FloatingInspector.iconButton("arrow.up.left.and.arrow.down.right", String(localized: "在标签页中打开"), target: self, action: #selector(self.openNotesDocumentInTab(_:)))
            menu.safeAreaRegions = []
            panel.setHeader(leading: menu, trailing: FloatingInspector.toolbarItem(open, fixedWidth: 36))
        }
        split.onFloatingInspectorChanged = { [weak self] in self?.updateNotesToolbarItems() }
        split.onAnimationBegan = { [weak self] in self?.content.holdScale() }
        split.onAnimationEnded = { [weak self] in self?.content.releaseScale() }
        window?.contentViewController = split
        window?.setContentSize(NSSize(width: 1200, height: 860))
        if !UserDefaults.standard.bool(forKey: "FolioUITesting") { split.splitView.autosaveName = "FolioReaderSplit" }
    }

    private var sidebarActions: ReaderSidebarActions {
        ReaderSidebarActions(
            goToPage: { [weak self] index, point in
                guard let self, let page = self.pdfView.document?.page(at: index) else { return }
                if let point { self.pdfView.go(to: PDFDestination(page: page, at: point)) } else { self.pdfView.go(to: page) }
            },
            showAnnotation: { [weak self] id in self?.showAnnotation(id) },
            deleteAnnotation: { [weak self] id in self?.deleteAnnotation(id) },
            showHit: { [weak self] index in self?.showHit(index) })
    }

    private func startObserving() {
        observers.append(ObservationLoop { [weak self] in
            guard let self else { return }
            // The paper may be trashed, purged or merged into another item while open.
            guard let file = self.model.snapshot.files[self.fileId],
                  let item = self.model.snapshot.items[file.itemId], !item.isTrashed else {
                DispatchQueue.main.async { self.close() }
                return
            }
            if file.itemId != self.itemId {
                self.itemId = file.itemId
                self.notesChoice.fileId = ""
                self.notesHost.rootView = ReaderNotesPanel(model: self.model, itemId: file.itemId, focusRequest: self.notesFocusRequest, choice: self.notesChoice)
                self.notesMenuHost?.rootView = ItemDocumentsMenu(model: self.model, itemId: file.itemId, choice: self.notesChoice, titleFont: Self.notesMenuFont)
            }
            let job = self.model.translations.jobs[file.itemId]
            self.followTranslation(job, finished: self.translationFile)
            let url = self.model.fileURL(file)
            if url != self.fileURL {
                self.fileURL = url
                self.window?.representedURL = url
            }
            self.updateTitle()
        })
        observers.append(ObservationLoop { [weak self] in
            guard let self else { return }
            let tool = self.state.tool
            self.pdfView.tool = tool
            _ = self.state.colors
            self.pdfView.inkColor = self.state.color(for: .ink).nsColor
            self.pdfView.noteColor = self.state.color(for: .note).nsColor
            self.pdfView.inkWidth = CGFloat(self.model.settings.inkLineWidth)
            self.editor.textSize = CGFloat(self.model.settings.textBoxFontSize)
            self.editor.returnsToSelect = self.model.settings.returnToSelectAfterPlacing
            self.pdfView.showsTooltips = self.model.settings.showAnnotationTooltips
            self.pdfView.eraserSize = self.state.eraserSize
            self.updateToolImages()
        })
        observers.append(ObservationLoop { [weak self] in
            guard let self else { return }
            let amount = self.model.settings.backgroundTranslucency
            self.split.translucency = amount
            self.notesPane.backdrop.amount = amount
            self.split.floatsInspector = self.model.settings.inspectorFloating
            self.content.setTranslucency(amount)
        })
    }

    // MARK: Document

    /// Saving annotations would take the text recognised by an earlier version with it (PDFKit before macOS 27).
    private static func safeToSave(_ data: Data) -> Data {
        if #available(macOS 27, *) { return data }
        return OCRTextLayer.safeToSave(data) ?? data
    }

    /// Reads the file into memory (mapped), so atomic saves can replace it underneath safely.
    private func loadDocument() -> Bool {
        guard let data = try? Data(contentsOf: fileURL, options: .alwaysMapped), let document = PDFDocument(data: Self.safeToSave(data)) else {
            model.toasts.show(String(localized: "无法打开「\(fileURL.lastPathComponent)」：不是有效的 PDF"), systemImage: "exclamationmark.triangle")
            return false
        }
        // Pages become ReaderPage (selection outline) and find results come back here.
        document.delegate = self
        pdfView.document = document
        knownModificationDate = Self.modificationDate(fileURL)
        state.pageCount = document.pageCount
        state.outline = Self.outlineRows(document.outlineRoot)
        // The page last used; a paper without a table of contents shows its pages instead (not remembered as a choice).
        if state.outline.isEmpty, state.sidebarTab == .outline {
            let remembered = ReaderSidebarTab.remembered
            state.sidebarTab = .thumbnails
            ReaderSidebarTab.remembered = remembered
        }
        refreshAnnotationRows()
        // Notes, text boxes and ink an earlier build saved with an empty picture: drawn anew into the file at once.
        if AppearanceRepair.repair(document) > 0 { documentChanged() }
        return true
    }

    /// Restores the reading position once the view has its final size (READER-06).
    func restorePosition() {
        guard !restoredPosition, let document = pdfView.document else { return }
        restoredPosition = true
        // Scrolling within a page (down the last one) does not change the page.
        if let clip = pdfView.documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged(_:)), name: NSView.boundsDidChangeNotification, object: clip)
        }
        // The notes panel starts hidden unless a saved layout says otherwise. (Setting this before the
        // first layout has no effect.)
        if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames FolioReaderSplit") == nil {
            notesItem.isCollapsed = true
        }
        DispatchQueue.main.async { [weak self] in self?.updateNotesToolbarItems() }
        if document.isLocked { unlockDocument() }
        let settings = model.settings
        // 设置 ▸ 阅读 ▸ 记住每篇论文的阅读位置 off: every paper opens at its top, at the usual zoom.
        if model.settings.rememberReadingPosition, let saved = try? model.library.readingState(fileId: fileId),
           let page = document.page(at: min(saved.pageIndex, document.pageCount - 1)) {
            pdfView.displayMode = PDFDisplayMode(rawValue: saved.displayMode) ?? .singlePageContinuous
            if saved.autoScale {
                pdfView.autoScales = true
            } else {
                pdfView.autoScales = false
                pdfView.scaleFactor = saved.scale
            }
            pdfView.layoutDocumentView()
            if pendingPageIndex == nil {
                pdfView.go(to: PDFDestination(page: page, at: NSPoint(x: saved.pointX, y: saved.pointY)))
            }
        } else {
            pdfView.displayMode = settings.readerLayout == .twoUp ? .twoUpContinuous : .singlePageContinuous
            if settings.readerZoom == .actualSize {
                pdfView.autoScales = false
                pdfView.scaleFactor = 1
            } else {
                pdfView.autoScales = true
            }
        }
        if let index = pendingPageIndex, let page = document.page(at: index) {
            pendingPageIndex = nil
            pdfView.layoutDocumentView()
            pdfView.go(to: page)
        }
        updateTitle()
    }

    func show(pageIndex: Int) {
        guard restoredPosition else {
            pendingPageIndex = pageIndex
            return
        }
        if let page = pdfView.document?.page(at: pageIndex) { pdfView.go(to: page) }
    }

    private func unlockDocument() {
        guard let window, let document = pdfView.document else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "这份 PDF 受密码保护")
        alert.informativeText = String(localized: "输入密码以打开「\(window.title)」。")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "打开"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            if !document.unlock(withPassword: field.stringValue) {
                self?.model.toasts.show(String(localized: "密码不正确"), systemImage: "lock")
                self?.unlockDocument()
            }
        }
    }

    // MARK: Saving annotations (READER-05)

    private func documentChanged() {
        isDirty = true
        window?.isDocumentEdited = true
        refreshAnnotationRows()
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Writes the document next to the file and swaps it in atomically. Returns false on failure.
    @discardableResult
    func save() -> Bool {
        saveTask?.cancel()
        guard isDirty, let document = pdfView.document else { return true }
        let temp = fileURL.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).folio-saving.pdf")
        guard document.write(to: temp) else {
            try? FileManager.default.removeItem(at: temp)
            model.toasts.show(String(localized: "无法保存批注：写入文件失败"), systemImage: "exclamationmark.triangle")
            return false
        }
        do {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            model.toasts.show(String(localized: "无法保存批注：\(error.localizedDescription)"), systemImage: "exclamationmark.triangle")
            return false
        }
        isDirty = false
        window?.isDocumentEdited = false
        knownModificationDate = Self.modificationDate(fileURL)
        // Fingerprint, full-text index and the inspector's annotation list follow the file (FILE-08).
        model.importer.refreshChangedFiles()
        return true
    }

    /// Picks up edits made in another app (e.g. Preview) while this tab was in the background.
    private func reloadIfChangedOnDisk() {
        guard !isDirty, let date = Self.modificationDate(fileURL), date != knownModificationDate else { return }
        reloadKeepingPlace()
        textEditMode?.reload()
    }

    /// The file read again, on the same page and at the same place and zoom.
    private func reloadKeepingPlace() {
        let destination = pdfView.currentDestination
        let scale = pdfView.scaleFactor, autoScales = pdfView.autoScales, mode = pdfView.displayMode
        guard loadDocument() else { return }
        pdfView.displayMode = mode
        if autoScales { pdfView.autoScales = true } else { pdfView.scaleFactor = scale }
        if let destination, let index = destination.page.flatMap({ $0.document?.index(for: $0) }),
           let page = pdfView.document?.page(at: index) {
            pdfView.go(to: PDFDestination(page: page, at: destination.point))
        }
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: Reading position (READER-06)

    @objc private func pageChanged(_ notification: Notification) {
        updateTitle()
        content.syncParallel(from: pdfView)
        schedulePositionSave()
    }

    @objc private func scaleChanged(_ notification: Notification) { schedulePositionSave() }

    func schedulePositionSave() {
        guard restoredPosition else { return }
        positionTask?.cancel()
        positionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.noteSeenPages()
            self?.savePosition()
        }
    }

    var offersMarkAsRead: Bool { content.readOffer.isShown }
    /// Where 标为已读 is in the window (its button is the part of the capsule between the words and the close mark).
    func readOfferButtonPoint() -> NSPoint? { content.readOfferPoint() }
    func acceptMarkAsRead() { content.readOffer.accept(); content.readOffer.isShown = false }

    /// The pages of the paper that were on screen for a moment, this time and before.
    private var seenPages: SeenPages?

    /// The pages on screen now count as seen. At the end of a paper most of which was seen, the reader offers to mark it read:
    /// jumping to the last page for its references is not reading it.
    private func noteSeenPages() {
        guard let document = pdfView.document else { return }
        if seenPages?.flags.count != document.pageCount {
            let saved = try? model.library.readingState(fileId: fileId)
            let known = saved?.pageCount == document.pageCount || saved?.pageCount == nil
            seenPages = SeenPages(count: document.pageCount, saved: known ? saved?.seenPages : nil, through: saved?.pageIndex)
        }
        // Only in a tab that is in front, and only pages that really show: not the top of the next one.
        guard window?.isVisible == true else { return }
        let visible = pdfView.visiblePages.filter { page in
            let box = pdfView.convert(page.bounds(for: pdfView.displayBox), from: page)
            let shown = box.intersection(pdfView.bounds)
            return !shown.isNull && (shown.height > box.height * 0.5 || shown.height > pdfView.bounds.height * 0.5)
        }.map { document.index(for: $0) }
        for page in visible { seenPages?.insert(page) }
        guard model.settings.offerMarkAsRead, !content.readOffer.wasOffered, document.pageCount > 1, visible.contains(document.pageCount - 1),
              seenPages?.reached == document.pageCount - 1, model.snapshot.items[itemId]?.readStatus == .reading else { return }
        content.readOffer.wasOffered = true
        content.readOffer.isShown = true
    }

    func savePosition() {
        positionTask?.cancel()
        guard restoredPosition, let page = pdfView.currentPage, let index = pdfView.document?.index(for: page) else { return }
        // currentDestination can name the page above when only its bottom margin is still visible;
        // the visible page is what the reader expects to come back to.
        let destination = pdfView.currentDestination
        let point = destination?.page === page ? destination!.point : NSPoint(x: 0, y: page.bounds(for: pdfView.displayBox).maxY)
        let state = ReadingState(fileId: fileId, pageIndex: index, pointX: point.x, pointY: point.y,
                                 scale: pdfView.scaleFactor, autoScale: pdfView.autoScales,
                                 displayMode: pdfView.displayMode.rawValue,
                                 pageCount: pdfView.document?.pageCount, seenPages: seenPages?.stored)
        // Nothing seen for long enough yet (the paper was closed at once): what was known stays.
        guard seenPages != nil else {
            var kept = state
            let saved = try? model.library.readingState(fileId: fileId)
            kept.pageCount = saved?.pageCount ?? pdfView.document?.pageCount
            kept.seenPages = saved == nil ? "" : saved?.seenPages
                ?? SeenPages(count: kept.pageCount ?? 0, through: saved?.pageIndex).stored
            try? model.library.saveReadingState(kept)
            return
        }
        try? model.library.saveReadingState(state)
        model.reloadReadingProgress()
    }

    // MARK: Title and annotation list

    private func updateTitle() {
        guard let window else { return }
        let item = model.snapshot.items[itemId]
        window.title = item?.title ?? fileURL.lastPathComponent
        if let page = pdfView.currentPage, let index = pdfView.document?.index(for: page) {
            state.pageIndex = index
            let label = page.label.flatMap { $0 == String(index + 1) ? nil : String(localized: "（\($0)）") } ?? ""
            var subtitle = String(localized: "第 \(index + 1) / \(state.pageCount) 页\(label)")
            window.subtitle = subtitle
        }
        // Translation progress of this paper (TRANS-04).
        content.showTranslation(model.translations.jobs[itemId])
        if let file = model.snapshot.files[fileId] {
            let files = model.snapshot.files(of: itemId)
            window.tab.title = FileLabel.tabTitle(of: file, item: item, among: files)
            window.tab.toolTip = FileLabel.tabToolTip(of: file, item: item, among: files)
            // A translation's kind, which the title leaves to it: the paper's name has the room.
            if let symbol = FileLabel.tabSymbol(of: file) {
                let icon = (window.tab.accessoryView as? NSImageView) ?? NSImageView()
                icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: file.translationKind.map(FileLabel.kindName))?
                    .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
                icon.contentTintColor = .secondaryLabelColor
                icon.toolTip = window.tab.toolTip
                if window.tab.accessoryView !== icon { window.tab.accessoryView = icon }
            } else if window.tab.accessoryView != nil {
                window.tab.accessoryView = nil
            }
        } else {
            window.tab.title = fileURL.lastPathComponent
            window.tab.toolTip = window.title
        }
    }

    private func refreshAnnotationRows() {
        guard let document = pdfView.document else { return }
        var rows: [AnnotationRow] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations {
                guard let type = annotation.type, ReaderPDFView.editableTypes.contains(type) else { continue }
                let isMarkup = ["Highlight", "Underline", "StrikeOut", "Squiggly"].contains(type)
                rows.append(AnnotationRow(id: ObjectIdentifier(annotation), pageIndex: index,
                                          kind: Self.kindName(type), color: annotation.color,
                                          text: isMarkup ? AnnotationEditor.text(of: annotation) ?? "" : annotation.contents ?? "",
                                          comment: isMarkup ? annotation.contents ?? "" : "",
                                          isOffPage: !annotation.bounds.insetBy(dx: 1, dy: 1).intersects(page.bounds(for: .cropBox))))
            }
        }
        state.annotations = rows
    }

    private static func kindName(_ type: String) -> String {
        switch type {
        case "Highlight": String(localized: "高亮")
        case "Underline": String(localized: "下划线")
        case "StrikeOut": String(localized: "删除线")
        case "Squiggly": String(localized: "波浪线")
        case "Text": String(localized: "便签")
        case "FreeText": String(localized: "文本框")
        case "Ink": String(localized: "手绘")
        default: String(localized: "图形")
        }
    }

    /// Deleted from the list (one undo step, as with ⌫ on the page): also what can't be reached on the page.
    private func deleteAnnotation(_ id: ObjectIdentifier) {
        guard let document = pdfView.document else { return }
        for index in 0..<document.pageCount {
            guard let annotation = document.page(at: index)?.annotations.first(where: { ObjectIdentifier($0) == id }) else { continue }
            if pdfView.selectedAnnotation === annotation { pdfView.selectAnnotation(nil) }
            editor.remove(annotation)
            return
        }
    }

    private func showAnnotation(_ id: ObjectIdentifier) {
        guard let document = pdfView.document else { return }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index),
                  let annotation = page.annotations.first(where: { ObjectIdentifier($0) == id }) else { continue }
            pdfView.go(to: PDFDestination(page: page, at: NSPoint(x: annotation.bounds.minX, y: annotation.bounds.maxY + 40)))
            editor.resetTool()
            pdfView.selectAnnotation(annotation)
            return
        }
    }

    /// The place on the page a bookmark leads to: its top (and left, when given), as `/XYZ` destinations say.
    /// Nil for destinations of a whole page (`/Fit`, `/XYZ` without a top), which go to the page as before.
    static func outlinePoint(_ destination: PDFDestination) -> CGPoint? {
        let unspecified = CGFloat(kPDFDestinationUnspecifiedValue)
        let point = destination.point
        guard point.y != unspecified, point.y.isFinite, let page = destination.page else { return nil }
        let bounds = page.bounds(for: .cropBox)
        let x = point.x == unspecified || !point.x.isFinite ? bounds.minX : point.x
        return CGPoint(x: x, y: point.y)
    }

    private static func outlineRows(_ outline: PDFOutline?) -> [OutlineRow] {
        guard let outline else { return [] }
        var counter = 0
        func rows(_ node: PDFOutline) -> [OutlineRow] {
            (0..<node.numberOfChildren).compactMap { index in
                guard let child = node.child(at: index) else { return nil }
                counter += 1
                // A bookmark's target is its destination, or the destination of its GoTo action.
                let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination
                let page = destination?.page.flatMap { $0.document?.index(for: $0) }
                let children = rows(child)
                return OutlineRow(id: counter, title: child.label ?? "—", pageIndex: page,
                                  point: destination.flatMap(Self.outlinePoint), children: children.isEmpty ? nil : children)
            }
        }
        return rows(outline)
    }

    // MARK: Notes (READER-08)

    private func addToNote(_ text: String, pageIndex: Int) {
        let quote = text.split(separator: "\n").map { "> \($0)" }.joined(separator: "\n")
        model.appendToNote(itemId: itemId, String(localized: "\(quote)\n> —— 第 \(pageIndex + 1) 页"))
        showNotes()
    }

    /// Preview hook: selects `text` and shows 划词翻译 for it.
    /// -FolioPreviewAnnotations: the reader's annotations as they look, on the cloned library's paper — markup in
    /// several colours over `phrases` (page 1), a written note and a text box, then `open` (note / text) being written.
    /// Preview hook (-FolioPreviewClickTools <log>): clicks the 高亮 tool on the toolbar twice with events sent to this
    /// window only (the pointer does not move), and logs the tool chosen after each click and whether its menu opened.
    func previewClickTools(log: String) {
        guard let window, let bar = Self.toolbarView(in: window) else { return }
        func controls(_ view: NSView) -> [NSSegmentedControl] { ((view as? NSSegmentedControl).map { [$0] } ?? []) + view.subviews.flatMap(controls) }
        guard let control = controls(bar).first(where: { $0.segmentCount == AnnotationTool.allCases.count }) else {
            try? "no tools control".write(toFile: log, atomically: true, encoding: .utf8); return
        }
        var lines: [String] = []
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
            guard let menu = note.object as? NSMenu, menu.supermenu == nil else { return }
            lines.append("menu opened: " + menu.items.prefix(4).map(\.title).joined(separator: " | "))
            menu.perform(#selector(NSMenu.cancelTracking), with: nil, afterDelay: 0.3)
        }
        let segment = control.bounds.width / CGFloat(control.segmentCount)
        let point = control.convert(NSPoint(x: segment * 1.5, y: control.bounds.midY), to: nil)
        func click() {
            let time = ProcessInfo.processInfo.systemUptime
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
                                                     context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { continue }
                NSApp.postEvent(event, atStart: false)
            }
        }
        lines.append("before: \(state.tool)")
        click()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            lines.append("after first click: \(state.tool)")
            click()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                lines.append("after second click: \(state.tool)")
                NotificationCenter.default.removeObserver(observer)
                try? lines.joined(separator: "\n").write(toFile: log, atomically: true, encoding: .utf8)
            }
        }
    }

    func previewAnnotations(open: String) {
        guard let document = pdfView.document, let page = document.page(at: 0) else { return }
        let marks: [(String, AnnotationTool, AnnotationColor)] = [
            ("Curvilinear structure segmentation is essential", .highlight, .yellow),
            ("prompt-free", .highlight, .green),
            ("few-shot training", .underline, .red),
            ("cross-domain generalization", .highlight, .blue),
        ]
        for (phrase, tool, color) in marks {
            guard let selection = document.findString(phrase, withOptions: .caseInsensitive).first, let type = tool.markupType else { continue }
            state.colors[tool] = color.rawValue
            editor.addMarkup(type, for: selection)
        }
        let box = page.bounds(for: .cropBox)
        state.colors[.note] = AnnotationColor.yellow.rawValue
        editor.place(.note, at: NSPoint(x: box.midX + 4, y: box.midY + 96), on: page)
        editor.previewType(String(localized: "和 SAM-Med2D 的适配器对比一下"))
        editor.finishCard()
        state.colors[.text] = AnnotationColor.red.rawValue
        editor.place(.text, at: NSPoint(x: box.minX + 52, y: box.maxY - 78), on: page)
        editor.previewType(String(localized: "重点：无需提示的曲线结构分割"))
        editor.finishTextBox()
        if open == "ink" || open.hasPrefix("erase") {
            let start = NSPoint(x: box.midX - 20, y: box.midY + 120)
            editor.addInk(points: (0...40).map { NSPoint(x: start.x + CGFloat($0) * 3, y: start.y + 8 * sin(CGFloat($0) / 4)) }, on: page)
        }
        pdfView.go(to: page)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
            if open == "noteshrink" || open == "notegrow" {
                state.colors[.note] = AnnotationColor.blue.rawValue
                editor.place(.note, at: NSPoint(x: box.maxX - 46, y: box.midY + 40), on: page)
                editor.previewType(String(localized: "Adapter-E 插在 Transformer 块之间，回头看实现细节。\n第二行：对比 SAM-Med2D。\n第三行：消融实验在表 3。\n第四行：代码在 GitHub。"))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                    // Smaller, then (notegrow) larger again, in small steps as a hand drags.
                    editor.previewDragCard(by: NSSize(width: -60, height: 60), steps: 12)
                    if open == "notegrow" { editor.previewDragCard(by: NSSize(width: 160, height: -220), steps: 20) }
                }
            } else if open == "note" {
                state.colors[.note] = AnnotationColor.blue.rawValue
                editor.place(.note, at: NSPoint(x: box.maxX - 46, y: box.midY + 40), on: page)
                editor.previewType(String(localized: "Adapter-E 插在 Transformer 块之间，回头看实现细节。"))
            } else if open.hasPrefix("erase") {
                // Scribbled over with the small eraser, back and forth along the stroke, as one does: what is left,
                // on the page, in the list and in the saved file.
                let start = NSPoint(x: box.midX - 20, y: box.midY + 120)
                state.eraserSize = .small
                state.tool = .eraser
                // "erasehalf": only the middle of the stroke, so a cut stroke is saved.
                let steps = open == "erasehalf" ? 80 : 240
                let first = open == "erasehalf" ? 80 : 0
                let track = (first...(first + steps)).map { k -> NSPoint in
                    let x = start.x - 6 + CGFloat(k) * 0.55
                    return NSPoint(x: x, y: start.y + 8 * sin((x - start.x) / 12) + (k % 2 == 0 ? 5 : -5))
                }
                pdfView.beginErasing(at: track[0], on: page)
                for point in track.dropFirst() { pdfView.continueErasing(to: point, on: page) }
                pdfView.endErasing()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                    let inks = page.annotations.filter { $0.type == "Ink" }
                    var lines = ["inks on page: \(inks.count) \(inks.map { "\(type(of: $0)) paths=\(($0.paths ?? []).map { "\($0.elementCount)@\($0.bounds)" })" })"]
                    lines.append("rows: \(state.annotations.map(\.kind))")
                    _ = save()
                    let saved = PDFDocument(url: fileURL)?.page(at: 0)?.annotations.map { $0.type ?? "?" } ?? []
                    lines.append("saved: \(saved)")
                    if let log = UserDefaults.standard.string(forKey: "FolioPreviewSnapshotLog") {
                        try? lines.joined(separator: "\n").write(toFile: log, atomically: true, encoding: .utf8)
                    }
                }
            } else if open == "text" {
                state.colors[.text] = AnnotationColor.blue.rawValue
                editor.place(.text, at: NSPoint(x: box.minX + 40, y: box.midY + 120), on: page)
                editor.previewType(String(localized: "这里的结论值得引用"))
            }
        }
    }

    /// Preview hook (-FolioPreviewMenuRender <dir>): the rows of the tools' menus, drawn to <dir>/<tool>-<n>.png.
    func previewRenderMenus(into directory: String) {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let look = NSAppearance(named: appearance)!
            let suffix = appearance == .aqua ? "light" : "dark"
            // Each tool's menu as it opens: its headers and rows, every row as wide as the menu.
            for tool in [AnnotationTool.highlight, .strikeOut, .ink, .text, .eraser] {
                guard let menu = toolMenu(for: tool) else { continue }
                let headerFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
                let width = menu.items.map { item in
                    item.view?.frame.width ?? (item.title as NSString).size(withAttributes: [.font: headerFont]).width + 28
                }.max() ?? 150
                let heights = menu.items.map { $0.isSeparatorItem ? 11 : ($0.view?.frame.height ?? 22) }
                let size = NSSize(width: width, height: heights.reduce(0, +) + 10)
                let image = NSImage(size: size, flipped: true) { _ in
                    look.performAsCurrentDrawingAppearance {
                        (appearance == .aqua ? NSColor(white: 0.97, alpha: 1) : NSColor(white: 0.17, alpha: 1)).setFill()
                        NSRect(origin: .zero, size: size).fill()
                        var y: CGFloat = 5
                        for (item, height) in zip(menu.items, heights) {
                            if item.isSeparatorItem {
                                NSColor.separatorColor.setFill()
                                NSRect(x: 14, y: y + 5, width: width - 28, height: 1).fill()
                            } else if let view = item.view {
                                view.appearance = look
                                view.setFrameSize(NSSize(width: width, height: view.frame.height))
                                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                                    view.cacheDisplay(in: view.bounds, to: rep)
                                    rep.draw(in: NSRect(x: 0, y: y, width: width, height: height), from: .zero, operation: .sourceOver,
                                             fraction: 1, respectFlipped: true, hints: nil)
                                }
                            } else {
                                (item.title as NSString).draw(at: NSPoint(x: 14, y: y + 4), withAttributes: [.font: headerFont, .foregroundColor: NSColor.secondaryLabelColor])
                            }
                            y += height
                        }
                    }
                    return true
                }
                Self.writePNG(image, scale: 2, to: "\(directory)/menu-\(tool.key)-\(suffix).png")
            }
            // The toolbar's tools, as the toolbar draws them.
            let tools = AnnotationTool.allCases
            let strip = NSImage(size: NSSize(width: CGFloat(tools.count) * 34 + 8, height: 34), flipped: false) { rect in
                look.performAsCurrentDrawingAppearance {
                    (appearance == .aqua ? NSColor(white: 0.95, alpha: 1) : NSColor(white: 0.2, alpha: 1)).setFill()
                    rect.fill()
                    for (index, tool) in tools.enumerated() {
                        let image = AnnotationToolImage.make(tool, color: tool.showsColorOnToolbar ? self.state.color(for: tool).nsColor : nil)
                        image.draw(in: NSRect(x: 8 + CGFloat(index) * 34 + (30 - image.size.width) / 2, y: (34 - image.size.height) / 2,
                                              width: image.size.width, height: image.size.height))
                    }
                }
                return true
            }
            Self.writePNG(strip, scale: 3, to: "\(directory)/toolbar-\(suffix).png")
        }
    }

    private static func writePNG(_ image: NSImage, scale: CGFloat, to path: String) {
        let width = Int(image.size.width * scale), height = Int(image.size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Preview hook (-FolioPreviewLayerDump <path>): zooms in on the first note, then writes the PDF view's layer tree
    /// (class, size, contents scale) to <path>.txt and the layers as they are rendered to <path>.png.
    func previewLayerDump(path: String) {
        guard let page = pdfView.document?.page(at: 0),
              let note = page.annotations.first(where: { $0 is NoteAnnotation }) ?? page.annotations.first(where: { $0 is InkAnnotation })
        else { try? "no note".write(toFile: path + ".txt", atomically: true, encoding: .utf8); return }
        pdfView.autoScales = false
        pdfView.scaleFactor = note is InkAnnotation ? 1.5 : 4
        pdfView.go(to: note.bounds.insetBy(dx: -40, dy: -40), on: page)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
            var lines: [String] = []
            func walk(_ layer: CALayer, _ depth: Int) {
                guard depth < 14, lines.count < 400 else { return }
                let t = layer.affineTransform()
                lines.append(String(repeating: "  ", count: depth) + "\(type(of: layer)) \(layer.name ?? "") bounds=\(Int(layer.bounds.width))x\(Int(layer.bounds.height)) scale=\(layer.contentsScale) t=\(String(format: "%.2f", t.a)) contents=\(Self.describeContents(of: layer)) delegate=\(layer.delegate.map { String(describing: type(of: $0)) } ?? "-")")
                for sub in layer.sublayers ?? [] { walk(sub, depth + 1) }
            }
            if let layer = pdfView.layer { walk(layer, 0) }
            func views(_ view: NSView, _ depth: Int) {
                lines.append("VIEW " + String(repeating: "  ", count: depth) + "\(type(of: view)) \(Int(view.frame.width))x\(Int(view.frame.height)) bounds=\(Int(view.bounds.width))x\(Int(view.bounds.height))")
                for sub in view.subviews where depth < 10 { views(sub, depth + 1) }
            }
            views(pdfView, 0)
            for index in 0..<min(pdfView.document?.pageCount ?? 0, 4) {
                for annotation in pdfView.document?.page(at: index)?.annotations ?? [] where annotation.type == "Ink" {
                    lines.append("INK page \(index) \(type(of: annotation)) bounds=\(annotation.bounds) width=\(annotation.border?.lineWidth ?? -1) color=\(annotation.color) paths=\((annotation.paths ?? []).map { "\($0.elementCount)@\($0.bounds)" })")
                }
            }
            try? lines.joined(separator: "\n").write(toFile: path + ".txt", atomically: true, encoding: .utf8)
            // The reader's own pictures, each at its own resolution.
            func pictures(_ layer: CALayer) -> [AnnotationPictureLayer] { ((layer as? AnnotationPictureLayer).map { [$0] } ?? []) + (layer.sublayers ?? []).flatMap(pictures) }
            for picture in pdfView.layer.map(pictures) ?? [] { lines.append("PICTURE frame=\(picture.frame) superlayer=\(picture.superlayer?.bounds ?? .zero) flipped=\(picture.superlayer?.isGeometryFlipped ?? false)") }
            for annotation in page.annotations { lines.append("ANNOTATION \(annotation.type ?? "") bounds=\(annotation.bounds)") }
            lines.append("PAGE media=\(page.bounds(for: .mediaBox)) crop=\(page.bounds(for: .cropBox))")
            try? lines.joined(separator: "\n").write(toFile: path + ".txt", atomically: true, encoding: .utf8)
            for (index, picture) in (pdfView.layer.map(pictures) ?? []).enumerated() {
                let scale = picture.contentsScale
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(picture.bounds.width * scale), pixelsHigh: Int(picture.bounds.height * scale),
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                      let context = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { continue }
                context.setFillColor(.white)
                context.fill(CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
                context.scaleBy(x: scale, y: scale)
                picture.render(in: context)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + "-picture\(index).png"))
            }
            if let layer = pdfView.layer, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(layer.bounds.width * 2), pixelsHigh: Int(layer.bounds.height * 2),
                                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
               let context = NSGraphicsContext(bitmapImageRep: rep)?.cgContext {
                context.scaleBy(x: 2, y: 2)
                layer.render(in: context)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + ".png"))
            }
        }
    }

    /// Preview hook: what a layer holds (an image: its size and how many of its pixels show).
    nonisolated private static func describeContents(of layer: CALayer) -> String {
        guard let contents = layer.contents else { return "none" }
        guard CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else {
            // A backing store: rendered, how many of its pixels show.
            let width = max(Int(layer.bounds.width), 1), height = max(Int(layer.bounds.height), 1)
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "store" }
            layer.render(in: context)
            guard let data = context.data else { return "store" }
            let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
            var shown = 0
            for index in 0..<(width * height) where bytes[index * 4 + 3] != 0 { shown += 1 }
            return "store shown=\(shown)/\(width * height)"
        }
        let image = contents as! CGImage
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return "image \(image.width)x\(image.height)" }
        var shown = 0
        let length = CFDataGetLength(data), step = max(image.bitsPerPixel / 8, 1)
        var index = 0
        while index + step <= length { if bytes[index + (image.alphaInfo == .premultipliedFirst || image.alphaInfo == .first ? 0 : step - 1)] != 0 { shown += 1 }; index += step }
        return "image \(image.width)x\(image.height) shown=\(shown)"
    }

    func previewSelectionTranslation(_ text: String, badgeOnly: Bool) {
        guard let selection = pdfView.document?.findString(text, withOptions: .caseInsensitive).first else { return }
        pdfView.setCurrentSelection(selection, animate: false)
        if let page = selection.pages.first { pdfView.go(to: selection.bounds(for: page), on: page) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            if badgeOnly { selectionTranslation.selectionFinished() } else { selectionTranslation.translateCurrentSelection() }
        }
    }

    private func addTranslationToNote(source: String, translation: String, pageIndex: Int) {
        let quote = source.split(separator: "\n").map { "> \($0)" }.joined(separator: "\n")
        model.appendToNote(itemId: itemId, String(localized: "\(quote)\n> —— 第 \(pageIndex + 1) 页") + "\n\n" + translation)
        showNotes()
    }

    private func copyAsCitation(_ text: String, pageIndex: Int) {
        var reference = ""
        if let item = model.snapshot.items[itemId], item.kind == .regular {
            let author = item.authors.first.map { item.authors.count > 1 ? "\($0.family) et al." : $0.family } ?? ""
            reference = [author, item.year.map(String.init)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        }
        let citation = reference.isEmpty ? "p. \(pageIndex + 1)" : "\(reference), p. \(pageIndex + 1)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(localized: "“\(text)”（\(citation)）"), forType: .string)
        model.toasts.show(String(localized: "已拷贝为引用"), systemImage: "quote.opening")
    }

    private func showNotes() {
        if !split.isInspectorOpen { split.setInspectorOpen(true) }
        notesFocusRequest += 1
        notesHost.rootView = ReaderNotesPanel(model: model, itemId: itemId, focusRequest: notesFocusRequest, choice: notesChoice)
    }

    override func editNote(itemId: String) { showNotes() }

    // MARK: Targets

    override var targetItemIds: [String] { [itemId] }
    override var targetFileId: String? { fileId }

    override func quickLook() {
        model.open(fileId: fileId, mode: .preview)
    }

    // MARK: Window delegate

    func windowDidBecomeKey(_ notification: Notification) {
        reloadIfChangedOnDisk()
    }

    func windowDidResignKey(_ notification: Notification) {
        save()
        savePosition()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finishWriting()
        guard !save() else { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "无法保存批注")
        alert.informativeText = String(localized: "关闭后，这次添加的批注会丢失。")
        alert.addButton(withTitle: String(localized: "取消"))
        alert.addButton(withTitle: String(localized: "仍然关闭"))
        alert.buttons[1].hasDestructiveAction = true
        alert.beginSheetModal(for: sender) { [weak self] response in
            if response == .alertSecondButtonReturn {
                self?.isDirty = false
                sender.close()
            }
        }
        return false
    }

    /// A text box being written, finished (quitting, closing).
    func finishWriting() { editor.finishTextBox() }

    func windowWillClose(_ notification: Notification) {
        finishWriting()
        savePosition()
        selectionTranslation.close()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        observers.forEach { $0.cancel() }
        model.readers.readerDidClose(self)
    }

    // MARK: Find (READER-03)

    @objc func focusSearch(_ sender: Any?) {
        searchItem?.beginSearchInteraction()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        find(field.stringValue)
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) { find("") }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            NSEvent.modifierFlags.contains(.shift) ? findPrevious(nil) : findNext(nil)
            return true
        }
        return false
    }

    private func find(_ text: String) {
        guard let document = pdfView.document else { return }
        document.cancelFindString()
        findHits = []
        state.searchHits = []
        state.currentHit = nil
        state.searchQuery = text
        pdfView.highlightedSelections = nil
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            state.isSearching = false
            return
        }
        state.isSearching = true
        state.sidebarTab = .search
        if sidebarItem.isCollapsed { split.setCollapsed(sidebarItem, false) }
        document.beginFindString(text, withOptions: [.caseInsensitive, .diacriticInsensitive])
    }

    nonisolated func classForPage() -> AnyClass { ReaderPage.self }
    /// Sticky notes, text boxes and ink are drawn by the reader (NoteAnnotation, TextBoxAnnotation, InkAnnotation, sharp
    /// on screen through CrispAnnotations); the rest is PDFKit's.
    nonisolated func `class`(forAnnotationType annotationType: String) -> AnyClass {
        switch annotationType {
        case "Text": NoteAnnotation.self
        case "FreeText": TextBoxAnnotation.self
        case "Ink": InkAnnotation.self
        default: PDFAnnotation.self
        }
    }

    nonisolated func didMatchString(_ instance: PDFSelection) {
        nonisolated(unsafe) let selection = instance
        MainActor.assumeIsolated { self.addHit(selection) }
    }

    nonisolated func documentDidEndDocumentFind(_ notification: Notification) {
        MainActor.assumeIsolated {
            state.isSearching = false
            if !findHits.isEmpty && state.currentHit == nil { showHit(0) }
        }
    }

    private func addHit(_ selection: PDFSelection) {
        guard let page = selection.pages.first, let index = pdfView.document?.index(for: page) else { return }
        findHits.append(selection)
        selection.color = .systemYellow.withAlphaComponent(0.5)
        pdfView.highlightedSelections = findHits
        let context = selection.copy() as! PDFSelection
        context.extend(atStart: 40)
        context.extend(atEnd: 60)
        var attributed = AttributedString(AnnotationEditor.clean(context.string ?? ""))
        if let range = attributed.range(of: selection.string ?? "", options: .caseInsensitive) {
            attributed[range].font = .body.bold()
        }
        state.searchHits.append(SearchHit(id: findHits.count - 1, pageIndex: index, pageLabel: page.label ?? "\(index + 1)",
                                          context: attributed))
    }

    private func showHit(_ index: Int) {
        guard findHits.indices.contains(index) else { return }
        state.currentHit = index
        pdfView.setCurrentSelection(findHits[index], animate: true)
        pdfView.scrollSelectionToVisible(nil)
    }

    @objc func findNext(_ sender: Any?) {
        guard !findHits.isEmpty else { return }
        showHit(((state.currentHit ?? -1) + 1) % findHits.count)
    }

    @objc func findPrevious(_ sender: Any?) {
        guard !findHits.isEmpty else { return }
        showHit(((state.currentHit ?? 0) - 1 + findHits.count) % findHits.count)
    }

    // MARK: Actions: view

    @objc func zoomIn(_ sender: Any?) { pdfView.zoomIn(sender) }
    @objc func zoomOut(_ sender: Any?) { pdfView.zoomOut(sender) }
    @objc func actualSize(_ sender: Any?) {
        pdfView.autoScales = false
        pdfView.scaleFactor = 1
    }
    @objc func zoomToFit(_ sender: Any?) { pdfView.autoScales = true }
    @objc func setSinglePage(_ sender: Any?) { pdfView.displayMode = .singlePageContinuous; schedulePositionSave() }
    @objc func setTwoPages(_ sender: Any?) { pdfView.displayMode = .twoUpContinuous; schedulePositionSave() }

    @objc func zoomFromToolbar(_ sender: Any?) {
        guard let group = sender as? NSToolbarItemGroup else { return }
        group.selectedIndex == 0 ? pdfView.zoomOut(nil) : pdfView.zoomIn(nil)
    }

    @objc func showReaderSidebarTab(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let tab = ReaderSidebarTab(rawValue: item.tag) else { return }
        state.sidebarTab = tab
        if sidebarItem.isCollapsed { split.setCollapsed(sidebarItem, false) }
    }

    /// 边翻边看: while this paper is being translated, 对照阅读 shows the pages done so far and follows new ones;
    /// when the translation is filed it switches to it.
    private func followTranslation(_ job: TranslationCoordinator.JobState?, finished: FileRecord?) {
        guard let shown = previewShown else { return }
        if let preview = job?.preview {
            if preview != shown {
                previewShown = preview
                content.replaceParallel(with: preview)
            }
        } else if job == nil {
            previewShown = nil
            if let finished {
                state.parallelFileId = finished.id
                content.replaceParallel(with: model.fileURL(finished))
            }
        }
    }

    /// The preview shown in 对照阅读 while the translation runs.
    private var previewShown: URL?

    var isShowingParallel: Bool { state.parallelFileId != nil || previewShown != nil }

    @objc func toggleParallelReading(_ sender: Any?) {
        if state.parallelFileId != nil || previewShown != nil {
            state.parallelFileId = nil
            previewShown = nil
            content.showParallel(nil)
            return
        }
        if translationFile == nil, let preview = model.translations.jobs[itemId]?.preview {
            previewShown = preview
            content.showParallel(preview)
            content.syncParallel(from: pdfView)
            return
        }
        guard let translation = translationFile else {
            model.toasts.show(String(localized: "这篇论文还没有译文。可以先\"翻译全文\""), systemImage: "character.book.closed")
            return
        }
        state.parallelFileId = translation.id
        content.showParallel(model.fileURL(translation))
        content.syncParallel(from: pdfView)
    }

    /// Screenshot-free check of 对照阅读: both panes visible and on the same page after paging.
    func logParallelState(to log: String) {
        let views = content.view.subviews.compactMap { $0 as? PDFView }
        var lines = ["panes: \(views.map { Int($0.frame.width) })"]
        pdfView.go(to: pdfView.document!.page(at: 0)!)
        pdfView.goToNextPage(nil)
        let pages = views.map { $0.currentPage.flatMap { $0.document?.index(for: $0) } ?? -1 }
        lines.append("pages after next: \(pages)")
        SimulatedDrop.append(lines.joined(separator: "\n") + "\n", to: log)
    }

    /// The translation to read side by side: the newest mono translation of this file, else a dual one.
    private var translationFile: FileRecord? {
        let files = model.snapshot.files.values.filter { $0.translationOf == fileId }.sorted { $0.dateAdded > $1.dateAdded }
        return files.first { $0.translationKind == .mono } ?? files.first
    }

    // MARK: Actions: navigation

    @objc func goToPreviousPage(_ sender: Any?) { pdfView.goToPreviousPage(sender) }
    @objc func goToNextPage(_ sender: Any?) { pdfView.goToNextPage(sender) }
    @objc func goToFirstPage(_ sender: Any?) { pdfView.goToFirstPage(sender) }
    @objc func goToLastPage(_ sender: Any?) { pdfView.goToLastPage(sender) }
    @objc func goBack(_ sender: Any?) { pdfView.goBack(sender) }
    @objc func goForward(_ sender: Any?) { pdfView.goForward(sender) }

    @objc func goToPageNumber(_ sender: Any?) {
        guard let window, let document = pdfView.document else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "前往页面")
        alert.informativeText = String(localized: "输入页码（1–\(document.pageCount)）")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.stringValue = "\(state.pageIndex + 1)"
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "前往"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespaces)
            // A page label ("iv", "S3") or a number.
            let page = (0..<document.pageCount).lazy.compactMap { document.page(at: $0) }.first { $0.label == text }
                ?? Int(text).flatMap { document.page(at: max(1, min($0, document.pageCount)) - 1) }
            if let page { self.pdfView.go(to: page) } else { NSSound.beep() }
        }
    }

    // MARK: Actions: annotations

    @objc func selectTool(_ sender: Any?) {
        let index = (sender as? NSMenuItem)?.tag ?? (sender as? NSToolbarItemGroup)?.selectedIndex ?? 0
        guard let tool = AnnotationTool(rawValue: index) else { return }
        // The tool already chosen, clicked again on the toolbar: its menu (colours, width, size).
        if sender is NSToolbarItemGroup, tool == state.tool, tool.hasToolbarMenu {
            showToolMenu(for: tool)
            return
        }
        // A tool ends 编辑 PDF 文字 and a text box being written: one thing at a time.
        if isEditingPDFText { toggleTextEditing(nil) }
        editor.finishTextBox()
        // Choosing a markup tool with text already selected marks that text right away.
        if let type = tool.markupType, let selection = pdfView.currentSelection, !(selection.string ?? "").isEmpty {
            editor.addMarkup(type, for: selection)
            pdfView.clearSelection()
        }
        state.tool = state.tool == tool && sender is NSMenuItem ? .select : tool
    }

    /// Shows a tool's menu under the toolbar, where the click was.
    private func showToolMenu(for tool: AnnotationTool) {
        guard let window, let menu = toolMenu(for: tool) else { return }
        let click = NSApp.currentEvent.map { $0.window === window ? $0.locationInWindow : nil } ?? nil
        // Just under the toolbar: the bottom of the window's title bar area.
        let toolbarBottom = Self.toolbarView(in: window).map { $0.convert($0.bounds, to: nil).minY } ?? window.contentLayoutRect.maxY
        let x = (click?.x ?? window.frame.width / 2) - 14
        let onScreen = window.convertPoint(toScreen: NSPoint(x: x, y: toolbarBottom - 4))
        menu.popUp(positioning: nil, at: onScreen, in: nil)
    }

    private static func toolbarView(in window: NSWindow) -> NSView? {
        func find(_ view: NSView) -> NSView? {
            if String(describing: type(of: view)) == "NSToolbarView" { return view }
            for child in view.subviews { if let hit = find(child) { return hit } }
            return nil
        }
        return window.contentView?.superview.flatMap(find)
    }

    /// The toolbar's tool images, each tool that shows its colour in its current one.
    private func updateToolImages() {
        guard let group = toolGroup else { return }
        group.selectedIndex = state.tool.rawValue
        for (index, tool) in AnnotationTool.allCases.enumerated() where group.subitems.indices.contains(index) {
            group.subitems[index].image = AnnotationToolImage.make(tool, color: tool.showsColorOnToolbar ? state.color(for: tool).nsColor : nil)
        }
    }

    /// A colour chosen in a tool's menu: the tool takes it (and is chosen), and the selected annotation, when that tool
    /// made it, is recoloured.
    private func choose(_ color: ToolColor, for tool: AnnotationTool) {
        state.colors[tool] = color.key
        model.settings.annotationToolColors[tool.key] = color.key
        if color.preset == nil { remember(custom: color) }
        if let annotation = pdfView.selectedAnnotation, AnnotationTool.forAnnotationType(annotation.type) == tool {
            editor.setColor(annotation, color.nsColor)
        } else if let type = tool.markupType, let selection = pdfView.currentSelection, !(selection.string ?? "").isEmpty {
            editor.addMarkup(type, for: selection)
            pdfView.clearSelection()
        }
        if isEditingPDFText { toggleTextEditing(nil) }
        state.tool = tool
    }

    /// A colour mixed in the colour panel joins the ones every tool offers (the newest five).
    func remember(custom color: ToolColor) {
        var list = state.customColors.filter { $0 != color.key }
        list.insert(color.key, at: 0)
        state.customColors = Array(list.prefix(5))
        model.settings.annotationCustomColors = state.customColors
    }

    /// The colour panel, for a tool's own colour.
    private func mixColor(for tool: AnnotationTool) {
        colorPanel.show(initial: state.color(for: tool).nsColor) { [weak self] color in
            self?.choose(ToolColor(color), for: tool)
        }
    }

    /// A tool's menu: its colours (the last circle mixes one's own), and the pen's width, the text size or the eraser's
    /// size, each shown as what it looks like.
    func toolMenu(for tool: AnnotationTool) -> NSMenu? {
        let menu = NSMenu()
        if tool == .eraser {
            menu.addItem(.sectionHeader(title: String(localized: "橡皮擦大小")))
            let sizes = InkEraser.Size.allCases
            // Rings in even steps (the sizes double, which would make the small one a speck beside the large one).
            let rings: [CGFloat] = [9, 14, 20]
            menu.addItem(.sizeRow(sizes.enumerated().map { .init(name: $1.title, kind: .ring(rings[min($0, rings.count - 1)])) },
                                  selected: sizes.firstIndex(of: state.eraserSize), label: String(localized: "橡皮擦大小")) {
                [weak self] index in self?.choose(sizes[index])
            })
            return menu
        }
        guard tool.hasColor else { return nil }
        let choices = state.choices(for: tool)
        let current = state.color(for: tool)
        menu.addItem(.sectionHeader(title: tool == .text ? String(localized: "文字颜色") : String(localized: "\(tool.title)颜色")))
        menu.addItem(.colorSwatches(choices.map { .init(name: $0.title, color: $0.nsColor) } + [.custom], selected: choices.firstIndex(of: current)) {
            [weak self] index in
            if index < choices.count { self?.choose(choices[index], for: tool) } else { self?.mixColor(for: tool) }
        })
        if tool == .ink {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: String(localized: "粗细")))
            let widths = AnnotationToolOptions.inkWidths
            let dots: [CGFloat] = [4, 7, 10, 14]
            menu.addItem(.sizeRow(widths.enumerated().map { .init(name: $1.title, kind: .dot(dots[min($0, dots.count - 1)], current.nsColor)) },
                                  selected: widths.firstIndex { $0.width == model.settings.inkLineWidth }, label: String(localized: "粗细")) {
                [weak self] index in
                self?.model.settings.inkLineWidth = widths[index].width
                self?.state.tool = .ink
            })
        }
        if tool == .text {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: String(localized: "字号")))
            let sizes = AnnotationToolOptions.textSizes
            menu.addItem(.sizeRow(sizes.map { .init(name: "\($0.title)（\(Int($0.size)) pt）", kind: .letter(CGFloat($0.size) - 1)) },
                                  selected: sizes.firstIndex { $0.size == model.settings.textBoxFontSize }, label: String(localized: "字号")) {
                [weak self] index in
                self?.model.settings.textBoxFontSize = sizes[index].size
                self?.state.tool = .text
            })
        }
        return menu
    }

    // MARK: Actions: eraser size (READER-30)

    @objc func selectEraserSize(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, InkEraser.Size.allCases.indices.contains(item.tag) else { return }
        choose(InkEraser.Size.allCases[item.tag])
    }

    /// A size is chosen to erase with: the eraser becomes the tool, and the size is remembered.
    private func choose(_ size: InkEraser.Size) {
        state.eraserSize = size
        model.settings.readerEraserSize = size.rawValue
        state.tool = .eraser
    }

    private func stepEraserSize(by step: Int) {
        let sizes = InkEraser.Size.allCases
        guard let index = sizes.firstIndex(of: state.eraserSize) else { return }
        choose(sizes[min(max(index + step, 0), sizes.count - 1)])
    }

    /// The eraser's sizes (right-click while erasing): the same plain list as its toolbar menu.
    private func eraserSizeMenu() -> NSMenu { toolMenu(for: .eraser) ?? NSMenu() }

    @objc func addSelectionToNote(_ sender: Any?) {
        if let selection = pdfView.currentSelection, let text = selection.string, !text.isEmpty {
            let index = selection.pages.first.flatMap { pdfView.document?.index(for: $0) } ?? state.pageIndex
            addToNote(AnnotationEditor.clean(text), pageIndex: index)
        } else if let annotation = pdfView.selectedAnnotation, let text = AnnotationEditor.text(of: annotation),
                  let page = annotation.page, let index = pdfView.document?.index(for: page) {
            addToNote(text, pageIndex: index)
        }
    }

    @objc func deleteSelectedAnnotation(_ sender: Any?) {
        if let annotation = pdfView.selectedAnnotation { editor.remove(annotation) }
    }

    @objc func delete(_ sender: Any?) { deleteSelectedAnnotation(sender) }

    @objc func printDocument(_ sender: Any?) {
        pdfView.print(with: NSPrintInfo.shared, autoRotate: true)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(selectTool(_:)):
            menuItem.state = state.tool.rawValue == menuItem.tag ? .on : .off
            return true
        case #selector(toggleTextEditing(_:)):
            menuItem.state = isEditingPDFText ? .on : .off
            return pdfView.document?.isEncrypted != true
        case #selector(recognizeText(_:)):
            return model.snapshot.files[fileId]?.isPDF == true && !model.ocr.isRecognizing(fileId)
        case #selector(selectEraserSize(_:)):
            menuItem.state = InkEraser.Size.allCases.firstIndex(of: state.eraserSize) == menuItem.tag ? .on : .off
            return true
        case #selector(setSinglePage(_:)):
            menuItem.state = pdfView.displayMode == .singlePageContinuous ? .on : .off
            return true
        case #selector(setTwoPages(_:)):
            menuItem.state = pdfView.displayMode == .twoUpContinuous ? .on : .off
            return true
        case #selector(zoomToFit(_:)):
            menuItem.state = pdfView.autoScales ? .on : .off
            return true
        case #selector(zoomIn(_:)): return pdfView.canZoomIn
        case #selector(zoomOut(_:)): return pdfView.canZoomOut
        case #selector(goToPreviousPage(_:)), #selector(goToFirstPage(_:)): return pdfView.canGoToPreviousPage
        case #selector(goToNextPage(_:)), #selector(goToLastPage(_:)): return pdfView.canGoToNextPage
        case #selector(goBack(_:)): return pdfView.canGoBack
        case #selector(goForward(_:)): return pdfView.canGoForward
        case #selector(findNext(_:)), #selector(findPrevious(_:)): return !findHits.isEmpty
        case #selector(showReaderSidebarTab(_:)):
            menuItem.state = state.sidebarTab.rawValue == menuItem.tag && !sidebarItem.isCollapsed ? .on : .off
            return true
        case #selector(toggleParallelReading(_:)):
            menuItem.state = state.parallelFileId != nil || previewShown != nil ? .on : .off
            return state.parallelFileId != nil || previewShown != nil || translationFile != nil || model.translations.jobs[itemId]?.preview != nil
        case #selector(addSelectionToNote(_:)):
            return !(pdfView.currentSelection?.string ?? "").isEmpty || pdfView.selectedAnnotation != nil
        case #selector(deleteSelectedAnnotation(_:)), #selector(delete(_:)):
            return pdfView.selectedAnnotation != nil
        default:
            return super.validateMenuItem(menuItem)
        }
    }

    // MARK: Toolbar

    func configureToolbar() {
        let toolbar = NSToolbar(identifier: "ReaderToolbar2")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = !UserDefaults.standard.bool(forKey: "FolioUITesting")
        window?.toolbar = toolbar
        removeNotesTitleFromSavedToolbar(toolbar)
        addEditButtonToSavedToolbar(toolbar)
    }

    /// 编辑 PDF came in 1.3: it joins toolbars saved before, once, after 翻译 (taken out again, it stays out).
    private func addEditButtonToSavedToolbar(_ toolbar: NSToolbar) {
        let key = "ReaderToolbarHasEditText"
        guard toolbar.autosavesConfiguration, !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        guard !toolbar.items.contains(where: { $0.itemIdentifier == .readerEditText }) else { return }
        let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == .readerTranslate }).map { $0 + 1 } ?? toolbar.items.count
        toolbar.insertItem(withItemIdentifier: .readerEditText, at: index)
    }

    /// The notes title was a toolbar item for a while (macOS 26 drew it as a button): it goes from saved toolbars.
    private func removeNotesTitleFromSavedToolbar(_ toolbar: NSToolbar) {
        if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == .readerNotesTitle }) { toolbar.removeItem(at: index) }
        // 放回标签页 belongs to a window standing apart, put in and taken out as that changes; so do the notes panel's
        // menu and button, there while the panel is open.
        for id in [NSToolbarItem.Identifier.folioReturnToTabs, .readerNotesDocument, .readerNotesOpen] {
            if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == id }) { toolbar.removeItem(at: index) }
        }
    }

    static let notesMenuFont = Font.system(size: 15, weight: .bold)

    /// The notes panel's menu (after the panel's tracking separator) and 在标签页中打开 (before the panel's button), while
    /// the panel is open.
    func updateNotesToolbarItems() {
        guard let toolbar = window?.toolbar, let notesItem else { return }
        // Floating, the panel has its menu and its button itself.
        let open = !notesItem.isCollapsed && !model.settings.inspectorFloating
        for id in [NSToolbarItem.Identifier.readerNotesOpen, .readerNotesDocument] {
            let index = toolbar.items.firstIndex { $0.itemIdentifier == id }
            if !open, let index { toolbar.removeItem(at: index) }
        }
        guard open else { return }
        if !toolbar.items.contains(where: { $0.itemIdentifier == .readerNotesDocument }) {
            let at = toolbar.items.firstIndex { $0.itemIdentifier == .inspectorTrackingSeparator }.map { $0 + 1 } ?? toolbar.items.count
            toolbar.insertItem(withItemIdentifier: .readerNotesDocument, at: at)
        }
        if !toolbar.items.contains(where: { $0.itemIdentifier == .readerNotesOpen }) {
            let at = toolbar.items.firstIndex { $0.itemIdentifier == .toggleInspector } ?? toolbar.items.count
            toolbar.insertItem(withItemIdentifier: .readerNotesOpen, at: at)
        }
    }

    @objc private func openNotesDocumentInTab(_ sender: Any?) {
        ItemDocumentsMenu.openInTab(model: model, itemId: itemId, choice: notesChoice)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .readerZoom, .space, .readerTools,
         .space, .readerTranslate, .readerEditText, .readerSearch, .inspectorTrackingSeparator, .flexibleSpace, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.readerPrint, .folioReveal, .folioReturnToTabs, .readerNotesDocument, .readerNotesOpen, .space, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .folioReturnToTabs:
            return makeReturnToTabsItem()
        case .readerNotesDocument:
            let host = NSHostingView(rootView: ItemDocumentsMenu(model: model, itemId: itemId, choice: notesChoice, titleFont: Self.notesMenuFont))
            notesMenuHost = host
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = host
            item.label = String(localized: "笔记")
            item.paletteLabel = String(localized: "笔记与文档")
            item.toolTip = String(localized: "选择要编辑的笔记或文档")
            if #available(macOS 26.0, *) { item.isBordered = false }
            return item
        case .readerNotesOpen:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: String(localized: "在标签页中打开"))
            item.label = String(localized: "在标签页中打开")
            item.toolTip = String(localized: "在标签页中打开")
            item.target = self
            item.action = #selector(openNotesDocumentInTab(_:))
            return item
        case .readerZoom:
            let group = NSToolbarItemGroup(itemIdentifier: id,
                                           images: [NSImage(systemSymbolName: "minus.magnifyingglass", accessibilityDescription: String(localized: "缩小"))!,
                                                    NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: String(localized: "放大"))!],
                                           selectionMode: .momentary, labels: [String(localized: "缩小"), String(localized: "放大")],
                                           target: nil, action: #selector(zoomFromToolbar(_:)))
            group.label = String(localized: "缩放")
            group.paletteLabel = String(localized: "缩放")
            // Where the toolbar runs out of room (the notes panel open), the pair folds into one menu button: it shows a
            // magnifier, not an empty button with an arrow.
            group.image = NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: String(localized: "缩放"))
            group.toolTip = String(localized: "缩放")
            group.visibilityPriority = .low
            return group
        case .readerTools:
            let tools = AnnotationTool.allCases
            let group = NSToolbarItemGroup(itemIdentifier: id,
                                           images: tools.map { AnnotationToolImage.make($0, color: $0.showsColorOnToolbar ? state.color(for: $0).nsColor : nil) },
                                           selectionMode: .selectOne, labels: tools.map(\.title),
                                           target: nil, action: #selector(selectTool(_:)))
            group.label = String(localized: "批注工具")
            group.paletteLabel = String(localized: "批注工具")
            group.selectedIndex = state.tool.rawValue
            for (index, tool) in tools.enumerated() {
                group.subitems[index].toolTip = tool.hasToolbarMenu
                    ? String(localized: "\(tool.title)（⌃⌘\(tool.keyEquivalent.uppercased())）：再点一次选择颜色和样式")
                    : String(localized: "\(tool.title)（⌃⌘\(tool.keyEquivalent.uppercased())）")
            }
            group.controlRepresentation = .expanded
            toolGroup = group
            return group
        case .readerTranslate:
            let menu = NSMenu()
            menu.addItem(withTitle: String(localized: "翻译全文…"), action: #selector(translateDocument(_:)), keyEquivalent: "")
            menu.addItem(withTitle: String(localized: "对照阅读"), action: #selector(toggleParallelReading(_:)), keyEquivalent: "")
            menu.addItem(withTitle: String(localized: "取消翻译"), action: #selector(cancelTranslation(_:)), keyEquivalent: "")
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.menu = menu
            item.showsIndicator = false
            item.label = String(localized: "翻译")
            item.paletteLabel = String(localized: "翻译")
            item.toolTip = String(localized: "保留排版翻译全文、对照阅读")
            item.image = TranslationIcon.fullText(accessibilityDescription: String(localized: "翻译"))
            return item
        case .readerSearch:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.label = String(localized: "查找")
            item.paletteLabel = String(localized: "在文档中查找")
            item.searchField.placeholderString = String(localized: "在文档中查找")
            item.searchField.delegate = self
            item.searchField.sendsSearchStringImmediately = false
            item.preferredWidthForSearchField = 160
            // The field would otherwise stretch over all free toolbar space.
            item.searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
            searchItem = item
            return item
        case .readerEditText:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = String(localized: "编辑 PDF")
            item.paletteLabel = String(localized: "编辑 PDF 文字")
            item.toolTip = String(localized: "编辑 PDF 中的文字")
            item.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: item.label)
            item.action = #selector(toggleTextEditing(_:))
            textEditItem = item
            return item
        case .readerPrint:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = String(localized: "打印")
            item.paletteLabel = String(localized: "打印")
            item.image = NSImage(systemSymbolName: "printer", accessibilityDescription: String(localized: "打印"))
            item.action = #selector(printDocument(_:))
            return item
        case .folioReveal:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = String(localized: "在 Finder 中显示")
            item.paletteLabel = item.label
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: item.label)
            item.action = #selector(revealInFinder(_:))
            return item
        default:
            return nil
        }
    }

}

extension NSToolbarItem.Identifier {
    static let readerZoom = NSToolbarItem.Identifier("ReaderZoom")
    static let readerTools = NSToolbarItem.Identifier("ReaderTools")
    static let readerColor = NSToolbarItem.Identifier("ReaderColor")
    static let readerTranslate = NSToolbarItem.Identifier("ReaderTranslate")
    static let readerSearch = NSToolbarItem.Identifier("ReaderSearch")
    static let readerPrint = NSToolbarItem.Identifier("ReaderPrint")
    static let readerEditText = NSToolbarItem.Identifier("ReaderEditText")
    static let readerNotesTitle = NSToolbarItem.Identifier("ReaderNotesTitle")
    /// The notes panel's document menu and 在标签页中打开, over the panel while it is open (never saved in layouts).
    static let readerNotesDocument = NSToolbarItem.Identifier("ReaderNotesDocument")
    static let readerNotesOpen = NSToolbarItem.Identifier("ReaderNotesOpen")
}

/// The PDF, plus the translation beside it while 对照阅读 is on (READER-10).
final class ReaderContentViewController: NSViewController, NSSplitViewDelegate {
    let pdfView: ReaderPDFView
    private let splitView = NSSplitView()
    private var parallelView: PDFView?
    private var isSyncing = false

    init(pdfView: ReaderPDFView) {
        self.pdfView = pdfView
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    /// Shown over the pages while this paper is being translated.
    private let translationHUD = TranslationProgressHUD()
    func readOfferPoint() -> NSPoint? {
        guard readOffer.isShown, readOfferHost.bounds.width > 60 else { return nil }
        return readOfferHost.convert(NSPoint(x: readOfferHost.bounds.maxX - 70, y: readOfferHost.bounds.midY), to: nil)
    }
    /// 扫描件: the offer to recognise its text, then the progress (OCR-01).
    let scanBanner = ScanBannerState()
    /// The offer to mark the paper read, at its end.
    let readOffer = ReadOfferState()
    private lazy var readOfferHost = ReadOfferHost(rootView: ReadOfferBanner(state: readOffer))
    private lazy var scanBannerHost = ScanBannerHost(rootView: ScanBanner(state: scanBanner))
    private let backdrop: TranslucentBackdrop = {
        let backdrop = TranslucentBackdrop()
        backdrop.drawsBlur = false
        return backdrop
    }()
    private var opaqueBackground: NSColor?
    /// Views whose automatic scale is held while the panes around them move.
    private var heldAutoScale: [PDFView] = []

    func holdScale() {
        for view in [pdfView, parallelView].compactMap({ $0 }) where view.autoScales {
            let scale = view.scaleFactor
            view.autoScales = false
            view.scaleFactor = scale
            heldAutoScale.append(view)
        }
    }

    func releaseScale() {
        let views = heldAutoScale
        heldAutoScale = []
        for view in views {
            // Keep the reading position while the page settles at its new width.
            let destination = view.currentDestination
            view.autoScales = true
            if let destination { view.go(to: destination) }
        }
    }

    /// 背景透明度: the grey around the pages becomes frosted glass; the pages stay as they are.
    func setTranslucency(_ amount: Double) {
        if opaqueBackground == nil { opaqueBackground = pdfView.backgroundColor }
        backdrop.baseColor = opaqueBackground ?? .underPageBackgroundColor
        backdrop.amount = amount
        let background = backdrop.isActive ? NSColor.clear : (opaqueBackground ?? .underPageBackgroundColor)
        for view in [pdfView, parallelView].compactMap({ $0 }) { view.backgroundColor = background }
    }

    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        NSRect(x: drawnRect.midX - EdgePointer.reach - 0.5, y: proposedEffectiveRect.minY, width: EdgePointer.reach * 2 + 1, height: proposedEffectiveRect.height)
    }

    override func loadView() {
        splitView.isVertical = true
        splitView.delegate = self
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(pdfView)
        EdgePointer.shared.add(splitView) { [weak self] in
            guard let self, self.splitView.arrangedSubviews.count > 1 else { return [] }
            return [NSRect(x: self.splitView.arrangedSubviews[0].frame.maxX - EdgePointer.reach, y: 0, width: EdgePointer.reach * 2 + 1, height: self.splitView.bounds.height)]
        }
        let container = NSView()
        for subview in [backdrop, splitView, translationHUD, scanBannerHost, readOfferHost] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(subview)
        }
        translationHUD.isHidden = true
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: container.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: container.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            translationHUD.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            translationHUD.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            translationHUD.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
            scanBannerHost.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            scanBannerHost.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 10),
            readOfferHost.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            readOfferHost.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18),
        ])
        view = container
    }

    /// The translation progress capsule: shown with a fade while `job` runs, hidden when it ends.
    func showTranslation(_ job: TranslationCoordinator.JobState?) {
        if let job { translationHUD.update(stage: job.stage, fraction: job.fraction) }
        let visible = job != nil
        guard visible == translationHUD.isHidden else { return }
        if visible {
            translationHUD.alphaValue = 0
            translationHUD.isHidden = false
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            translationHUD.animator().alphaValue = visible ? 1 : 0
        }, completionHandler: { [weak self] in
            if !visible { self?.translationHUD.isHidden = true }
        })
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        (view.window?.windowController as? ReaderWindowController)?.restorePosition()
    }

    func showParallel(_ url: URL?) {
        parallelView?.removeFromSuperview()
        parallelView = nil
        guard let url, let data = try? Data(contentsOf: url, options: .alwaysMapped), let document = PDFDocument(data: data) else { return }
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.setAccessibilityIdentifier("parallelPDFView")
        if backdrop.isActive { view.backgroundColor = .clear }
        splitView.addArrangedSubview(view)
        // A view added later starts with zero width: split the space evenly.
        splitView.layoutSubtreeIfNeeded()
        splitView.setPosition(splitView.bounds.width / 2, ofDividerAt: 0)
        parallelView = view
        NotificationCenter.default.addObserver(self, selector: #selector(parallelPageChanged(_:)), name: .PDFViewPageChanged, object: view)
    }

    /// Shows another version of the translation in the open pane, on the same page and at the same place.
    func replaceParallel(with url: URL) {
        guard let parallelView else { return showParallel(url) }
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), let document = PDFDocument(data: data) else { return }
        let destination = parallelView.currentDestination
        let index = destination?.page.flatMap { parallelView.document?.index(for: $0) }
        isSyncing = true
        parallelView.document = document
        if let index, let page = document.page(at: index), let point = destination?.point {
            parallelView.go(to: PDFDestination(page: page, at: point))
        }
        isSyncing = false
    }

    /// Keeps both sides on the same page index.
    func syncParallel(from source: PDFView) {
        guard !isSyncing, let target = source === pdfView ? parallelView : pdfView, let page = source.currentPage,
              let index = source.document?.index(for: page), let targetPage = target.document?.page(at: index),
              target.currentPage !== targetPage else { return }
        isSyncing = true
        target.go(to: targetPage)
        isSyncing = false
    }

    @objc private func parallelPageChanged(_ notification: Notification) {
        if let parallelView { syncParallel(from: parallelView) }
    }
}
