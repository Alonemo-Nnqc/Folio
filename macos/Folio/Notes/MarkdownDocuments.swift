import AppKit
import FolioCore
import SwiftUI

extension Notification.Name {
    /// Posted after a Markdown file is saved; `object` is the file id. Other editors showing it reload.
    static let folioMarkdownFileDidChange = Notification.Name("FolioMarkdownFileDidChange")
}

// MARK: - Model actions (MD-01)

extension AppModel {
    /// Where a new document is created and edited: the text, saved through the library.
    func markdownSource(fileId: String) -> MarkdownSource {
        MarkdownSource(
            key: fileId,
            load: { [weak self] in (try? self?.library.text(ofFile: fileId)) ?? "" },
            save: { [weak self] text in
                self?.perform(String(localized: "无法保存 Markdown 文件")) { try self?.library.writeText(text, toFile: fileId) }
            },
            notification: .folioMarkdownFileDidChange)
    }

    /// A new Markdown document as an item of its own, in the group being shown: selected in the list and opened in a
    /// tab to write in (the inspector stays as it is).
    func newMarkdownDocument() {
        let title = String(localized: "未命名文档")
        perform(String(localized: "无法新建 Markdown 文件")) {
            let created = try library.createMarkdownDocument(title: title, inGroup: sidebarSelection.groupId)
            if sidebarSelection == .trash { sidebarSelection = .all }
            selectedFileIDs = []
            selectedItemIDs = [created.itemId]
            DispatchQueue.main.async { [weak self] in self?.openMarkdown(fileId: created.fileId, naming: true) }
        }
    }

    /// A new, empty Markdown attachment of an item, quietly (the panels that show it select it themselves).
    func createMarkdownAttachment(itemId: String) -> String? {
        var fileId: String?
        perform(String(localized: "无法新建 Markdown 文件")) {
            fileId = try library.createMarkdownAttachment(title: String(localized: "未命名文档"), toItem: itemId)
        }
        return fileId
    }

    /// Renames a Markdown document's file (its tab's title edited).
    func renameMarkdownFile(_ fileId: String, to name: String) {
        perform(String(localized: "无法重命名文件")) { try library.renameMarkdownFile(fileId, to: name) }
    }

    /// A new Markdown document attached to a paper (reading notes kept as a file), listed under it and opened in a tab.
    func newMarkdownAttachment(itemId: String) {
        guard snapshot.items[itemId] != nil else { return }
        // Named like any new document, not after the paper (it is listed under the paper anyway).
        guard let fileId = createMarkdownAttachment(itemId: itemId) else { return }
        previewExpandRequest = itemId
        DispatchQueue.main.async { [weak self] in self?.openMarkdown(fileId: fileId, naming: true) }
    }

    /// The Markdown file the inspector shows: a selected .md file, or a document item's own file.
    var inspectedMarkdownFile: FileRecord? {
        if selectedItemIDs.isEmpty, selectedFileIDs.count == 1, let id = selectedFileIDs.first,
           let file = snapshot.files[id], file.isMarkdown { return file }
        if selectedFileIDs.isEmpty, selectedItemIDs.count == 1, let id = selectedItemIDs.first, let item = snapshot.items[id],
           item.kind == .standalone, let file = defaultFile(of: id), file.isMarkdown { return file }
        return nil
    }
}

// MARK: - Inspector

/// A Markdown file in the inspector: its name, a button to open it in a tab, and the live editor.
struct MarkdownFileInspector: View {
    let model: AppModel
    let file: FileRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.richtext")
                    .foregroundStyle(.secondary)
                MarkdownNameField(model: model, file: file)
                Spacer(minLength: 4)
                Button {
                    model.openMarkdown(fileId: file.id)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .help("在标签页中打开")
                .accessibilityIdentifier("openMarkdownInTab")
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
            Divider().padding(.horizontal, 10)
            MarkdownFileEditor(model: model, fileId: file.id, focus: model.markdownFocusFileId == file.id)
                .padding(.horizontal, 8)
        }
    }
}

/// A document's name, renamed where it stands: Return or leaving the field renames the file, Esc keeps the name.
private struct MarkdownNameField: View {
    let model: AppModel
    let file: FileRecord
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var name: String { model.snapshot.documentName(file) }

