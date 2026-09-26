import Foundation
import Observation

/// Short, non-blocking notices shown as a glass capsule at the bottom of the window (UI-04).
@Observable
final class ToastCenter {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var message: String
        var systemImage: String
    }

    private(set) var current: Toast?
    private var dismissTask: Task<Void, Never>?

    func show(_ message: String, systemImage: String = "info.circle") {
        if current?.message == message {
            scheduleDismiss()
            return
        }
        current = Toast(message: message, systemImage: systemImage)
        scheduleDismiss()
    }

    func dismiss() {
        current = nil
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }
}
