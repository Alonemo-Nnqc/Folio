import AppKit
import FolioCore
import Observation

/// Queues whole-document translations and files the results under their items (TRANS-01…06).
@Observable
final class TranslationCoordinator {
    /// Progress of a queued or running translation, keyed by item id.
    struct JobState: Equatable {
        var fileId: String
        var fraction: Double?
        var stage: String
    }

    private(set) var jobs: [String: JobState] = [:]
    @ObservationIgnored private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
    }

    var activeItemIds: Set<String> { Set(jobs.keys) }

    func requestTranslation(fileId: String) {
        model?.toasts.show("翻译功能正在接入", systemImage: "character.book.closed")
    }

    func cancel(itemId: String) {
        jobs[itemId] = nil
    }
}