    var body: some View {
        TextField("文件名", text: $draft)
            .textFieldStyle(.plain)
            .font(.callout.weight(.medium))
            .focused($focused)
            .help(file.fileName)
            .onSubmit { focused = false }
            .onExitCommand { draft = name; focused = false }
            .onChange(of: focused) { _, now in if !now { commit() } }
            .onAppear { draft = name }
            .onChange(of: name) { _, _ in if !focused { draft = name } }
            .accessibilityIdentifier("markdownInspectorName")
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { draft = name } else if trimmed != name { model.renameMarkdownFile(file.id, to: trimmed) }
    }
}

/// The live Markdown editor on a library file (the inspector, a document tab).
struct MarkdownFileEditor: NSViewRepresentable {
    let model: AppModel
    let fileId: String
    var focus = false

    func makeCoordinator() -> MarkdownEditorController {
        let controller = MarkdownEditorController()
        controller.textView.setAccessibilityIdentifier("markdownEditor")
        return controller
    }

    func makeNSView(context: Context) -> MarkdownPane { MarkdownPane(editor: context.coordinator) }

    func updateNSView(_ nsView: MarkdownPane, context: Context) {
        nsView.showsToolbar = model.settings.markdownToolbar
        context.coordinator.textView.references = { [weak model] in model?.markdownReferences(matching: $0) ?? [] }
        context.coordinator.load(model.markdownSource(fileId: fileId))
        if focus, model.markdownFocusFileId == fileId {
            context.coordinator.focus(request: model.noteFocusRequest + 1_000_000)
            DispatchQueue.main.async { model.markdownFocusFileId = nil }
        }
    }

    static func dismantleNSView(_ nsView: MarkdownPane, coordinator: MarkdownEditorController) {
        coordinator.saveNow()
    }
}

// MARK: - An item's documents in a side panel

/// Which of an item's documents a panel shows: "" for the note, else a Markdown attachment's file id. Shared by the
/// reader's notes panel and its toolbar, where the panel's title menu sits.
@Observable
final class ItemDocumentChoice {
    var fileId = ""
}

extension AppModel {
    /// An item's Markdown attachments, the documents a panel offers beside the note.
    func markdownDocuments(of itemId: String) -> [FileRecord] { snapshot.files(of: itemId).filter(\.isMarkdown) }
}

/// The title of an item's documents: the one shown, with a menu of the note and the item's Markdown attachments (and
/// one to add).
struct ItemDocumentsMenu: View {
    let model: AppModel
    let itemId: String
    let choice: ItemDocumentChoice
    var titleFont: Font = .headline

    var body: some View {
        let documents = model.markdownDocuments(of: itemId)
        let current = documents.first { $0.id == choice.fileId }
        Menu {
            Picker(selection: Binding(get: { choice.fileId }, set: { choice.fileId = $0 })) {
                Label("笔记", systemImage: "note.text").tag("")
                ForEach(documents) { file in
                    Label(model.snapshot.documentName(file), systemImage: "doc.richtext").tag(file.id)
                }
            } label: { EmptyView() }
            .pickerStyle(.inline)
            Divider()
            if let current {
                Button { model.askMarkdownName(fileId: current.id) } label: { Label("重命名…", systemImage: "pencil") }
            }
            Button {
                if let id = model.createMarkdownAttachment(itemId: itemId) {
                    choice.fileId = id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { model.askMarkdownName(fileId: id) }
                }
            } label: { Label("新建 Markdown 附件", systemImage: "plus") }
        } label: {
            Text(current.map { model.snapshot.documentName($0) } ?? String(localized: "笔记"))
                .font(titleFont)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("itemDocumentMenu")
    }

    /// Opens the document shown in a tab.
    static func openInTab(model: AppModel, itemId: String, choice: ItemDocumentChoice) {
        if model.markdownDocuments(of: itemId).contains(where: { $0.id == choice.fileId }) {
            model.openMarkdown(fileId: choice.fileId)
        } else {
            model.openNote(itemId: itemId)
        }
    }
}

/// An item's documents where its note was edited (the inspector's 笔记, the reader's notes panel): the note, or one of
/// the item's Markdown attachments, chosen from the title's menu (which can also add one), and a button to open the
/// one shown in a tab. The note and the attachments are written in the same editor, in the panel or in a tab. In the
/// reader the menu and the button are in the toolbar, over the panel (`showsHeader` false).
struct ItemDocumentsPanel: View {
    let model: AppModel
    let itemId: String
    var focusRequest = 0
    var choice: ItemDocumentChoice?
    var showsHeader = true
    var showsItemTitle = false
    @State private var ownChoice = ItemDocumentChoice()

