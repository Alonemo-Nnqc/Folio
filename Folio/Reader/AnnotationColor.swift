import AppKit

/// The six markup colours offered by the reader (READER-04), close to Preview's.
enum AnnotationColor: String, CaseIterable, Identifiable {
    case yellow, green, blue, pink, purple, red

    var id: String { rawValue }

    var title: String {
        switch self {
        case .yellow: String(localized: "黄色")
        case .green: String(localized: "绿色")
        case .blue: String(localized: "蓝色")
        case .pink: String(localized: "粉色")
        case .purple: String(localized: "紫色")
        case .red: String(localized: "红色")
        }
    }

    /// Opaque base colour; highlights get transparency from PDFKit's blend mode.
    var nsColor: NSColor {
        switch self {
        case .yellow: NSColor(srgbRed: 1.00, green: 0.85, blue: 0.20, alpha: 1)
        case .green: NSColor(srgbRed: 0.45, green: 0.85, blue: 0.40, alpha: 1)
        case .blue: NSColor(srgbRed: 0.40, green: 0.70, blue: 1.00, alpha: 1)
        case .pink: NSColor(srgbRed: 1.00, green: 0.55, blue: 0.75, alpha: 1)
        case .purple: NSColor(srgbRed: 0.75, green: 0.55, blue: 1.00, alpha: 1)
        case .red: NSColor(srgbRed: 1.00, green: 0.35, blue: 0.35, alpha: 1)
        }
    }

    /// The preset closest to an existing annotation's colour (for ticking the colour menu).
    static func nearest(to color: NSColor) -> AnnotationColor? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        return allCases.min { lhs, rhs in
            distance(lhs.nsColor, rgb) < distance(rhs.nsColor, rgb)
        }.flatMap { distance($0.nsColor, rgb) < 0.12 ? $0 : nil }
    }

    private static func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        guard let a = a.usingColorSpace(.sRGB) else { return .infinity }
        return abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
            + abs(a.blueComponent - b.blueComponent)
    }
}
