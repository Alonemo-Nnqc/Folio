import AppKit
import FolioCore

/// The 出版物 column: where the paper appeared, as a capsule set in bold ("CVPR", "TPAMI"), followed by its ranks
/// (CCF class, 中科院 zone, JCR quartile, impact factor) in the colours the inspector uses. Capsules that do not fit
/// are left out from the end; the venue itself is always shown, truncated if it must be.
final class VenueBadgesView: NSView {
    private struct Badge {
        var text: String
        var tint: NSColor
        var font: NSFont
    }

    private static let spacing: CGFloat = 4
    private static let padding: CGFloat = 6
    private static let venueFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private static let rankFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    /// The venue's capsule: a neutral ink colour, so the ranks keep their colours to themselves.
    static let venueTint = NSColor(srgbRed: 0.30, green: 0.34, blue: 0.80, alpha: 1)

    private var badges: [Badge] = []

    override var isFlipped: Bool { true }

    // Redrawn when its content changes, or when a new width cuts it differently, not at every resize: a pane sliding
    // beside the list resizes every cell of the list at every frame.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layerContentsPlacement = .topLeft
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override func setFrameSize(_ newSize: NSSize) {
        let old = frame.size
        super.setFrameSize(newSize)
        let natural = naturalWidth
        if newSize.height != old.height || !(old.width >= natural && newSize.width >= natural) { needsDisplay = true }
    }

    /// The width that shows every capsule.
    private var naturalWidth: CGFloat {
        badges.reduce(4) { $0 + CapsuleLabel.textWidth($1.text, font: $1.font) + Self.padding * 2 + Self.spacing }
    }

    func configure(venue: VenueCatalog.Venue?, metrics: JournalMetrics?) {
        var list: [Badge] = []
        var tips: [String] = []
        if let venue {
            list.append(Badge(text: venue.abbreviation, tint: Self.venueTint, font: Self.venueFont))
            tips.append(venue.fullName ?? venue.abbreviation)
        }
        // CCF: easyScholar's answer, else the built-in list of well-known venues.
        if let ccf = metrics?.ccf ?? venue?.ccf {
            list.append(Badge(text: "CCF-\(ccf)", tint: JournalBadgeTint.color(for: .ccf), font: Self.rankFont))
            tips.append(String(localized: "中国计算机学会推荐：\(ccf) 类"))
        }
        if let metrics {
            if let zone = metrics.casZone ?? metrics.casBaseZone {
                let text = String(localized: "中科院\(zone)区") + (metrics.casTop ? " Top" : "")
                list.append(Badge(text: text, tint: JournalBadgeTint.cas(zone), font: metrics.casTop ? JournalBadgeTint.emphasizedFont : Self.rankFont))
            }
            if let quartile = metrics.jcrQuartile {
                list.append(Badge(text: "Q\(quartile)", tint: JournalBadgeTint.quartile(quartile), font: Self.rankFont))
            }
            if let value = metrics.impactFactor {
                list.append(Badge(text: "IF \(JournalMetrics.format(value))", tint: JournalBadgeTint.color(for: .impactFactor), font: Self.rankFont))
            }
            if !metrics.summary.isEmpty { tips.append(metrics.summary) }
        }
        badges = list
        toolTip = tips.isEmpty ? nil : tips.joined(separator: "\n")
        setAccessibilityValue(list.map(\.text).joined(separator: ", "))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !badges.isEmpty else {
            CapsuleLabel.drawText("—", in: NSRect(x: 2, y: 0, width: 20, height: bounds.height), color: .tertiaryLabelColor,
                                  font: ItemListMetrics.bodyFont, flipped: true, scale: window?.backingScaleFactor ?? 2)
            return
        }
        let height = CapsuleLabel.tagHeight
        let scale = window?.backingScaleFactor ?? 2
        let y = ((bounds.height - height) / 2 * scale).rounded() / scale
        var x: CGFloat = 2
        let limit = bounds.width - 2
        for (index, badge) in badges.enumerated() {
            var width = CapsuleLabel.textWidth(badge.text, font: badge.font) + Self.padding * 2
            if x + width > limit {
                // The venue always shows, truncated; ranks that do not fit are left out.
                guard index == 0 else { return }
                width = max(limit - x, 24)
            }
            CapsuleLabel.draw(badge.text, in: NSRect(x: x, y: y, width: width, height: height), tint: badge.tint,
                              font: badge.font, padding: Self.padding, dot: false, appearance: effectiveAppearance, flipped: true, scale: scale)
            x += width + Self.spacing
        }
    }
}

final class VenueCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("VenueCell")
    let badges = VenueBadgesView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        badges.translatesAutoresizingMaskIntoConstraints = false
        badges.setAccessibilityIdentifier("venueBadges")
        addSubview(badges)
        NSLayoutConstraint.activate([
            badges.leadingAnchor.constraint(equalTo: leadingAnchor),
            badges.trailingAnchor.constraint(equalTo: trailingAnchor),
            badges.topAnchor.constraint(equalTo: topAnchor),
            badges.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }
}
