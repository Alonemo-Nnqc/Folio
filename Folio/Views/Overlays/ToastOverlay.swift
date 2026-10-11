import SwiftUI

/// Bottom-centred glass capsule for short notices (UI-04).
struct ToastOverlay: View {
    let center: ToastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let toast = center.current {
                HStack(spacing: 12) {
                    Label(toast.message, systemImage: toast.systemImage)
                        .lineLimit(2)
                    if let title = toast.actionTitle, let action = toast.action {
                        Button(title) {
                            center.dismiss()
                            action()
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                    }
                }
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: Capsule())
                    .onTapGesture { center.dismiss() }
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
                    .accessibilityIdentifier("toast")
            }
        }
        .padding(.bottom, 24)
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.2), value: center.current)
    }
}
