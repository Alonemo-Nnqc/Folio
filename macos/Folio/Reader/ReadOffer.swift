import AppKit
import Observation
import SwiftUI

/// What the reader offers at the end of a paper: marking it read (never done by itself).
@Observable
final class ReadOfferState {
    var isShown = false
    var accept: () -> Void = {}
    /// Offered once while the paper is open, whatever the answer.
    @ObservationIgnored var wasOffered = false
}

/// A glass capsule at the foot of the pages: a full ring, "读完了？" and 标为已读.
struct ReadOfferBanner: View {
    @Bindable var state: ReadOfferState

    var body: some View {
        Group {
            if state.isShown {
                HStack(spacing: 10) {
                    Image(nsImage: ReadingRing.image(.reading, fraction: 1, size: 17))
                        .accessibilityHidden(true)
                    Text("看到最后一页了").font(.callout)
                    Button("标为已读") {
                        state.accept()
                        withAnimation(.smooth(duration: 0.2)) { state.isShown = false }
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("markAsRead")
                    Button {
                        withAnimation(.smooth(duration: 0.2)) { state.isShown = false }
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "关闭"))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .modifier(GlassCapsule())
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: state.isShown)
    }
}

/// The banner's host: as large as the capsule (nothing while it is hidden), so the pages around it stay usable. It does not
/// look into what SwiftUI draws to tell empty space: SwiftUI's buttons are no views of their own there, and were taken for it.
final class ReadOfferHost: NSHostingView<ReadOfferBanner> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
