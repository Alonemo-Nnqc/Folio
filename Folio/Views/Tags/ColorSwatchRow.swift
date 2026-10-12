import AppKit
import SwiftUI

/// A row of colour swatches like Reminders' list colours: the presets, then one more swatch of the
/// same size for a custom colour that opens the system colour panel. The chosen swatch gets a ring.
struct ColorSwatchRow: View {
    @Binding var hex: String?
    /// Offer a "none" swatch first (groups: back to the accent colour).
    var allowsNone = false
    var diameter: CGFloat = 18
    @State private var panel = ColorPanelBridge()

    private var isCustom: Bool {
        guard let hex else { return false }
        return !TagPalette.presets.contains { $0.hex.caseInsensitiveCompare(hex) == .orderedSame }
    }

    var body: some View {
        HStack(spacing: 6) {
            if allowsNone {
                swatch(selected: hex == nil, help: "默认（强调色）") {
                    Circle().fill(Color.accentColor)
                        .overlay(Image(systemName: "folder.fill").font(.system(size: diameter * 0.42)).foregroundStyle(.white))
                } action: { hex = nil }
            }
            ForEach(TagPalette.presets, id: \.hex) { preset in
                swatch(selected: hex?.caseInsensitiveCompare(preset.hex) == .orderedSame, help: preset.name) {
                    Circle().fill(Color(hex: preset.hex))
                } action: { hex = preset.hex }
            }
            swatch(selected: isCustom, help: "自定义颜色…") {
                if isCustom, let hex {
                    Circle().fill(Color(hex: hex))
                } else {
                    Circle().fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .mint, .blue, .indigo, .purple, .pink, .red],
                                                  center: .center))
                }
            } action: {
                panel.show(initial: hex.map(NSColor.init(hex:)) ?? .systemBlue) { color in hex = color.hexString }
            }
        }
        .onDisappear { panel.close() }
    }

    private func swatch<Fill: View>(selected: Bool, help: String, @ViewBuilder fill: () -> Fill,
                                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            fill()
                .frame(width: diameter, height: diameter)
                .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                .padding(3)
                .overlay {
                    if selected { Circle().strokeBorder(Color.primary.opacity(0.55), lineWidth: 2) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Drives the shared NSColorPanel for one swatch row.
@MainActor
final class ColorPanelBridge: NSObject {
    private var onChange: ((NSColor) -> Void)?

    func show(initial: NSColor, onChange: @escaping (NSColor) -> Void) {
        self.onChange = nil
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = initial
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        self.onChange = onChange
        panel.orderFront(nil)
    }

    func close() {
        guard onChange != nil else { return }
        onChange = nil
        NSColorPanel.shared.setTarget(nil)
        NSColorPanel.shared.setAction(nil)
        NSColorPanel.shared.orderOut(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        onChange?(sender.color)
    }
}
