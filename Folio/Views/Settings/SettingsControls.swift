import Observation
import SwiftUI

/// "重新检测" in a settings section header: the circular-arrows symbol turns while the check runs, then the
/// result ("找到 3 个智能体") shows beside the button for a few seconds, so a click always visibly does something.
struct RedetectButton: View {
    let isChecking: Bool
    let result: String?
    var help = "重新检测"
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let result {
                Label(result, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
            }
            Button(action: action) {
                Label(isChecking ? "正在检测…" : "重新检测", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                    .symbolEffect(.rotate, options: .repeat(.continuous), isActive: isChecking)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isChecking)
            .help(help)
        }
        .animation(.smooth(duration: 0.25), value: result)
        .animation(.smooth(duration: 0.25), value: isChecking)
    }
}

/// Drives a `RedetectButton`: runs the check for at least a moment (an instant check reads as "nothing
/// happened"), then shows its one-line result for three seconds.
@Observable
final class RedetectState {
    private(set) var isChecking = false
    private(set) var result: String?
    private var generation = 0

    func run(_ check: @escaping () async -> String) {
        guard !isChecking else { return }
        isChecking = true
        result = nil
        Task {
            let started = ContinuousClock.now
            let text = await check()
            try? await Task.sleep(until: started + .milliseconds(600))
            isChecking = false
            result = text
            generation += 1
            let current = generation
            try? await Task.sleep(for: .seconds(3))
            if current == generation { result = nil }
        }
    }
}

/// A coloured status pill ("● 已启用"), readable at a glance unlike a line of grey caption text.
struct StatusBadge: View {
    enum Tone { case positive, attention, neutral, info }
    let text: String
    let tone: Tone

    private var color: Color {
        switch tone {
        case .positive: .green
        case .attention: .orange
        case .neutral: .secondary
        case .info: .blue
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.callout.weight(.medium))
        }
        .foregroundStyle(tone == .neutral ? Color.secondary : color)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(color.opacity(0.13), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.28), lineWidth: 0.5))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}
