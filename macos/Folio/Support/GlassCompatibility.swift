import SwiftUI

/// Liquid Glass on macOS 26, the closest earlier style before that.
extension View {
    @ViewBuilder func glassProminentButtonStyle() -> some View {
        if !UserDefaults.standard.bool(forKey: "FolioPreviewNoGlass"), #available(macOS 26, *) { buttonStyle(.glassProminent) } else { buttonStyle(.borderedProminent) }
    }

    @ViewBuilder func glassButtonStyle() -> some View {
        if #available(macOS 26, *) { buttonStyle(.glass) } else { buttonStyle(.bordered) }
    }

    @ViewBuilder func glassBackground(in shape: some Shape) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.separator, lineWidth: 0.5))
        }
    }

    /// A plain edge where content scrolls under the toolbar: the soft (blurred) edge is redrawn at every step of a
    /// scroll, which made long forms (设置) stutter.
    @ViewBuilder func hardScrollEdge() -> some View {
        if #available(macOS 26, *) { scrollEdgeEffectStyle(.hard, for: .all) } else { self }
    }
}
