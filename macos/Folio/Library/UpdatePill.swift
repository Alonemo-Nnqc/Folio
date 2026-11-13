import SwiftUI

/// The update waiting for the user (UPD-*): a small glass card at the foot of the sidebar, out of the way of the
/// toolbar and the reading, there only while an update is found. One click opens the update (or, downloaded already,
/// restarts Folio into it).
struct UpdatePill: View {
    let updater: SoftwareUpdater
    @State private var hovering = false

    var body: some View {
        if let update = updater.pendingUpdate {
            Button {
                updater.checkForUpdates(nil)
            } label: {
                HStack(spacing: 9) {
                    ZStack {
                        Circle().fill(Color.accentColor.gradient)
                        Image(systemName: update.isDownloaded ? "arrow.clockwise" : "arrow.down")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(update.isDownloaded ? String(localized: "重新启动以更新") : String(localized: "有新版本可用"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("Folio \(update.version)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .opacity(hovering ? 1 : 0.6)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .glassBackground(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(hovering ? 1.015 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
            .help(update.isDownloaded ? String(localized: "Folio \(update.version) 已下载，点按重新启动并安装")
                                      : String(localized: "Folio \(update.version) 可供更新"))
            .accessibilityIdentifier("updateButton")
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
