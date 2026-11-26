import SwiftUI

/// Liquid Glass panel shown while files from Finder hover over the list (DND-01).
struct DropOverlay: View {
    let fileCount: Int
    var hasFolders = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounce = 0

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: hasFolders ? "folder.badge.plus" : "doc.badge.plus")
                .font(.system(size: 46, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .symbolEffect(.bounce, options: .repeating.speed(0.6), value: bounce)
            Text(hasFolders ? String(localized: "松开以导入文件夹") : fileCount > 1 ? String(localized: "松开以添加 \(fileCount) 个文件") : String(localized: "松开以添加文件"))
                .font(.title3.weight(.semibold))
            Text(hasFolders ? "文件夹成为分组，子文件夹成为子分组；拖到侧边栏可选择位置和级别" : "PDF 会自动检索元数据并创建条目")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: 420)
        .glassBackground(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                .foregroundStyle(.tint.opacity(0.6))
                .padding(8)
        }
        .onAppear { if !reduceMotion { bounce += 1 } }
        .accessibilityIdentifier("dropOverlay")
    }
}
