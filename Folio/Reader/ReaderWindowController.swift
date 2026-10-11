import AppKit
import FolioCore
import PDFKit
import SwiftUI

/// One paper in its own native tab (READER-01…10). The PDF is shown with PDFKit — the engine
/// Preview uses — and annotations are written back into the file in standard form.
final class ReaderWindowController: FolioWindowController, NSToolbarDelegate, NSSearchFieldDelegate, PDFDocumentDelegate {
    let fileId: String
    private(set) var itemId: String
    let state: ReaderState
    let pdfView = ReaderPDFView()
    private let editor: AnnotationEditor
    private let content: ReaderContentViewController
    private let split = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem!
    private var notesItem: NSSplitViewItem!
    private var notesHost: NSHostingController<ReaderNotesPanel>!
    private var notesFocusRequest = 0
    private var observers: [ObservationLoop] = []
    private weak var toolGroup: NSToolbarItemGroup?
    private weak var colorItem: NSMenuToolbarItem?
    private weak var searchItem: NSSearchToolbarItem?

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
        state = ReaderState(color: AnnotationColor(rawValue: model.settings.highlightColor) ?? .yellow)
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    // MARK: Setup

    private func configurePDFView() {
        pdfView.editor = editor
        editor.pdfView = pdfView
        pdfView.displaysPageBreaks = true
        pdfView.pageShadowsEnabled = true
        pdfView.setAccessibilityIdentifier("readerPDFView")
        editor.onChange = { [weak self] in self?.documentChanged() }
        editor.onAddToNote = { [weak self] text, page in self?.addToNote(text, pageIndex: page) }
        editor.onCopyAsCitation = { [weak self] text, page in self?.copyAsCitation(text, pageIndex: page) }
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged(_:)), name: .PDFViewPageChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged(_:)), name: .PDFViewScaleChanged, object: pdfView)
    }

    private func buildSplit() {
        let sidebar = NSHostingController(rootView: ReaderSidebarView(state: state, pdfView: pdfView, actions: sidebarActions))
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = true
        let main = NSSplitViewItem(viewController: content)
        main.minimumThickness = 360
        notesHost = NSHostingController(rootView: ReaderNotesPanel(model: model, itemId: itemId, focusRequest: 0))
        notesItem = NSSplitViewItem(inspectorWithViewController: notesHost)
        notesItem.minimumThickness = 260
        notesItem.maximumThickness = 480
        notesItem.canCollapse = true
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(main)
        split.addSplitViewItem(notesItem)
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
            self.colorItem?.image = Self.colorSwatch(color)
        })
    }

    // MARK: Document

    /// Reads the file into memory (mapped), so atomic saves can replace it underneath safely.
    private func loadDocument() -> Bool {
        guard let data = try? Data(contentsOf: fileURL, options: .alwaysMapped), let document = PDFDocument(data: data) else {
            model.toasts.show("无法打开「\(fileURL.lastPathComponent)」：不是有效的 PDF", systemImage: "exclamationmark.triangle")
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
        alert.messageText = "这份 PDF 受密码保护"
        alert.informativeText = "输入密码以打开「\(window.title)」。"
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "打开")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            if !document.unlock(withPassword: field.stringValue) {
                self?.model.toasts.show("密码不正确", systemImage: "lock")
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
            model.toasts.show("无法保存批注：写入文件失败", systemImage: "exclamationmark.triangle")
            return false
        }
        do {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            model.toasts.show("无法保存批注：\(error.localizedDescription)", systemImage: "exclamationmark.triangle")
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
            let label = page.label.flatMap { $0 == String(index + 1) ? nil : "（\($0)）" } ?? ""
            window.subtitle = "第 \(index + 1) / \(state.pageCount) 页\(label)"
        }
        let short = item.map { $0.authors.first.map { "\($0.family) \(item?.year.map(String.init) ?? "")" } ?? $0.title } ?? fileURL.lastPathComponent
        window.tab.title = short.trimmingCharacters(in: .whitespaces)
        window.tab.toolTip = window.title
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
        case "Highlight": "高亮"
        case "Underline": "下划线"
        case "StrikeOut": "删除线"
        case "Squiggly": "波浪线"
        case "Text": "便签"
        case "FreeText": "文本框"
        case "Ink": "手绘"
        default: "图形"
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
        model.appendToNote(itemId: itemId, "\(quote)\n> —— 第 \(pageIndex + 1) 页")
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
        NSPasteboard.general.setString("“\(text)”（\(citation)）", forType: .string)
        model.toasts.show("已拷贝为引用", systemImage: "quote.opening")
    }

    private func showNotes() {
        if notesItem.isCollapsed { notesItem.animator().isCollapsed = false }
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
        alert.messageText = "无法保存批注"
        alert.informativeText = "关闭后，这次添加的批注会丢失。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "仍然关闭")
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
        if sidebarItem.isCollapsed { sidebarItem.animator().isCollapsed = false }
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
        if sidebarItem.isCollapsed { sidebarItem.animator().isCollapsed = false }
    }

    @objc func toggleParallelReading(_ sender: Any?) {
        if state.parallelFileId != nil {
            state.parallelFileId = nil
            content.showParallel(nil)
            return
        }
        guard let translation = translationFile else {
            model.toasts.show("这篇论文还没有译文。可以先\"翻译全文\"", systemImage: "character.book.closed")
            return
        }
        state.parallelFileId = translation.id
        content.showParallel(model.fileURL(translation))
        content.syncParallel(from: pdfView)
    }

    /// The translation to read side by side: a mono translation of this file, else a dual one.
    private var translationFile: FileRecord? {
        let files = model.snapshot.files.values.filter { $0.translationOf == fileId }
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
        alert.messageText = "前往页面"
        alert.informativeText = "输入页码（1–\(document.pageCount)）"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.stringValue = "\(state.pageIndex + 1)"
        alert.accessoryView = field
        alert.addButton(withTitle: "前往")
        alert.addButton(withTitle: "取消")
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
        // Choosing a markup tool with text already selected marks that text right away.
        if let type = tool.markupType, let selection = pdfView.currentSelection, !(selection.string ?? "").isEmpty {
            editor.addMarkup(type, for: selection)
            pdfView.clearSelection()
        }
        state.tool = state.tool == tool && sender is NSMenuItem ? .select : tool
    }

    @objc func selectColor(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, AnnotationColor.allCases.indices.contains(item.tag) else { return }
        let color = AnnotationColor.allCases[item.tag]
        state.color = color
        if let annotation = pdfView.selectedAnnotation { editor.setColor(annotation, color) }
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
            menuItem.state = state.parallelFileId != nil ? .on : .off
            return state.parallelFileId != nil || translationFile != nil
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
        let toolbar = NSToolbar(identifier: "ReaderToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = !UserDefaults.standard.bool(forKey: "FolioUITesting")
        window?.toolbar = toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .readerZoom, .space, .readerTools, .readerColor,
         .space, .readerTranslate, .readerSearch, .inspectorTrackingSeparator, .flexibleSpace, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.readerPrint, .folioReveal, .space, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .readerZoom:
            let group = NSToolbarItemGroup(itemIdentifier: id,
                                           images: [NSImage(systemSymbolName: "minus.magnifyingglass", accessibilityDescription: "缩小")!,
                                                    NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: "放大")!],
                                           selectionMode: .momentary, labels: ["缩小", "放大"],
                                           target: nil, action: #selector(zoomFromToolbar(_:)))
            group.label = "缩放"
            group.paletteLabel = "缩放"
            return group
        case .readerTools:
            let tools = AnnotationTool.allCases
            let group = NSToolbarItemGroup(itemIdentifier: id,
                                           images: tools.map { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.title)! },
                                           selectionMode: .selectOne, labels: tools.map(\.title),
                                           target: nil, action: #selector(selectTool(_:)))
            group.label = "批注工具"
            group.paletteLabel = "批注工具"
            group.selectedIndex = state.tool.rawValue
            for (index, tool) in tools.enumerated() {
                group.subitems[index].toolTip = "\(tool.title)（⌃⌘\(tool.keyEquivalent.uppercased())）"
            }
            group.controlRepresentation = .expanded
            toolGroup = group
            return group
        case .readerColor:
            let menu = NSMenu()
            for (index, color) in AnnotationColor.allCases.enumerated() {
                let item = menu.addItem(withTitle: color.title, action: #selector(selectColor(_:)), keyEquivalent: "")
                item.tag = index
                item.image = Self.colorSwatch(color)
            }
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.menu = menu
            item.label = "颜色"
            item.paletteLabel = "批注颜色"
            item.toolTip = "批注颜色"
            item.image = Self.colorSwatch(state.color)
            colorItem = item
            return item
        case .readerTranslate:
            let menu = NSMenu()
            menu.addItem(withTitle: "翻译全文…", action: #selector(translateDocument(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "对照阅读", action: #selector(toggleParallelReading(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "取消翻译", action: #selector(cancelTranslation(_:)), keyEquivalent: "")
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.menu = menu
            item.label = "翻译"
            item.paletteLabel = "翻译"
            item.toolTip = "保留排版翻译全文、对照阅读"
            item.image = NSImage(systemSymbolName: "character.book.closed", accessibilityDescription: "翻译")
            return item
        case .readerSearch:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.label = "查找"
            item.paletteLabel = "在文档中查找"
            item.searchField.placeholderString = "在文档中查找"
            item.searchField.delegate = self
            item.searchField.sendsSearchStringImmediately = false
            item.preferredWidthForSearchField = 200
            searchItem = item
            return item
        case .readerPrint:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "打印"
            item.paletteLabel = "打印"
            item.image = NSImage(systemSymbolName: "printer", accessibilityDescription: "打印")
            item.action = #selector(printDocument(_:))
            return item
        case .folioReveal:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "在 Finder 中显示"
            item.paletteLabel = item.label
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: item.label)
            item.action = #selector(revealInFinder(_:))
            return item
        default:
            return nil
        }
    }

    static func colorSwatch(_ color: AnnotationColor) -> NSImage {
        NSImage(systemSymbolName: "circle.fill", accessibilityDescription: color.title)!
            .withSymbolConfiguration(.init(paletteColors: [color.nsColor]))!
    }
}

extension NSToolbarItem.Identifier {
    static let readerZoom = NSToolbarItem.Identifier("ReaderZoom")
    static let readerTools = NSToolbarItem.Identifier("ReaderTools")
    static let readerColor = NSToolbarItem.Identifier("ReaderColor")
    static let readerTranslate = NSToolbarItem.Identifier("ReaderTranslate")
    static let readerSearch = NSToolbarItem.Identifier("ReaderSearch")
    static let readerPrint = NSToolbarItem.Identifier("ReaderPrint")
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

    override func loadView() {
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(pdfView)
        view = splitView
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
        splitView.addArrangedSubview(view)
        splitView.adjustSubviews()
        parallelView = view
        NotificationCenter.default.addObserver(self, selector: #selector(parallelPageChanged(_:)), name: .PDFViewPageChanged, object: view)
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
