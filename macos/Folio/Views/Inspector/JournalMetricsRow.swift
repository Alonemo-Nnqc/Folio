import AppKit
import FolioCore
import SwiftUI

/// Tints of the journal rank capsules (META-30), drawn by `CapsuleLabel`, which darkens the text in light mode
/// and lightens it in dark mode, so one tint reads well on both.
enum JournalBadgeTint {
    /// 中科院 1 区 red, 2 区 orange, 3 区 yellow-green, 4 区 grey-green.
    static func cas(_ zone: Int) -> NSColor {
        switch zone {
        case 1: NSColor(srgbRed: 0.92, green: 0.26, blue: 0.24, alpha: 1)
        case 2: NSColor(srgbRed: 0.96, green: 0.55, blue: 0.10, alpha: 1)
        case 3: NSColor(srgbRed: 0.55, green: 0.70, blue: 0.10, alpha: 1)
        default: NSColor(srgbRed: 0.40, green: 0.60, blue: 0.52, alpha: 1)
        }
    }

    /// JCR / SSCI quartiles: blues that fade with the quartile.
    static func quartile(_ quartile: Int) -> NSColor {
        switch quartile {
        case 1: NSColor(srgbRed: 0.10, green: 0.45, blue: 0.95, alpha: 1)
        case 2: NSColor(srgbRed: 0.18, green: 0.62, blue: 0.86, alpha: 1)
        case 3: NSColor(srgbRed: 0.30, green: 0.66, blue: 0.70, alpha: 1)
        default: NSColor(srgbRed: 0.50, green: 0.56, blue: 0.62, alpha: 1)
        }
    }

    static func color(for kind: JournalMetrics.BadgeKind) -> NSColor {
        switch kind {
        case .cas(let zone): cas(zone)
        case .quartile(let value): quartile(value)
        case .impactFactor: NSColor(srgbRed: 0.62, green: 0.36, blue: 0.86, alpha: 1)
        case .impactFactor5Year: NSColor(srgbRed: 0.45, green: 0.42, blue: 0.84, alpha: 1)
        case .ccf: NSColor(srgbRed: 0.05, green: 0.65, blue: 0.60, alpha: 1)
        case .index: NSColor(srgbRed: 0.52, green: 0.52, blue: 0.56, alpha: 1)
        case .warning: NSColor(srgbRed: 0.88, green: 0.22, blue: 0.20, alpha: 1)
        }
    }

    static let font = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let emphasizedFont = NSFont.systemFont(ofSize: 11, weight: .bold)
}

/// The line of rank capsules under 来源 in the inspector, or a quiet hint when there is nothing to show yet.
struct JournalMetricsRow: View {
    let model: AppModel
    let item: Item
    @State private var hovering = false

    var body: some View {
        if JournalMetrics.journalName(of: item) != nil {
            content
                .padding(.leading, 64)
                .padding(.top, -2)
                .onHover { hovering = $0 }
                .animation(.smooth(duration: 0.2), value: model.snapshot.journalMetrics(for: item))
        }
    }

    @ViewBuilder private var content: some View {
        let coordinator = model.journalMetrics
        if let metrics = model.snapshot.journalMetrics(for: item) {
            let badges = metrics.badges
            if badges.isEmpty {
                hint(String(localized: "easyScholar 未收录该期刊"), symbol: nil, action: nil)
                    .help(String(localized: "按期刊名「\(item.source ?? "")」没有查到分区信息，可核对期刊全称后刷新"))
                    .contextMenu { refreshMenu }
            } else {
                FlowLayout(spacing: 5) {
                    ForEach(badges) { badge in
                        CapsuleText(text: badge.text, tint: JournalBadgeTint.color(for: badge.kind),
                                    font: badge.emphasized ? JournalBadgeTint.emphasizedFont : JournalBadgeTint.font)
                            .help(badge.detail)
                    }
                    refreshButton
                        .opacity(hovering ? 1 : 0)
                }
                .contextMenu {
                    refreshMenu
                    Button("拷贝期刊指标") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(metrics.summary, forType: .string)
                    }
                }
                .transition(.opacity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(String(localized: "期刊指标：\(metrics.summary)"))
            }
        } else if !coordinator.hasKey {
            hint(String(localized: "设置期刊指标…"), symbol: "chart.bar.xaxis") { JournalMetricsCoordinator.openSettings() }
                .help(String(localized: "填写 easyScholar 密钥后，这里会显示中科院分区、JCR 分区与影响因子"))
        } else if case .invalidKey = coordinator.status.problem {
            hint(String(localized: "easyScholar 密钥无效"), symbol: "exclamationmark.triangle") { JournalMetricsCoordinator.openSettings() }
        } else if coordinator.isPending(item) {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("正在获取期刊指标…")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        } else {
            hint(String(localized: "获取期刊指标"), symbol: "arrow.clockwise") { coordinator.refresh(itemIds: [item.id]) }
        }
    }

    private var refreshButton: some View {
        Button {
            model.journalMetrics.refresh(itemIds: [item.id])
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("刷新期刊指标")
    }

    @ViewBuilder private var refreshMenu: some View {
        Button("刷新期刊指标") { model.journalMetrics.refresh(itemIds: [item.id]) }
    }

    /// A light line of text, clickable when it leads somewhere.
    private func hint(_ text: String, symbol: String?, action: (() -> Void)?) -> some View {
        HintLink(text: text, symbol: symbol, action: action)
    }
}

private struct HintLink: View {
    let text: String
    let symbol: String?
    let action: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        let label = HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text).underline(hovering && action != nil)
        }
        .font(.caption)
        .foregroundStyle(hovering && action != nil ? .secondary : .tertiary)
        if let action {
            Button(action: action) { label }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
        } else {
            label
        }
    }
}
