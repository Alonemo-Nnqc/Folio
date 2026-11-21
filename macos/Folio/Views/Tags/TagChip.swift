import FolioCore
import SwiftUI

/// A coloured tag capsule, truncated with "…" past ~6 CJK characters (TAG-05). Drawn like the list's chips
/// (`CapsuleLabel`), so the text is optically centred and both places look the same.
struct TagChip: View {
    let tag: Tag
    var onRemove: (() -> Void)?

    var body: some View {
        CapsuleText(text: tag.name, tint: NSColor(hex: tag.colorHex), dot: true,
                    maxTextWidth: TagChipsView.maxChipWidth - 2 * CapsuleLabel.tagPadding) {
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7.5, weight: .bold))
                        .frame(width: 10, height: 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("移除标签")
                .accessibilityLabel(String(localized: "移除标签 \(tag.name)"))
            }
        }
        .help(tag.name)
    }
}

/// The "默认" badge after a file name in the inspector.
struct DefaultFileBadge: View {
    var body: some View {
        CapsuleText(text: String(localized: "默认"), tint: .controlAccentColor, font: CapsuleLabel.badgeFont, height: CapsuleLabel.badgeHeight,
                    padding: CapsuleLabel.badgePadding)
    }
}

/// Tinted capsule with optically centred text and optional trailing controls.
struct CapsuleText<Trailing: View>: View {
    let text: String
    let tint: NSColor
    var font = CapsuleLabel.tagFont
    var height = CapsuleLabel.tagHeight
    var padding = CapsuleLabel.tagPadding
    /// A tag: a capsule tinted with its colour. Otherwise a badge, a small rounded rectangle.
    var dot = false
    var maxTextWidth: CGFloat = .infinity
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        let textColor = CapsuleLabel.textColor(resolved(tint), dark: dark)
        HStack(spacing: 3) {
            Image(nsImage: CapsuleLabel.textImage(text, font: font, color: textColor, height: height, maxWidth: maxTextWidth))
                .accessibilityLabel(text)
            trailing()
                .foregroundStyle(Color(nsColor: textColor))
        }
        .padding(.horizontal, padding)
        .frame(height: height)
        .background(Color(nsColor: dot ? CapsuleLabel.tagFill(tint, dark: dark) : CapsuleLabel.fill(tint, dark: dark)),
                    in: RoundedRectangle(cornerRadius: dot ? height / 2 : CapsuleLabel.badgeRadius, style: .continuous))
        .fixedSize()
    }

    /// Dynamic colours (the accent colour) as concrete RGB for the current appearance.
    private func resolved(_ color: NSColor) -> NSColor {
        var result = color
        NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB) ?? color
        }
        return result
    }
}

extension CapsuleText where Trailing == EmptyView {
    init(text: String, tint: NSColor, font: NSFont = CapsuleLabel.tagFont, height: CGFloat = CapsuleLabel.tagHeight,
         padding: CGFloat = CapsuleLabel.tagPadding, dot: Bool = false) {
        self.init(text: text, tint: tint, font: font, height: height, padding: padding, dot: dot, trailing: { EmptyView() })
    }
}
