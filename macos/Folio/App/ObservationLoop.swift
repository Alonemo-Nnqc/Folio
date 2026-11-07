import Foundation
import Observation

/// Re-runs `apply` whenever an `@Observable` property it read changes — the AppKit counterpart of
/// SwiftUI's automatic view updates. Changes in one run-loop turn are coalesced into one call.
final class ObservationLoop {
    private var isActive = true
    private var isScheduled = false
    private let apply: () -> Void

    @discardableResult
    init(_ apply: @escaping () -> Void) {
        self.apply = apply
        run()
    }

    func cancel() { isActive = false }

    private func run() {
        guard isActive else { return }
        isScheduled = false
        withObservationTracking(apply) { [weak self] in
            DispatchQueue.main.async { self?.schedule() }
        }
    }

    private func schedule() {
        guard !isScheduled else { return }
        isScheduled = true
        run()
    }
}
