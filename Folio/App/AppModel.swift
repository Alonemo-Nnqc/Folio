import AppKit
import FolioCore
import Observation

/// Search state behind the sidebar search field (SEARCH-01…05).
struct SearchState: Equatable {
    var isVisible = false
    var text = ""
    var wholeLibrary = false
    var includeFulltext = false

    var isActive: Bool { isVisible && !text.trimmingCharacters(in: .whitespaces).isEmpty }
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
    var showInspector = true
    /// Set by the sidebar to start inline renaming of a newly created group.
    var groupPendingRename: String?
    /// Bumped to ask the sidebar search field to take focus.
    var searchFocusRequest = 0
    var activeSheet: ActiveSheet?
    // Screenshot hooks (see PreviewHooks).
    var previewExpandRequest: String?
    var previewInspectorTab: String?
    var previewDropCount = 0
    var previewExpandAllGroups = false
    var previewOpenSettings = false

    @ObservationIgnored private var fulltextMatches: Set<String>?
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var fulltextTask: Task<Void, Never>?
    @ObservationIgnored lazy var importer = ImportCoordinator(model: self)
    @ObservationIgnored let citations = CitationService()

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

    /// Re-opens the library at a new location (settings → 文献库位置).
    func reopenLibrary(at url: URL) throws {
        let newLibrary = try Library(root: url)
        observationTask?.cancel()
        library = newLibrary
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
        let firstLoad = snapshot == .empty
        snapshot = newSnapshot
        if case .group(let id) = sidebarSelection, snapshot.groupsById[id] == nil { sidebarSelection = .all }
        if case .tag(let id) = sidebarSelection, snapshot.tagsById[id] == nil { sidebarSelection = .all }
        recompute()
        if firstLoad {
            importer.libraryDidLoad()
            PreviewHooks.apply(to: self)
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
