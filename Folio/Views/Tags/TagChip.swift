import FolioCore
import SwiftUI

/// A coloured tag capsule, truncated with "…" past ~6 CJK characters (TAG-05).
struct TagChip: View {
    let tag: Tag
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 3) {
            Text(tag.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 90, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("移除标签")
                .accessibilityLabel("移除标签 \(tag.name)")
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .foregroundStyle(Color(hex: tag.colorHex))
        .background(Color(hex: tag.colorHex).opacity(0.18), in: Capsule())
        .overlay(Capsule().strokeBorder(Color(hex: tag.colorHex).opacity(0.5), lineWidth: 0.75))
        .help(tag.name)
    }
}
