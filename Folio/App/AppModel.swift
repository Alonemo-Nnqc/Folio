import AppKit
import FolioCore
import Observation

/// Search state behind the toolbar search field and the scope bar (SEARCH-01…05).
struct SearchState: Equatable {
    var text = ""
    var wholeLibrary = false
    var includeFulltext = false

    var isActive: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// Pages of the library inspector (INSP-02/03, NOTE-01).
enum InspectorTab: String, CaseIterable {
    case metadata, annotations, notes

    var title: String {
        switch self {
        case .metadata: "信息"
        case .annotations: "标注"
        case .notes: "笔记"
        }
    }
}

/// Root state of the main window. Views read from it; every mutation goes through `Library`.
@Observable
final class AppModel {
    let settings: AppSettings
    let toasts = ToastCenter()
    private(set) var library: Library
    private(set) var snapshot: LibrarySnapshot = .empty
    private(set) var rows: [String] = []
    private(set) var counts: [ViewScope: Int] = [:]
    private(set) var loadError: String?

    var sidebarSelection: ViewScope = .all {
        didSet {
            guard sidebarSelection != oldValue else { return }
            selectedItemIDs = []
            selectedFileIDs = []
            recompute()
        }
    }
    var selectedItemIDs: Set<String> = []
    var selectedFileIDs: Set<String> = []
    var search = SearchState() {
        didSet {
            guard search != oldValue else { return }
            if search.includeFulltext && search.isActive {
                scheduleFulltextSearch()
            } else {
                fulltextMatches = nil
            }
            recompute()
        }
    }
    var inspectorTab = InspectorTab.metadata
    /// Set by the sidebar to start inline renaming of a newly created group.
    var groupPendingRename: String?
    /// Bumped to ask the toolbar search field to take focus.
    var searchFocusRequest = 0
    /// Bumped to put the keyboard focus into the inspector's note editor.
    var noteFocusRequest = 0
    var activeSheet: ActiveSheet?
    // Screenshot hooks (see PreviewHooks).
    var previewExpandRequest: String?
    /// Files currently dragged over the list from Finder; > 0 shows the drop overlay (DND-01).
    var externalDropCount = 0
    var previewExpandAllGroups = false

    @ObservationIgnored private var fulltextMatches: Set<String>?
    /// Set once the first snapshot arrives. (Comparing with `.empty` misfires for an empty library.)
    @ObservationIgnored private var didLoadLibrary = false
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var fulltextTask: Task<Void, Never>?
    @ObservationIgnored lazy var importer = ImportCoordinator(model: self)
    @ObservationIgnored let citations = CitationService()
    @ObservationIgnored lazy var readers = ReaderCoordinator(model: self)
    @ObservationIgnored lazy var translations = TranslationCoordinator(model: self)
    /// The live list controller, for the simulated-drop check (see SimulatedDrop).
    @ObservationIgnored weak var itemListController: ItemListController?
    @ObservationIgnored weak var sidebarController: SidebarController?
    /// The library window, for sheets and alerts that belong to it.
    @ObservationIgnored weak var libraryWindow: NSWindow?

    enum ActiveSheet: Identifiable {
        case identifierAdd
        case manualMatch(itemId: String)
        case zoteroImport
        case tagEditor(tagId: String?, applyTo: [String], initialName: String = "")

        var id: String {
            switch self {
            case .identifierAdd: "identifier"
            case .manualMatch(let id): "match-\(id)"
            case .zoteroImport: "zotero"
            case .tagEditor(let id, _, _): "tag-\(id ?? "new")"
            }
        }
    }

    init(settings: AppSettings = AppSettings()) {
        self.settings = settings
        do {
            library = try Library(root: settings.libraryURL)
        } catch {
            loadError = error.localizedDescription
            library = try! Library.temporary()
        }
        refreshResolver()
        startObserving()
        let citations = self.citations
        Task.detached(priority: .background) {
            try? await Task.sleep(for: .seconds(2))
            await citations.warmUp()
        }
    }

    /// Rebuilds the metadata engine after retrieval settings change.
    func refreshResolver() {
        importer.resolver = EngineResolver(mailto: settings.crossrefMailto, openAlexAPIKey: settings.openAlexAPIKey)
    }

