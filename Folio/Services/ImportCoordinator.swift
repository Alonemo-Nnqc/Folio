import AppKit
import FolioCore

/// Drives imports end to end: copying files in, metadata retrieval (max 4 at once), duplicate
/// prompts, network-recovery retries, full-text indexing and trash auto-purge.
final class ImportCoordinator {
    private weak var model: AppModel?
    var resolver: any MetadataResolving = UnavailableResolver()

    private let maxConcurrent = 4
    private let maxNetworkRetries = 3
    private var queue: [String] = []
    private var queued: Set<String> = []
    private var running = 0
    private var failedNames: [String] = []
    private var failureToastTask: Task<Void, Never>?
    private var indexing = false
    private var purgeTimer: Timer?
    private let networkMonitor = NetworkMonitor()
    private let prompter = DuplicatePrompter()

    init(model: AppModel) {
        self.model = model
    }

    private var library: Library? { model?.library }
    private var autoRename: Bool { model?.settings.autoRenameFiles ?? true }

    // MARK: Lifecycle

    func libraryDidLoad() {
        guard let snapshot = model?.snapshot else { return }
        for item in snapshot.items.values where !item.isTrashed && item.kind == .standalone
            && (item.metadataState == .pending || (item.metadataState == .networkFailed && item.retryCount < maxNetworkRetries)) {
            enqueue(item.id)
        }
        networkMonitor.onReconnect = { [weak self] in self?.retryNetworkFailures() }
        networkMonitor.start()
        indexFulltext()
        purgeTrashIfNeeded()
        purgeTimer?.invalidate()
        purgeTimer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.purgeTrashIfNeeded() }
        }
    }

    /// Called when the app becomes active: picks up PDFs edited elsewhere (FILE-08).
    func refreshChangedFiles() {
        guard let library else { return }
        Task {
            let changed = await Task.detached(priority: .utility) { (try? library.refreshFingerprints()) ?? [] }.value
            if !changed.isEmpty { indexFulltext() }
        }
    }

    // MARK: Importing (DND-01/02, META-01, DUP-01/02)

    func importFiles(_ urls: [URL], toGroup groupId: String?) {
        guard let library, !urls.isEmpty else { return }
        Task {
            let files = Self.expand(urls)
            guard !files.isEmpty else {
                model?.toasts.show("没有找到可导入的文件", systemImage: "doc.questionmark")
                return
            }
            let outcomes = await Task.detached(priority: .userInitiated) {
                (try? library.importFiles(files, toGroup: groupId)) ?? []
            }.value
            handle(outcomes, groupId: groupId)
        }
    }

    private func handle(_ outcomes: [ImportOutcome], groupId: String?) {
        guard let model else { return }
        for outcome in outcomes {
            switch outcome {
            case .imported(let id, let isPDF):
                if isPDF {
                    enqueue(id)
                    indexFulltext()
                }
            case .duplicateFile(let existing, let addedToGroup):
                let title = model.snapshot.items[existing]?.title ?? ""
                if addedToGroup, let groupId, let name = model.snapshot.groupsById[groupId]?.name {
                    model.toasts.show("已有该文献，已加入「\(name)」", systemImage: "doc.on.doc")
                } else {
                    model.toasts.show("已有该文献「\(title)」", systemImage: "doc.on.doc")
                }
            case .duplicateInTrash(let existing):
                let title = model.snapshot.items[existing]?.title ?? ""
                prompter.askRestore(title: title) { [weak model] restore in
                    if restore { model?.restoreItems([existing]) }
                }
            case .failed(let url, let reason):
                model.toasts.show("无法添加「\(url.lastPathComponent)」：\(reason)", systemImage: "exclamationmark.triangle")
            }
        }
    }

    func attachFiles(_ urls: [URL], to itemId: String) {
        guard let library else { return }
        let rename = autoRename
        Task {
            let outcomes = await Task.detached { (try? library.addFiles(urls, toItem: itemId, autoRename: rename)) ?? [] }.value
            let added = outcomes.filter { if case .added = $0 { true } else { false } }.count
            if outcomes.contains(where: { if case .duplicate = $0 { true } else { false } }) {
                model?.toasts.show("已有该文献", systemImage: "doc.on.doc")
            } else if added > 0 {
                model?.toasts.show(added == 1 ? "已添加文件" : "已添加 \(added) 个文件", systemImage: "paperclip")
            }
        }
    }

    /// Folders are searched recursively for PDFs; files are taken as they are.
    nonisolated static func expand(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
                                                                options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let file = enumerator?.nextObject() as? URL {
                    if file.pathExtension.lowercased() == "pdf" { result.append(file) }
                }
            } else {
                result.append(url)
            }
        }
        return result
    }

    // MARK: Retrieval (META-01…07)

    func retrieve(itemId: String) {
        guard let item = model?.snapshot.items[itemId] else { return }
        if item.kind == .standalone {
            try? library?.setMetadataState(.pending, for: itemId)
            enqueue(itemId)
        } else {
            refreshRegularItem(item)
        }
    }

    private func enqueue(_ id: String) {
        guard !queued.contains(id) else { return }
        queued.insert(id)
        queue.append(id)
        pump()
    }

    private func pump() {
        while running < maxConcurrent, !queue.isEmpty {
            let id = queue.removeFirst()
            running += 1
            Task {
                await resolveStandalone(id)
                running -= 1
                queued.remove(id)
                pump()
            }
        }
    }

    private func resolveStandalone(_ id: String) async {
        guard let model, let library, let item = model.snapshot.items[id] ?? (try? library.item(id)),
              item.kind == .standalone, let file = try? library.files(ofItem: id).first else { return }
        if item.metadataState != .pending { try? library.setMetadataState(.pending, for: id) }
        let url = library.fileURL(for: file)
        let resolver = self.resolver
        let result = await Task.detached(priority: .userInitiated) { await resolver.resolvePDF(at: url) }.value
        switch result {
        case .found(let metadata):
            apply(metadata, toStandalone: id)
        case .notFound:
            try? library.setMetadataState(.failed, for: id)
            reportFailure(item.title)
        case .networkError:
            try? library.setMetadataState(.networkFailed, for: id, incrementRetry: true)
            reportFailure(item.title)
        }
    }

    /// Turns a standalone file into an item, or asks what to do when the work already exists (DUP-03).
    func apply(_ metadata: Metadata, toStandalone id: String) {
        guard let model, let library else { return }
        let rename = autoRename
        do {
            switch try library.applyMetadata(metadata, toStandalone: id, autoRename: rename) {
            case .created:
                break
            case .duplicateItem(let existing):
                let title = model.snapshot.items[existing]?.title ?? metadata.title
                try? library.setMetadataState(.none, for: id)
                prompter.askDuplicateItem(title: title) { [weak model] choice in
                    guard let model else { return }
                    model.perform {
                        switch choice {
                        case .attach: try model.library.mergeStandalone(id, intoItem: existing, autoRename: rename)
                        case .discard: try model.library.discardStandalone(id)
                        }
                    }
                }
            }
        } catch {
            model.toasts.show("无法创建条目：\(error.localizedDescription)", systemImage: "exclamationmark.triangle")
        }
    }

    private func refreshRegularItem(_ item: Item) {
        guard let library else { return }
        let resolver = self.resolver
        let identifier = item.doi ?? item.arxivId ?? item.isbn
        let title = item.title
        let rename = autoRename
        model?.toasts.show("正在重新检索元数据…", systemImage: "arrow.clockwise")
        Task {
            let result: RetrievalResult = await Task.detached {
                if let identifier, !identifier.isEmpty { return await resolver.resolve(identifier: identifier) }
                if let best = await resolver.search(title).first,
                   TitleNormalizer.similarity(best.title, title) >= 0.9 { return .found(best) }
                return .notFound
            }.value
            switch result {
            case .found(let metadata):
                model?.perform { try library.updateMetadata(item.id, metadata, autoRename: rename) }
                model?.toasts.show("元数据已更新", systemImage: "checkmark.circle")
            case .notFound:
                model?.toasts.show("未检索到该条目的元数据", systemImage: "questionmark.circle")
            case .networkError:
                model?.toasts.show("网络不可用，请稍后重试", systemImage: "wifi.slash")
            }
        }
    }

    private func retryNetworkFailures() {
        guard let snapshot = model?.snapshot else { return }
        for item in snapshot.items.values where !item.isTrashed && item.kind == .standalone
            && item.metadataState == .networkFailed && item.retryCount < maxNetworkRetries {
            try? library?.setMetadataState(.pending, for: item.id)
            enqueue(item.id)
        }
    }

    /// Batches "not found" notices so a big import produces a single toast (META-04).
    private func reportFailure(_ name: String) {
        failedNames.append(name)
        failureToastTask?.cancel()
        failureToastTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            let names = self.failedNames
            self.failedNames = []
            let message = names.count == 1 ? "未检索到「\(names[0])」的元数据，已保留为独立文件"
                : "\(names.count) 个文件未检索到元数据，已保留为独立文件"
            self.model?.toasts.show(message, systemImage: "questionmark.circle")
        }
    }

    // MARK: Full-text index (SEARCH-04) and trash purge (TRASH-07)

    func indexFulltext() {
        guard !indexing, let library else { return }
        indexing = true
        Task {
            await Task.detached(priority: .utility) {
                let files = (try? library.filesNeedingFulltext()) ?? []
                for file in files {
                    let url = library.fileURL(for: file)
                    if let text = PDFTextExtractor.fullText(of: url) {
                        try? library.setFulltext(fileId: file.id, text: text)
                    } else {
                        try? library.markFulltextNotApplicable(fileId: file.id)
                    }
                }
            }.value
            indexing = false
            if !((try? library.filesNeedingFulltext()) ?? []).isEmpty { indexFulltext() }
        }
    }

    func purgeTrashIfNeeded() {
        guard let model, model.settings.autoPurgeTrash else { return }
        try? model.library.purgeTrash(olderThan: Date().addingTimeInterval(-30 * 24 * 3600))
    }
}
