import SwiftUI

/// Preset tag colours (TAG-03). Grey is the default for imported tags.
enum TagPalette {
    static let presets: [(name: String, hex: String)] = [
        (String(localized: "红"), "#FF3B30"), (String(localized: "橙"), "#FF9500"), (String(localized: "黄"), "#FFCC00"), (String(localized: "绿"), "#34C759"), (String(localized: "薄荷"), "#00C7BE"),
        (String(localized: "青"), "#32ADE6"), (String(localized: "蓝"), "#007AFF"), (String(localized: "靛"), "#5856D6"), (String(localized: "紫"), "#AF52DE"), (String(localized: "粉"), "#FF2D55"),
    ]
    static let importDefault = "#8E8E93"
}

extension Color {
    init(hex: String) {
        self.init(nsColor: NSColor(hex: hex))
    }
}