    var body: some View {
        let active = choice ?? ownChoice
        let documents = model.markdownDocuments(of: itemId)
        let current = documents.first { $0.id == active.fileId }
        VStack(alignment: .leading, spacing: 6) {
            if showsHeader {
                HStack(spacing: 6) {
                    ItemDocumentsMenu(model: model, itemId: itemId, choice: active)
                    Spacer(minLength: 4)
                    Button {
                        ItemDocumentsMenu.openInTab(model: model, itemId: itemId, choice: active)
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.borderless)
                    .help("在标签页中打开")
                }
                .frame(height: 28)
                .padding(.horizontal, 12)
            }
            if showsItemTitle, let title = model.snapshot.items[itemId]?.title {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
            }
            Divider().padding(.horizontal, 8)
            if let current {
                MarkdownFileEditor(model: model, fileId: current.id)
                    .id(current.id)
                    .padding(.horizontal, 6)
            } else {
                NoteEditor(model: model, itemId: itemId, focusRequest: focusRequest)
                    .padding(.horizontal, 6)
            }
        }
        .onChange(of: documents.map(\.id)) { _, ids in if !active.fileId.isEmpty, !ids.contains(active.fileId) { active.fileId = "" } }
    }
}

// MARK: - Document tabs

/// What a document tab shows: a Markdown file of the library, or an item's note (written in the same editor).
enum MarkdownTarget: Hashable {
    case file(String)
    case note(String)

    var key: String {
        switch self {
        case .file(let id): "file:\(id)"
        case .note(let id): "note:\(id)"
        }
    }
}

extension AppModel {
    /// Opens a Markdown file as a tab beside the library (or brings its tab forward).
    /// `naming`: a new document, its name selected to be typed over.
    func openMarkdown(fileId: String, naming: Bool = false) {
        guard snapshot.files[fileId] != nil else {
            // Just created: in the snapshot a moment later.
            if naming { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in if self?.snapshot.files[fileId] != nil { self?.openMarkdown(fileId: fileId, naming: true) } } }
            return
        }
        markdownTabs.open(.file(fileId))
        if naming { markdownTabs.controller(for: fileId)?.beginNaming() }
    }

    /// Asks for a Markdown document's new name (its menus in the panels, where it has no row of its own).
    func askMarkdownName(fileId: String) {
        guard let file = snapshot.files[fileId] else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "重命名文档")
        let field = NSTextField(string: snapshot.documentName(file))
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "重命名"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        renameMarkdownFile(fileId, to: field.stringValue)
    }

    /// Opens an item's note as a document tab (the note is a document of the item, listed under it).
    func openNote(itemId: String) {
        guard snapshot.items[itemId] != nil else { return }
        markdownTabs.open(.note(itemId))
    }

    /// Where an item's note comes from and goes to (the same note the inspector edits).
    func noteSource(itemId: String) -> MarkdownSource {
        MarkdownSource(
            key: itemId,
            load: { [weak self] in (try? self?.library.note(for: itemId)) ?? "" },
            save: { [weak self] text in
                self?.perform(String(localized: "无法保存笔记")) { try self?.library.setNote(text, for: itemId) }
                NotificationCenter.default.post(name: .folioNoteDidChange, object: itemId)
            },
            notification: .folioNoteDidChange)
    }
}

/// The open document tabs, one per file or note.
@MainActor
final class MarkdownTabCoordinator {
    private weak var model: AppModel?
    private var windows: [MarkdownTarget: MarkdownWindowController] = [:]

    init(model: AppModel) { self.model = model }

    func controller(for fileId: String) -> MarkdownWindowController? { windows[.file(fileId)] }

    func open(fileId: String) { open(.file(fileId)) }

    func open(_ target: MarkdownTarget) {
        guard let model else { return }
        if let existing = windows[target] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = MarkdownWindowController(model: model, target: target)
        controller.onClose = { [weak self] in self?.windows[target] = nil }
        windows[target] = controller
        guard let window = controller.window else { return }
        let host = (NSApp.keyWindow?.windowController as? FolioWindowController)?.window ?? model.libraryWindow
        if let host, host.isVisible, host.tabbingIdentifier == window.tabbingIdentifier {
            host.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        } else {
            window.center()
            controller.showWindow(nil)
        }
    }

