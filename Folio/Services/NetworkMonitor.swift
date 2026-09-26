import Foundation
import Network

/// Calls `onReconnect` on the main actor whenever connectivity comes back (META-05).
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private var wasSatisfied = true
    private var started = false
    var onReconnect: (() -> Void)?

    /// Idempotent: an NWPathMonitor may only be started once.
    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                if satisfied && !self.wasSatisfied { self.onReconnect?() }
                self.wasSatisfied = satisfied
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.nnqc.Folio.network"))
    }

    deinit { monitor.cancel() }
}
