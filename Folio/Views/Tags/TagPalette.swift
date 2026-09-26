import SwiftUI

/// Preset tag colours (TAG-03). Grey is the default for imported tags.
enum TagPalette {
    static let presets: [(name: String, hex: String)] = [
        ("红", "#FF3B30"), ("橙", "#FF9500"), ("黄", "#FFCC00"), ("绿", "#34C759"), ("薄荷", "#00C7BE"),
        ("青", "#32ADE6"), ("蓝", "#007AFF"), ("靛", "#5856D6"), ("紫", "#AF52DE"), ("粉", "#FF2D55"),
    ]
    static let importDefault = "#8E8E93"
}

extension Color {
    init(hex: String) {
        self.init(nsColor: NSColor(hex: hex))
    }
}