    func saveAll() {
        for controller in windows.values { controller.editor.saveNow() }
    }
}

/// A Markdown document (or an item's note) in a tab of its own: the editor centred at a comfortable reading width,
/// under a toolbar of the usual formatting tools (设置 ▸ 通用 ▸ 显示 Markdown 文档工具栏).
final class MarkdownWindowController: FolioWindowController, NSToolbarDelegate, NSTextFieldDelegate, NSMenuDelegate {
    let target: MarkdownTarget
    let editor: MarkdownEditorController
    var onClose: () -> Void = {}
    private var observers: [ObservationLoop] = []
    private let countLabel = NSTextField(labelWithString: "")
    private var countTask: Task<Void, Never>?
    private weak var styleItem: NSMenuToolbarItem?
    private weak var outlineItem: NSMenuToolbarItem?
    private weak var appearanceItem: NSMenuToolbarItem?

    var fileId: String? { if case .file(let id) = target { id } else { nil } }
    var noteItemId: String? { if case .note(let id) = target { id } else { nil } }

    init(model: AppModel, target: MarkdownTarget) {
        self.target = target
        editor = MarkdownEditorController(inPanel: false)
        editor.textView.limitsWidth = true
        editor.textView.readableWidth = MarkdownPreferences.current.readableWidth
        editor.textView.verticalInset = 28
        // Room beside the text for the handles of the line under the pointer, however narrow the window.
        editor.textView.horizontalInset = 56
        editor.textView.showsGutter = true
        editor.textView.references = { [weak model] in model?.markdownReferences(matching: $0) ?? [] }
        editor.textView.setAccessibilityIdentifier("markdownDocumentEditor")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.tabbingIdentifier = LibraryWindowController.tabbingIdentifier
        window.tabbingMode = .preferred
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.setAccessibilityIdentifier("markdownWindow")
        let content = NSViewController()
        let root = NSView()
        let background = NSVisualEffectView()
        background.material = .contentBackground
        background.blendingMode = .behindWindow
        for view in [background, editor.scrollView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: root.topAnchor),
            background.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            background.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            editor.scrollView.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            editor.scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            editor.scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            editor.scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.setAccessibilityIdentifier("markdownWordCount")
        root.addSubview(countLabel)
        NSLayoutConstraint.activate([
            countLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            countLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])
        content.view = root
        window.contentViewController = content
        window.setContentSize(NSSize(width: 1100, height: 820))
        super.init(model: model, window: window)
        // A document's name is in the toolbar, where it can be edited; a note keeps the window's own title.
        if case .file = target { window.titleVisibility = .hidden }
        installToolbar()
        switch target {
        case .file(let id): editor.load(model.markdownSource(fileId: id))
        case .note(let id): editor.load(model.noteSource(itemId: id))
        }
        window.initialFirstResponder = editor.textView
        editor.onSelectionChange = { [weak self] in self?.updateStyleButton() }
        editor.onTextChange = { [weak self] in self?.textChanged() }
        textChanged()
        observers.append(ObservationLoop { [weak self] in
            guard let self else { return }
            let snapshot = self.model.snapshot
            switch self.target {
            case .file(let id):
                guard let file = snapshot.files[id] else { return }
                let item = snapshot.items[file.itemId]
                let name = snapshot.documentName(file)
                self.window?.title = name
                self.window?.subtitle = item?.kind == .regular ? (item?.title ?? "") : ""
                self.window?.tab.title = name
                self.window?.representedURL = self.model.fileURL(file)
                if self.nameField.currentEditor() == nil, self.nameField.stringValue != name { self.nameField.stringValue = name }
                self.fitName()
                self.nameField.toolTip = item?.kind == .regular ? String(localized: "\(file.fileName) · \(item?.title ?? "")") : file.fileName
            case .note(let id):
                guard let item = snapshot.items[id] else { return }
                self.window?.title = String(localized: "笔记")
                self.window?.subtitle = item.title
                self.window?.tab.title = String(localized: "笔记 · \(item.title)")
            }
        })
        var shown = model.settings.markdownToolbar
        observers.append(ObservationLoop { [weak self] in
            guard let self else { return }
            let wanted = self.model.settings.markdownToolbar
            if wanted != shown {
                shown = wanted
                self.installToolbar()
            }
        })
        observers.append(ObservationLoop { [weak self] in
            guard let self else { return }
            _ = self.model.settings.markdown.showsWordCount
            self.textChanged()
        })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override var targetItemIds: [String] {
        switch target {
        case .file(let id): model.snapshot.files[id].map { [$0.itemId] } ?? []
        case .note(let id): [id]
        }
    }
    override var targetFileId: String? { fileId }

    func windowWillClose(_ notification: Notification) {
        editor.saveNow()
        onClose()
    }

    func windowDidResignKey(_ notification: Notification) { editor.saveNow() }

    // MARK: Toolbar

    /// A new toolbar whenever the formatting tools are shown or hidden (the window keeps its title either way). The name is
    /// at the left, the tools in the middle of the window, what is about the whole document at the right.
    private func installToolbar() {
        let toolbar = NSToolbar(identifier: model.settings.markdownToolbar ? "MarkdownFormatToolbar" : "MarkdownPlainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        if model.settings.markdownToolbar { toolbar.centeredItemIdentifiers = Set(Self.formatItems) }
        window?.toolbar = toolbar
        updateReturnButton()
        updateStyleButton()
    }

    private static let formatItems: [NSToolbarItem.Identifier] = [.markdownStyle, .markdownInline, .markdownLists, .markdownBlocks, .markdownInsert]

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        let name: [NSToolbarItem.Identifier] = fileId != nil ? [.markdownName] : []
        let paper: [NSToolbarItem.Identifier] = paperFile != nil ? [.markdownPaper] : []
        guard model.settings.markdownToolbar else { return name + [.flexibleSpace] + paper + [.markdownAppearance, .markdownOutline] }
        return name + Self.formatItems + [.flexibleSpace] + paper + [.markdownAppearance, .markdownOutline, .markdownFind]
    }

    /// The PDF of the paper the document or note belongs to.
    private var paperFile: FileRecord? {
        guard let id = targetItemIds.first, let item = model.snapshot.items[id], item.kind == .regular,
              let file = model.defaultFile(of: id), file.isPDF else { return nil }
        return file
    }

    // MARK: What follows the text

    private func updateStyleButton() {
        guard let styleItem else { return }
        let title = editor.textView.styleTitle
        if styleItem.title != title { styleItem.title = title }
    }

    /// The count a moment after typing stops.
    private func textChanged() {
        updateStyleButton()
        countTask?.cancel()
        countTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            let count = self.editor.wordCount
            self.countLabel.stringValue = count == 0 || !self.model.settings.markdown.showsWordCount ? "" : String(localized: "\(count) 字")
        }
    }

