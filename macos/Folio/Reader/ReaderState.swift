import AppKit
import FolioCore
import Observation
import PDFKit

/// Annotation tools of the reader (READER-04).
enum AnnotationTool: Int, CaseIterable {
    case select, highlight, underline, strikeOut, note, text, ink, eraser

    var title: String {
        switch self {
        case .select: String(localized: "选择")
        case .highlight: String(localized: "高亮")
        case .underline: String(localized: "下划线")
        case .strikeOut: String(localized: "删除线")
        case .note: String(localized: "便签")
        case .text: String(localized: "文本框")
        case .ink: String(localized: "手绘")
        case .eraser: String(localized: "橡皮擦")
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .highlight: "highlighter"
        case .underline: "underline"
        case .strikeOut: "strikethrough"
        case .note: "note.text"
        case .text: "character.textbox"
        case .ink: "scribble"
        case .eraser: "eraser"
        }
    }

    /// ⌃⌘ shortcut in the 批注 menu.
    var keyEquivalent: String {
        switch self {
        case .select: "0"
        case .highlight: "h"
        case .underline: "u"
        case .strikeOut: "k"
        case .note: "n"
        case .text: "t"
        case .ink: "d"
        case .eraser: "e"
        }
    }

    /// Tools that turn a text selection into markup.
    var markupType: PDFAnnotationSubtype? {
        switch self {
        case .highlight: .highlight
        case .underline: .underline
        case .strikeOut: .strikeOut
        default: nil
        }
    }
}

extension InkEraser.Size {
    var title: String {
        switch self {
        case .small: String(localized: "小")
        case .medium: String(localized: "中")
        case .large: String(localized: "大")
        }
    }

    /// A ring as large as the eraser, relative to the others: the toolbar button and the menu items (template, so it
    /// follows light and dark).
    var image: NSImage {
        let ring: CGFloat = switch self {
        case .small: 6
        case .medium: 10
        case .large: 15
        }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: NSRect(x: rect.midX - ring / 2, y: rect.midY - ring / 2, width: ring, height: ring))
            NSColor.black.withAlphaComponent(0.18).setFill()
            circle.fill()
            NSColor.black.setStroke()
            circle.lineWidth = 1.4
            circle.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = String(localized: "橡皮擦大小：\(title)")
        return image
    }
}

/// Pages of the reader sidebar (READER-02).
enum ReaderSidebarTab: Int, CaseIterable {
    case thumbnails, outline, annotations, search

    var title: String {
        switch self {
        case .thumbnails: String(localized: "缩略图")
        case .outline: String(localized: "目录")
        case .annotations: String(localized: "批注")
        case .search: String(localized: "查找结果")
        }
    }

    var symbol: String {
        switch self {
        case .thumbnails: "square.grid.2x2"
        case .outline: "list.bullet.indent"
        case .annotations: "highlighter"
        case .search: "magnifyingglass"
        }
    }
}

/// One annotation as listed in the sidebar.
struct AnnotationRow: Identifiable, Equatable {
    let id: ObjectIdentifier
    let pageIndex: Int
    let kind: String
    let color: NSColor
    let text: String
    let comment: String
}

/// One find result as listed in the sidebar.
struct SearchHit: Identifiable, Equatable {
    let id: Int
    let pageIndex: Int
    let pageLabel: String
    let context: AttributedString
}

/// An entry of the PDF outline.
struct OutlineRow: Identifiable {
    let id: Int
    let title: String
    let pageIndex: Int?
    let children: [OutlineRow]?
}

/// What the reader window's SwiftUI parts (sidebar, notes panel) read and the AppKit side writes.
@Observable
final class ReaderState {
    var tool = AnnotationTool.select
    var color: AnnotationColor
    var eraserSize: InkEraser.Size
    var sidebarTab = ReaderSidebarTab.thumbnails
    var pageIndex = 0
    var pageCount = 0
    var annotations: [AnnotationRow] = []
    var outline: [OutlineRow] = []
    var searchQuery = ""
    var searchHits: [SearchHit] = []
    var isSearching = false
    var currentHit: Int?
    /// The mono/dual translation shown next to the original, when 对照阅读 is on (READER-10).
    var parallelFileId: String?

    init(color: AnnotationColor, eraserSize: InkEraser.Size) {
        self.color = color
        self.eraserSize = eraserSize
    }
}
