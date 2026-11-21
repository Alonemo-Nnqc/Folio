import SwiftUI

/// The update waiting for the user (UPD-*): a flat, quiet row at the foot of the sidebar, there only while an update
/// is found. A tinted fill instead of glass and shadow, the version in plain words and one small capsule that says
/// what a click does. One click opens the update (or, downloaded already, restarts Folio into it).
struct UpdatePill: View {
    let updater: SoftwareUpdater
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        if let update = updater.pendingUpdate {
            Button {
                updater.checkForUpdates(nil)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: update.isDownloaded ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.down.circle.fill")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Folio \(update.version)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                            .monospacedDigit()
                        Text(update.isDownloaded ? String(localized: "已下载，重启即可完成") : String(localized: "新版本可用"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(update.isDownloaded ? String(localized: "重启") : String(localized: "更新"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .frame(height: 20)
                        .background(Capsule().fill(Color.accentColor))
                }
                .padding(.leading, 8)
                .padding(.trailing, 7)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(pressed ? 0.2 : hovering ? 0.14 : 0.09)))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in pressed = true }.onEnded { _ in pressed = false })
            .animation(.easeOut(duration: 0.12), value: hovering)
            .help(update.isDownloaded ? String(localized: "Folio \(update.version) 已下载，点按重新启动并安装")
                                      : String(localized: "Folio \(update.version) 可供更新，点按查看更新内容"))
            .accessibilityIdentifier("updateButton")
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
