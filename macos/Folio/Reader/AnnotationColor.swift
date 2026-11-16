import AppKit

/// The reader's annotation colours (READER-04), close to Preview's. Each tool offers its own few of them
/// (`AnnotationTool.palette`): no black highlighter, no yellow pen.
enum AnnotationColor: String, CaseIterable, Identifiable {
    case yellow, green, blue, pink, purple, red, orange, black

    var id: String { rawValue }

    var title: String {
        switch self {
        case .yellow: String(localized: "黄色")
        case .green: String(localized: "绿色")
        case .blue: String(localized: "蓝色")
        case .pink: String(localized: "粉色")
        case .purple: String(localized: "紫色")
        case .red: String(localized: "红色")
        case .orange: String(localized: "橙色")
        case .black: String(localized: "黑色")
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
        case .orange: NSColor(srgbRed: 1.00, green: 0.62, blue: 0.20, alpha: 1)
        case .black: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
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

/// A colour a tool or an annotation uses: one of the presets, or one the user mixed in the colour panel, kept as
/// "#RRGGBB" (设置: annotationToolColors, annotationCustomColors).
struct ToolColor: Hashable, Identifiable {
    let key: String
    var id: String { key }

    init(key: String) { self.key = key }
    init(_ preset: AnnotationColor) { key = preset.rawValue }
    /// A mixed colour: the preset it matches, if it is one.
    init(_ color: NSColor) {
        key = AnnotationColor.allCases.first { $0.nsColor.hexString == color.hexString }?.rawValue ?? color.hexString
    }

    var preset: AnnotationColor? { AnnotationColor(rawValue: key) }
    var isValid: Bool { preset != nil || (key.hasPrefix("#") && key.count == 7) }
    var nsColor: NSColor { preset?.nsColor ?? NSColor(hex: key) }
    var title: String { preset?.title ?? String(localized: "自定义颜色") }

    /// The colour among `choices` an annotation's colour is (for ticking it in a menu).
    static func matching(_ color: NSColor?, in choices: [ToolColor]) -> ToolColor? {
        guard let rgb = color?.withAlphaComponent(1).usingColorSpace(.sRGB) else { return nil }
        func distance(_ c: ToolColor) -> CGFloat {
            guard let other = c.nsColor.usingColorSpace(.sRGB) else { return .infinity }
            return abs(other.redComponent - rgb.redComponent) + abs(other.greenComponent - rgb.greenComponent)
                + abs(other.blueComponent - rgb.blueComponent)
        }
        return choices.min { distance($0) < distance($1) }.flatMap { distance($0) < 0.06 ? $0 : nil }
    }
}