    /// Moves the whole library folder into `parent` and reopens it there (STORE-01). The database is
    /// closed first so nothing writes to the files while they move; on failure the old location is reopened.
    func relocateLibrary(into parent: URL) throws -> URL {
        let source = library.root
        let destination = parent.appending(path: source.lastPathComponent, directoryHint: .isDirectory)
        guard destination.standardizedFileURL != source.standardizedFileURL else { return source }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw LibraryError.invalidOperation("目标位置已存在同名文件夹")
        }
        // Open papers hold paths inside the library: save and close them first.
        readers.saveAll()
        readers.closeAll()
        observationTask?.cancel()
        try library.close()
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            try reopenLibrary(at: destination)
            settings.libraryPath = destination.path
            return destination
        } catch {
            try? reopenLibrary(at: source)
            throw error
        }
    }

    private func reopenLibrary(at url: URL) throws {
        library = try Library(root: url)
        didLoadLibrary = false
        snapshot = .empty
        sidebarSelection = .all
        startObserving()
    }

    private func startObserving() {
        let observation = library.observeSnapshots()
        observationTask = Task { [weak self] in
            do {
                for try await snapshot in observation {
                    self?.apply(snapshot)
                }
            } catch {
                self?.loadError = error.localizedDescription
            }
        }
    }

    private func apply(_ newSnapshot: LibrarySnapshot) {
        let firstLoad = !didLoadLibrary
        didLoadLibrary = true
        snapshot = newSnapshot
        if case .group(let id) = sidebarSelection, snapshot.groupsById[id] == nil { sidebarSelection = .all }
        if case .tag(let id) = sidebarSelection, snapshot.tagsById[id] == nil { sidebarSelection = .all }
        recompute()
        if firstLoad {
            importer.libraryDidLoad()
            readers.restoreTabs()
            PreviewHooks.apply(to: self)
            // Performance runs pass -FolioPerfLog <file> to record when the first data is on screen.
            if let log = UserDefaults.standard.string(forKey: "FolioPerfLog") {
                DispatchQueue.main.async {
                    try? "\(Date().timeIntervalSince1970) \(self.rows.count)\n".write(toFile: log, atomically: true, encoding: .utf8)
                }
            }
        }
    }

    // MARK: Derived state

    func recompute() {
        let query = ViewQuery(scope: sidebarSelection,
                              searchText: search.isActive ? search.text : "",
                              searchWholeLibrary: search.wholeLibrary,
                              fulltextItemIds: search.includeFulltext ? fulltextMatches : nil,
                              includeSubgroupItems: settings.includeSubgroupItems,
                              sort: snapshot.sort(for: sidebarSelection))
        rows = ViewResolver.rows(query, in: snapshot)
        counts = SidebarCounts.compute(snapshot, includeSubgroupItems: settings.includeSubgroupItems)
        selectedItemIDs = selectedItemIDs.filter { snapshot.items[$0] != nil }
        selectedFileIDs = selectedFileIDs.filter { snapshot.files[$0] != nil }
    }

    private func scheduleFulltextSearch() {
        fulltextTask?.cancel()
        let text = search.text
        let library = self.library
        fulltextTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let matches = await Task.detached { (try? library.fulltextItemIds(matching: text)) ?? [] }.value
            guard !Task.isCancelled, let self, self.search.text == text else { return }
            self.fulltextMatches = matches
            self.recompute()
        }
    }

    var currentSort: SortState { snapshot.sort(for: sidebarSelection) }

    var title: String {
        if search.isActive { return "「\(search.text.trimmingCharacters(in: .whitespaces))」的搜索结果" }
        return title(for: sidebarSelection)
    }

    /// Window subtitle: how many rows the list shows.
    var subtitle: String {
        rows.isEmpty ? "" : "\(rows.count) 项"
    }

    func title(for scope: ViewScope) -> String {
        switch scope {
        case .all: "所有文献"
        case .unfiled: "未分组"
        case .trash: "回收站"
        case .group(let id): snapshot.groupsById[id]?.name ?? "分组"
        case .tag(let id): "标签：\(snapshot.tagsById[id]?.name ?? "")"
        }
    }

    /// The single item the inspector describes, if any.
    var inspectedItem: Item? {
        if selectedItemIDs.count == 1, let id = selectedItemIDs.first { return snapshot.items[id] }
        if selectedItemIDs.isEmpty, selectedFileIDs.count == 1, let fileId = selectedFileIDs.first,
           let file = snapshot.files[fileId] { return snapshot.items[file.itemId] }
        return nil
    }

    var selectionCount: Int { selectedItemIDs.count + selectedFileIDs.count }

    var isUserGroupSelected: Bool { sidebarSelection.groupId != nil }

    func fileURL(_ file: FileRecord) -> URL { library.fileURL(for: file) }

    func defaultFile(of itemId: String) -> FileRecord? {
        guard let item = snapshot.items[itemId] else { return nil }
        if let id = item.defaultFileId, let file = snapshot.files[id] { return file }
        return snapshot.files(of: itemId).first
    }

    /// Groups ordered for menus: each top-level group followed by its children.
    var groupsForMenus: [(group: LibraryGroup, depth: Int)] {
        snapshot.topLevelGroups.flatMap { id -> [(LibraryGroup, Int)] in
            guard let group = snapshot.groupsById[id] else { return [] }
            return [(group, 0)] + (snapshot.childGroups[id] ?? []).compactMap { snapshot.groupsById[$0].map { ($0, 1) } }
        }
    }
}
