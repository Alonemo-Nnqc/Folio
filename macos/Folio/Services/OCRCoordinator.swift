import AppKit
import FolioCore
import FolioTranslate
import Observation

extension Notification.Name {
    /// A file's text was recognised and the file replaced (`userInfo["fileId"]`): readers showing it load it again.
    static let folioFileRecognized = Notification.Name("FolioFileRecognized")
}

/// 扫描件识别 (OCR-01): scanned PDFs get an invisible text layer (Vision, Chinese and English) so they can be selected,
/// searched, translated and their metadata found. One file at a time; a new scan is queued by itself after import,
/// others from the reader's banner or the file's menu. The file is replaced in place once the result is checked
/// (`PDFTextRecognizer`); the original is kept in `.ocr-backup/` until the new one is in place.
@MainActor @Observable
final class OCRCoordinator {
    struct Progress: Equatable {
        var done = 0
        var total = 0
        var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    }

    /// Files queued or being recognised, with how far they are.
    private(set) var jobs: [String: Progress] = [:]
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var current: (fileId: String, task: Task<PDFTextRecognizer.Summary, Error>)?
    /// Whether a file (by its hash) is a scan: asked once per version of the file.
    @ObservationIgnored private var scanned: [String: Bool] = [:]
    /// Those waiting for a file to be done (整篇翻译 of a scan), and who follows its progress.
    @ObservationIgnored private var waiters: [String: [CheckedContinuation<Void, Error>]] = [:]
    @ObservationIgnored private var listeners: [String: [(Progress) -> Void]] = [:]

    init(model: AppModel) {
        self.model = model
    }

    func isRecognizing(_ fileId: String) -> Bool { jobs[fileId] != nil }

    /// Whether the file is a scan without text (looked at off the main thread, remembered per file version).
    func isScanned(fileId: String) async -> Bool {
        guard let model, let file = model.snapshot.files[fileId], file.isPDF else { return false }
        let key = "\(fileId)|\(file.sha256)"
        if let known = scanned[key] { return known }
        let url = model.fileURL(file)
        let result = await Task.detached(priority: .utility) { ScannedPDF.isScanned(url) }.value
        scanned[key] = result
        return result
    }

    /// After import: a scan is recognised by itself (its metadata is looked for again afterwards).
    func recognizeIfScanned(itemId: String) {
        Task {
            // The import is in the database before it is in the snapshot: wait for it a little.
            var file: FileRecord?
            for _ in 0..<50 {
                file = model?.snapshot.files(of: itemId).first(where: \.isPDF)
                if file != nil { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if let file, await isScanned(fileId: file.id) { recognize(fileId: file.id) }
        }
    }

    /// Queues a file (the reader's banner, 识别文字（OCR）).
    func recognize(fileId: String) {
        guard jobs[fileId] == nil else { return }
        jobs[fileId] = Progress()
        queue.append(fileId)
        startIfNeeded()
    }

    /// Recognises the file (or waits for it, when it is already queued) and returns once it has been replaced.
    /// `progress` follows the pages. Throws what made recognition fail.
    func recognizeAndWait(fileId: String, progress: @escaping (Progress) -> Void = { _ in }) async throws {
        listeners[fileId, default: []].append(progress)
        try await withCheckedThrowingContinuation { continuation in
            waiters[fileId, default: []].append(continuation)
            recognize(fileId: fileId)
        }
    }

    private func finish(_ fileId: String, _ error: Error?) {
        listeners[fileId] = nil
        for waiter in waiters.removeValue(forKey: fileId) ?? [] {
            if let error { waiter.resume(throwing: error) } else { waiter.resume() }
        }
    }

    func cancel(fileId: String) {
        queue.removeAll { $0 == fileId }
        if current?.fileId == fileId { current?.task.cancel() }
        jobs[fileId] = nil
        finish(fileId, CancellationError())
    }

    private func startIfNeeded() {
        guard worker == nil, !queue.isEmpty else { return }
        worker = Task { [weak self] in
            while let self, !self.queue.isEmpty {
                let fileId = self.queue.removeFirst()
                await self.run(fileId)
            }
            self?.worker = nil
        }
    }

    private func run(_ fileId: String) async {
        guard let model, let file = model.snapshot.files[fileId] else { jobs[fileId] = nil; finish(fileId, CocoaError(.fileNoSuchFile)); return }
        let url = model.fileURL(file)
        let library = model.library
        let temp = url.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).folio-ocr.pdf")
        let task = Task.detached(priority: .utility) {
            try await PDFTextRecognizer.recognize(input: url, output: temp) { done, total in
                Task { @MainActor [weak self] in
                    guard let self, self.jobs[fileId] != nil else { return }
                    let progress = Progress(done: done, total: total)
                    self.jobs[fileId] = progress
                    self.listeners[fileId]?.forEach { $0(progress) }
                }
            }
        }
        current = (fileId, task)
        defer { current = nil; jobs[fileId] = nil }
        do {
            _ = try await task.value
            try Self.replace(url, with: temp, backupFolder: library.root.appending(path: ".ocr-backup"), name: fileId)
            scanned = scanned.filter { !$0.key.hasPrefix(fileId + "|") }
            jobs[fileId] = nil
            NotificationCenter.default.post(name: .folioFileRecognized, object: nil, userInfo: ["fileId": fileId])
            // Fingerprint and full-text index follow the new file; a paper still without metadata is looked up again.
            model.importer.refreshChangedFiles()
            if let item = model.snapshot.items[file.itemId], item.kind == .standalone, item.metadataState != .pending {
                model.importer.retrieve(itemId: item.id)
            }
            let quiet = waiters[fileId]?.isEmpty == false
            finish(fileId, nil)
            if !quiet { model.toasts.show(String(localized: "已识别「\(file.fileName)」的文字"), systemImage: "text.viewfinder") }
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: temp)
            finish(fileId, CancellationError())
        } catch {
            try? FileManager.default.removeItem(at: temp)
            let quiet = waiters[fileId]?.isEmpty == false
            finish(fileId, error)
            if !quiet { model.toasts.show(String(localized: "无法识别「\(file.fileName)」的文字：\(error.localizedDescription)"), systemImage: "exclamationmark.triangle") }
        }
    }

    /// The original goes to the backup folder first, the new file takes its place, and the backup is removed once
    /// that worked (it is put back if it did not).
    nonisolated static func replace(_ url: URL, with new: URL, backupFolder: URL, name: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: backupFolder, withIntermediateDirectories: true)
        let backup = backupFolder.appending(path: "\(name).pdf")
        try? fm.removeItem(at: backup)
        try fm.copyItem(at: url, to: backup)
        do {
            _ = try fm.replaceItemAt(url, withItemAt: new)
        } catch {
            if !fm.fileExists(atPath: url.path) { try? fm.copyItem(at: backup, to: url) }
            throw error
        }
        try? fm.removeItem(at: backup)
        if (try? fm.contentsOfDirectory(atPath: backupFolder.path))?.isEmpty == true { try? fm.removeItem(at: backupFolder) }
    }
}