    // MARK: The file's name, edited in place

    private lazy var nameField: NSTextField = {
        let field = NSTextField(string: "")
        field.isBordered = false
        field.drawsBackground = false
        field.isEditable = true
        field.isSelectable = true
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13, weight: .semibold)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.delegate = self
        field.setAccessibilityIdentifier("markdownFileName")
        field.setAccessibilityLabel(String(localized: "文件名"))
        field.translatesAutoresizingMaskIntoConstraints = false
        nameWidth = field.widthAnchor.constraint(equalToConstant: 80)
        nameWidth?.isActive = true
        return field
    }()

    private var nameWidth: NSLayoutConstraint?

    /// The name selected, to be typed over (a new document); Return goes on to the text.
    func beginNaming(tries: Int = 12) {
        guard let window, nameField.window === window, window.makeFirstResponder(nameField) else {
            if tries > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in self?.beginNaming(tries: tries - 1) } }
            return
        }
        nameField.currentEditor()?.selectAll(nil)
    }

    var isNaming: Bool { nameField.currentEditor() != nil }

    /// The field is as wide as the name: a wider one would push the tools out of the window's middle.
    private func fitName() {
        let font = nameField.font ?? .systemFont(ofSize: 13, weight: .semibold)
        let width = (nameField.stringValue as NSString).size(withAttributes: [.font: font]).width
        nameWidth?.constant = min(max(ceil(width) + 12, 60), 220)
    }

    func controlTextDidChange(_ obj: Notification) { fitName() }

    private func commitName() {
        guard let fileId, let file = model.snapshot.files[fileId] else { return }
        let current = model.snapshot.documentName(file)
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { nameField.stringValue = current } else if name != current { model.renameMarkdownFile(fileId, to: name) }
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitName() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commitName()
            window?.makeFirstResponder(editor.textView)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if let fileId, let file = model.snapshot.files[fileId] { nameField.stringValue = model.snapshot.documentName(file) }
            window?.makeFirstResponder(editor.textView)
            return true
        default:
            return false
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.folioReturnToTabs]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func symbol(_ name: String, _ label: String) -> NSImage {
            NSImage(systemSymbolName: name, accessibilityDescription: label) ?? NSImage()
        }
        func group(_ id: NSToolbarItem.Identifier, _ label: String, _ parts: [(String, String)], _ action: Selector) -> NSToolbarItemGroup {
            let group = NSToolbarItemGroup(itemIdentifier: id, images: parts.map { symbol($0.0, $0.1) }, selectionMode: .momentary,
                                           labels: parts.map(\.1), target: self, action: action)
            group.label = label
            group.paletteLabel = label
            // Never folded into a menu of their own: in a narrow window the last groups go into the toolbar's overflow.
            group.controlRepresentation = .expanded
            for (index, sub) in group.subitems.enumerated() { sub.toolTip = parts[index].1 }
            return group
        }
        switch id {
        case .folioReturnToTabs:
            return makeReturnToTabsItem()
        case .markdownName:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = nameField
            item.label = String(localized: "文件名")
            item.isNavigational = true
            item.visibilityPriority = .high
            return item
        case .markdownStyle:
            let menu = NSMenu()
            for (index, command) in MarkdownCommand.all.enumerated() where command.style != nil {
                if index > 0, MarkdownCommand.all[index - 1].section != command.section { menu.addItem(.separator()) }
                let item = NSMenuItem(title: command.title, action: #selector(blockStyle(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                item.image = command.image
                menu.addItem(item)
            }
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.menu = menu
            item.title = String(localized: "正文")
            item.label = String(localized: "段落样式")
            item.toolTip = String(localized: "段落样式")
            item.showsIndicator = true
            item.visibilityPriority = .high
            styleItem = item
            return item
        case .markdownInline:
            return group(id, String(localized: "文字"), [("bold", String(localized: "粗体（⌘B）")), ("italic", String(localized: "斜体（⌘I）")),
                                                        ("strikethrough", String(localized: "删除线")), ("highlighter", String(localized: "高亮")),
                                                        ("chevron.left.forwardslash.chevron.right", String(localized: "行内代码"))],
                         #selector(inlineStyle(_:)))
        case .markdownLists:
            return group(id, String(localized: "列表"), [("list.bullet", String(localized: "项目列表")), ("list.number", String(localized: "编号列表")),
                                                        ("checklist", String(localized: "任务列表"))],
                         #selector(listStyle(_:)))
        case .markdownBlocks:
            return group(id, String(localized: "区块"), [("text.quote", String(localized: "引用块")), ("curlybraces", String(localized: "代码块")),
                                                        ("tablecells", String(localized: "表格"))],
                         #selector(block(_:)))
        case .markdownInsert:
            return group(id, String(localized: "插入"), [("link", String(localized: "链接（⌘K）")), ("quote.opening", String(localized: "引用文献")),
                                                        ("plus", String(localized: "插入（/）"))],
                         #selector(insert(_:)))
        case .markdownPaper:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = symbol("doc.text", String(localized: "打开论文"))
            item.label = String(localized: "打开论文")
            item.toolTip = String(localized: "打开论文")
            item.isBordered = true
            item.target = self
            item.action = #selector(openPaper(_:))
            return item
        case .markdownAppearance:
            let menu = NSMenu()
            menu.delegate = self
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.menu = menu
            item.image = symbol("textformat.size", String(localized: "文字大小"))
            item.label = String(localized: "文字大小")
            item.toolTip = String(localized: "文字大小、行高和宽度")
            item.showsIndicator = false
            appearanceItem = item
            return item
        case .markdownOutline:
            let menu = NSMenu()
            menu.delegate = self
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.menu = menu
            item.image = symbol("list.bullet.indent", String(localized: "大纲"))
            item.label = String(localized: "大纲")
            item.toolTip = String(localized: "大纲")
            item.showsIndicator = false
            outlineItem = item
            return item
        case .markdownFind:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = symbol("magnifyingglass", String(localized: "查找（⌘F）"))
            item.label = String(localized: "查找")
            item.toolTip = String(localized: "查找（⌘F）")
            item.isBordered = true
            item.target = self
            item.action = #selector(find(_:))
            return item
        default:
            return nil
        }
    }

    // MARK: Outline

    /// The headings as they are when the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === appearanceItem?.menu {
            let entries = editor.textView.appearanceMenu()
            for item in entries.items { entries.removeItem(item); menu.addItem(item) }
            return
        }
        let headings = editor.headings
        guard !headings.isEmpty else {
            let empty = NSMenuItem(title: String(localized: "没有标题"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        let top = headings.map(\.level).min() ?? 1
        for heading in headings {
            let item = NSMenuItem(title: heading.title, action: #selector(goToHeading(_:)), keyEquivalent: "")
            item.target = self
            item.tag = heading.location
            item.indentationLevel = min(heading.level - top, 5)
            menu.addItem(item)
        }
    }

    @objc private func goToHeading(_ sender: NSMenuItem) { editor.reveal(sender.tag) }

    @objc private func openPaper(_ sender: Any?) {
        if let file = paperFile { model.open(fileId: file.id, mode: .reader) }
    }

    @objc private func find(_ sender: Any?) {
        window?.makeFirstResponder(textView)
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(item)
    }

    // MARK: Formatting

    private var textView: MarkdownTextView { editor.textView }

    private func segment(_ sender: Any?) -> Int {
        (sender as? NSToolbarItemGroup)?.selectedIndex ?? (sender as? NSSegmentedControl)?.selectedSegment ?? -1
    }

    @objc private func blockStyle(_ sender: NSMenuItem) {
        guard MarkdownCommand.all.indices.contains(sender.tag), let style = MarkdownCommand.all[sender.tag].style else { return }
        textView.setBlockStyle(style)
        updateStyleButton()
    }

    @objc private func inlineStyle(_ sender: Any?) {
        if textView.blockViews.activeCell == nil { window?.makeFirstResponder(textView) }
        switch segment(sender) {
        case 0: textView.toggleWrap("**")
        case 1: textView.toggleWrap("*")
        case 2: textView.toggleWrap("~~")
        case 3: textView.toggleWrap("==")
        case 4: textView.toggleWrap("`")
        default: break
        }
    }

    @objc private func insert(_ sender: Any?) {
        window?.makeFirstResponder(textView)
        switch segment(sender) {
        case 0: textView.insertLink()
        case 1: textView.openMenu(typingSlash: true, citing: true)
        case 2: textView.openMenu(typingSlash: true)
        default: break
        }
    }

    @objc private func listStyle(_ sender: Any?) {
        switch segment(sender) {
        case 0: textView.toggleLineStyle(.bullet)
        case 1: textView.toggleLineStyle(.numbered)
        case 2: textView.toggleLineStyle(.task)
        default: break
        }
    }

    @objc private func block(_ sender: Any?) {
        switch segment(sender) {
        case 0: textView.toggleLineStyle(.quote)
        case 1: textView.insertCodeBlock()
        case 2: textView.insertTable()
        default: break
        }
    }

    /// 显示 ▸ 显示 Markdown 文档工具栏.
    @objc func toggleMarkdownToolbar(_ sender: Any?) { model.settings.markdownToolbar.toggle() }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleMarkdownToolbar(_:)) {
            menuItem.state = model.settings.markdownToolbar ? .on : .off
            return true
        }
        return super.validateMenuItem(menuItem)
    }
}

extension NSToolbarItem.Identifier {
    static let markdownName = NSToolbarItem.Identifier("MarkdownName")
    static let markdownStyle = NSToolbarItem.Identifier("MarkdownStyle")
    static let markdownInline = NSToolbarItem.Identifier("MarkdownInline")
    static let markdownLists = NSToolbarItem.Identifier("MarkdownLists")
    static let markdownBlocks = NSToolbarItem.Identifier("MarkdownBlocks")
    static let markdownInsert = NSToolbarItem.Identifier("MarkdownInsert")
    static let markdownPaper = NSToolbarItem.Identifier("MarkdownPaper")
    static let markdownAppearance = NSToolbarItem.Identifier("MarkdownAppearance")
    static let markdownOutline = NSToolbarItem.Identifier("MarkdownOutline")
    static let markdownFind = NSToolbarItem.Identifier("MarkdownFind")
}
