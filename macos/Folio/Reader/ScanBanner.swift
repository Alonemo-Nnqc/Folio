import AppKit
import Observation
import SwiftUI

/// What the reader's scan banner shows (OCR-01).
@Observable
final class ScanBannerState {
    /// The paper is a scan without text.
    var isScan = false
    /// Recognition under way: pages done of pages to do.
    var progress: OCRCoordinator.Progress?
    var recognize: () -> Void = {}
    var cancel: () -> Void = {}
    var dismiss: () -> Void = {}
    var dismissed = false
    /// 编辑 PDF 文字 is on: the bar says so and finishes it.
    var editing = false
    var finishEditing: () -> Void = {}

    var isVisible: Bool { editing || (isScan && !dismissed) || progress != nil }
}

/// A glass capsule at the top of the pages: "这是扫描件，识别文字后即可选中、搜索与翻译 [识别文字]", then the progress.
struct ScanBanner: View {
    @Bindable var state: ScanBannerState

    var body: some View {
        Group {
            if state.isVisible {
                HStack(spacing: 10) {
                    Image(systemName: state.editing ? "square.and.pencil" : "text.viewfinder")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    if state.editing {
                        Text("编辑 PDF 文字：点按文字直接修改，改动自动保存，⌘Z 可撤销")
                            .font(.callout)
                        Button(String(localized: "退出编辑"), action: state.finishEditing)
                            .controlSize(.small)
                            .help("Esc")
                    } else if let progress = state.progress {
                        Text(progress.total > 0 ? String(localized: "正在识别文字（\(progress.done)/\(progress.total) 页）") : String(localized: "正在识别文字…"))
                            .font(.callout.monospacedDigit())
                        ProgressView(value: progress.fraction)
                            .progressViewStyle(.linear)
                            .frame(width: 120)
                            .animation(.smooth, value: progress.fraction)
                        Button(String(localized: "取消"), action: state.cancel)
                            .controlSize(.small)
                    } else {
                        Text("这是扫描件，识别文字后即可选中、搜索与翻译")
                            .font(.callout)
                        Button(String(localized: "识别文字"), action: state.recognize)
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("recognizeText")
                        Button {
                            withAnimation(.smooth(duration: 0.2)) { state.dismiss() }
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "关闭"))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .modifier(GlassCapsule())
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: state.isVisible)
        .animation(.smooth(duration: 0.2), value: state.progress == nil)
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
    }
}

private struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
    }
}

/// The banner's host: it takes clicks only on the capsule, so the pages under the empty space stay usable.
final class ScanBannerHost: NSHostingView<ScanBanner> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
