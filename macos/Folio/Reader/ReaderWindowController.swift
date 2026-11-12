import AppKit
import FolioCore
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
    private var notesFocusRequest = 0
    private var observers: [ObservationLoop] = []
    private var selectionTranslation: SelectionTranslationController!
    private var keyMonitor: Any?
    private weak var toolGroup: NSToolbarItemGroup?
    private weak var colorItem: NSMenuToolbarItem?
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
        state = ReaderState(color: AnnotationColor(rawValue: model.settings.highlightColor) ?? .yellow,
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
            content.scanBanner.editing = false
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
        content.scanBanner.editing = true
        content.scanBanner.finishEditing = { [weak self] in self?.toggleTextEditing(nil) }
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
        notesHost = NSHostingController(rootView: ReaderNotesPanel(model: model, itemId: itemId, focusRequest: 0))
        notesPane = PaneContainerController(child: notesHost, edge: .trailing)
        notesPane.backdrop.baseColor = .windowBackgroundColor
        notesItem = NSSplitViewItem(inspectorWithViewController: notesPane)
        notesItem.minimumThickness = 260
        notesItem.maximumThickness = 480
        notesItem.canCollapse = true
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(main)
        split.addSplitViewItem(notesItem)
        // The pages keep their scale while the panes beside them slide, and fit the new width at the end.
        split.onAnimationBegan = { [weak self] in self?.content.holdScale() }
        split.onAnimationEnded = { [weak self] in self?.content.releaseScale() }
        window?.contentViewController = split
        window?.setContentSize(NSSize(width: 1200, height: 860))
        if !UserDefaults.standard.bool(forKey: "FolioUITesting") { split.splitView.autosaveName = "FolioReaderSplit" }
    }

    private var sidebarActions: ReaderSidebarActions {
        ReaderSidebarActions(
            goToPage: { [weak self] index in
                guard let self, let page = self.pdfView.document?.page(at: index) else { return }
                self.pdfView.go(to: page)
            },
            showAnnotation: { [weak self] id in self?.showAnnotation(id) },
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
                self.notesHost.rootView = ReaderNotesPanel(model: self.model, itemId: file.itemId, focusRequest: self.notesFocusRequest)
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
            self.toolGroup?.selectedIndex = tool.rawValue
            let color = self.state.color
            self.pdfView.inkColor = color.nsColor
            let eraserSize = self.state.eraserSize
            self.pdfView.eraserSize = eraserSize
            // While erasing, the colour button beside the tools picks the eraser's size instead (READER-30).
            if let item = self.colorItem {
                let erasing = tool == .eraser
                item.image = erasing ? eraserSize.image : Self.colorSwatch(color)
                item.label = erasing ? String(localized: "大小") : String(localized: "颜色")
                item.toolTip = erasing ? String(localized: "橡皮擦大小（[ 与 ] 调整）") : String(localized: "批注颜色")
            }
        })
        observers.append(ObservationLoop { [weak self] in
            guard let self else { return }
            let amount = self.model.settings.backgroundTranslucency
            self.notesPane.backdrop.amount = amount
            self.content.setTranslucency(amount)
        })
    }

    // MARK: Document

    /// Reads the file into memory (mapped), so atomic saves can replace it underneath safely.
    private func loadDocument() -> Bool {
        guard let data = try? Data(contentsOf: fileURL, options: .alwaysMapped), let document = PDFDocument(data: data) else {
            model.toasts.show(String(localized: "无法打开「\(fileURL.lastPathComponent)」：不是有效的 PDF"), systemImage: "exclamationmark.triangle")
            return false
        }
        // Pages become ReaderPage (selection outline) and find results come back here.
        document.delegate = self
        pdfView.document = document
        knownModificationDate = Self.modificationDate(fileURL)
        state.pageCount = document.pageCount
        state.outline = Self.outlineRows(document.outlineRoot)
        if state.outline.isEmpty == false && state.sidebarTab == .thumbnails { state.sidebarTab = .outline }
        refreshAnnotationRows()
        return true
    }

    /// Restores the reading position once the view has its final size (READER-06).
    func restorePosition() {
        guard !restoredPosition, let document = pdfView.document else { return }
        restoredPosition = true
        // The notes panel starts hidden unless a saved layout says otherwise. (Setting this before the
        // first layout has no effect.)
        if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames FolioReaderSplit") == nil {
            notesItem.isCollapsed = true
        }
        if document.isLocked { unlockDocument() }
        let settings = model.settings
        if let saved = try? model.library.readingState(fileId: fileId), let page = document.page(at: min(saved.pageIndex, document.pageCount - 1)) {
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
            self?.savePosition()
        }
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
                                 displayMode: pdfView.displayMode.rawValue)
        try? model.library.saveReadingState(state)
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
                                          comment: isMarkup ? annotation.contents ?? "" : ""))
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

    private static func outlineRows(_ outline: PDFOutline?) -> [OutlineRow] {
        guard let outline else { return [] }
        var counter = 0
        func rows(_ node: PDFOutline) -> [OutlineRow] {
            (0..<node.numberOfChildren).compactMap { index in
                guard let child = node.child(at: index) else { return nil }
                counter += 1
                let page = child.destination?.page.flatMap { $0.document?.index(for: $0) }
                let children = rows(child)
                return OutlineRow(id: counter, title: child.label ?? "—", pageIndex: page, children: children.isEmpty ? nil : children)
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
        if notesItem.isCollapsed { split.setCollapsed(notesItem, false) }
        notesFocusRequest += 1
        notesHost.rootView = ReaderNotesPanel(model: model, itemId: itemId, focusRequest: notesFocusRequest)
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

    func windowWillClose(_ notification: Notification) {
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
        // A tool ends 编辑 PDF 文字: annotating and editing the text are not done at once.
        if isEditingPDFText { toggleTextEditing(nil) }
        // Choosing a markup tool with text already selected marks that text right away.
        if let type = tool.markupType, let selection = pdfView.currentSelection, !(selection.string ?? "").isEmpty {
            editor.addMarkup(type, for: selection)
            pdfView.clearSelection()
        }
        state.tool = state.tool == tool && sender is NSMenuItem ? .select : tool
    }

    @objc func selectColor(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, AnnotationColor.allCases.indices.contains(item.tag) else { return }
        choose(AnnotationColor.allCases[item.tag])
    }

    private func choose(_ color: AnnotationColor) {
        state.color = color
        if let annotation = pdfView.selectedAnnotation { editor.setColor(annotation, color) }
    }

    static let colorMenuIdentifier = NSUserInterfaceItemIdentifier("readerColorMenu")

    /// The toolbar's colour menu: the annotation colours as circles, the current one checked.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.identifier == Self.colorMenuIdentifier else { return }
        menu.removeAllItems()
        if state.tool == .eraser {
            menu.addItem(.sectionHeader(title: String(localized: "橡皮擦大小")))
            menu.addItem(.eraserSizes(selected: state.eraserSize) { [weak self] size in self?.choose(size) })
            menu.addItem(.separator())
            let hint = NSMenuItem(title: String(localized: "按 [ 或 ] 调整大小"), action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
            return
        }
        let colors = AnnotationColor.allCases
        menu.addItem(.colorSwatches(colors.map { .init(name: $0.title, color: $0.nsColor) }, selected: colors.firstIndex(of: state.color)) {
            [weak self] index in self?.choose(colors[index])
        })
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

    private func eraserSizeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: String(localized: "橡皮擦大小")))
        menu.addItem(.eraserSizes(selected: state.eraserSize) { [weak self] size in self?.choose(size) })
        return menu
    }

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
        case #selector(selectColor(_:)):
            menuItem.state = AnnotationColor.allCases.firstIndex(of: state.color) == menuItem.tag ? .on : .off
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
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .readerZoom, .space, .readerTools, .readerColor,
         .space, .readerTranslate, .readerEditText, .readerSearch, .inspectorTrackingSeparator, .flexibleSpace, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.readerPrint, .folioReveal, .space, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
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
                                           images: tools.map { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.title)! },
                                           selectionMode: .selectOne, labels: tools.map(\.title),
                                           target: nil, action: #selector(selectTool(_:)))
            group.label = String(localized: "批注工具")
            group.paletteLabel = String(localized: "批注工具")
            group.selectedIndex = state.tool.rawValue
            for (index, tool) in tools.enumerated() {
                group.subitems[index].toolTip = String(localized: "\(tool.title)（⌃⌘\(tool.keyEquivalent.uppercased())）")
            }
            group.controlRepresentation = .expanded
            toolGroup = group
            return group
        case .readerColor:
            let menu = NSMenu()
            menu.delegate = self
            menu.identifier = Self.colorMenuIdentifier
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.menu = menu
            item.showsIndicator = false
            item.label = String(localized: "颜色")
            item.paletteLabel = String(localized: "批注颜色")
            item.toolTip = String(localized: "批注颜色")
            item.image = Self.colorSwatch(state.color)
            colorItem = item
            return item
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
            item.image = NSImage(systemSymbolName: "character.book.closed", accessibilityDescription: String(localized: "翻译"))
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

    static func colorSwatch(_ color: AnnotationColor) -> NSImage {
        .colorDot(color.nsColor, diameter: 14)
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
    /// 扫描件: the offer to recognise its text, then the progress (OCR-01).
    let scanBanner = ScanBannerState()
    private lazy var scanBannerHost = ScanBannerHost(rootView: ScanBanner(state: scanBanner))
    private let backdrop = TranslucentBackdrop()
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

    override func loadView() {
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(pdfView)
        let container = NSView()
        for subview in [backdrop, splitView, translationHUD, scanBannerHost] as [NSView] {
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
            scanBannerHost.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scanBannerHost.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scanBannerHost.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
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
