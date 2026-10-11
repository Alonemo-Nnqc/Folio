import Foundation
import Observation

/// Short, non-blocking notices shown as a glass capsule at the bottom of the window (UI-04).
@Observable
final class ToastCenter {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var message: String
        var systemImage: String
        /// An optional button in the capsule ("打开译文").
        var actionTitle: String?
        var action: (() -> Void)?

        static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
    }

    private(set) var current: Toast?
    private var dismissTask: Task<Void, Never>?

    func show(_ message: String, systemImage: String = "info.circle", actionTitle: String? = nil,
              action: (() -> Void)? = nil) {
        if current?.message == message && actionTitle == nil {
            scheduleDismiss()
            return
        }
        current = Toast(message: message, systemImage: systemImage, actionTitle: actionTitle, action: action)
        // Toasts with a button stay a little longer so there is time to use it.
        scheduleDismiss(after: actionTitle == nil ? 2.5 : 6)
    }

    func dismiss() {
        current = nil
    }

    private func scheduleDismiss(after seconds: Double = 2.5) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }
}
