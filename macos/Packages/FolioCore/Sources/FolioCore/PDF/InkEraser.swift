import CoreGraphics
import Foundation

/// Geometry of the reader's eraser (READER-30): cuts away the parts of ink strokes the eraser passed over.
///
/// The eraser's track is a chain of capsules (each segment of the track widened by `radius`). Every stroke is a
/// polyline; for each of its segments the stretch inside any capsule is computed exactly (a capsule is convex, so
/// it meets a line in one interval) and removed, and the stroke is cut where it enters and leaves. What remains of
/// a cut stroke is kept as separate strokes; pieces shorter than `minimumLength` are dropped. Strokes the eraser
/// did not touch are returned as they were. The Windows app has the same algorithm (Folio.Core `InkEraser`).
public enum InkEraser {
    /// The eraser's three sizes (the setting `readerEraserSize`, shared with the Windows app).
    public enum Size: String, CaseIterable, Sendable {
        case small, medium, large

        /// Diameter in page points: zooming in makes the eraser look larger, as it does the ink.
        public var diameter: CGFloat {
            switch self {
            case .small: 8
            case .medium: 16
            case .large: 32
            }
        }
    }

    /// Pieces of cut strokes shorter than this (page points) are dropped: they would show as specks.
    public static let defaultMinimumLength: CGFloat = 1

    /// The strokes after erasing along `path`, or nil when the eraser touched none of them.
    /// An empty result means everything was erased.
    ///
    /// - Parameters:
    ///   - strokes: polylines in page coordinates.
    ///   - path: the eraser's track in page coordinates; a single point erases a disc.
    ///   - radius: how far from the track is erased: the eraser's radius plus half the stroke's line width,
    ///     so that touching the visible line is enough.
    public static func erase(_ strokes: [[CGPoint]], along path: [CGPoint], radius: CGFloat,
                             minimumLength: CGFloat = defaultMinimumLength) -> [[CGPoint]]? {
        guard !path.isEmpty, radius > 0 else { return nil }
        let capsules = path.count == 1 ? [(path[0], path[0])] : zip(path, path.dropFirst()).map { ($0, $1) }
        let reach = bounds(of: path).insetBy(dx: -radius, dy: -radius)
        var result: [[CGPoint]] = []
        var changed = false
        for stroke in strokes {
            guard !stroke.isEmpty, bounds(of: stroke).intersects(reach),
                  let pieces = cut(stroke, by: capsules, radius: radius, minimumLength: minimumLength) else {
                result.append(stroke)
                continue
            }
            changed = true
            result.append(contentsOf: pieces)
        }
        return changed ? result : nil
    }

    /// The smallest rectangle around the points (zero size for one point).
    public static func bounds(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Length of a polyline.
    public static func length(of stroke: [CGPoint]) -> CGFloat {
        zip(stroke, stroke.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    // MARK: Cutting one stroke

    /// The pieces left of one stroke, or nil when no capsule touches it.
    static func cut(_ stroke: [CGPoint], by capsules: [(CGPoint, CGPoint)], radius: CGFloat,
                    minimumLength: CGFloat) -> [[CGPoint]]? {
        if stroke.count == 1 {
            // A dot: gone when the eraser covers it.
            let p = stroke[0]
            return capsules.contains { distance(from: p, toSegment: $0.0, $0.1) <= radius } ? [] : nil
        }
        var pieces: [[CGPoint]] = []
        var current: [CGPoint] = []
        var touched = false
        func flush() {
            if current.count > 1 { pieces.append(current) }
            current = []
        }
        for (a, b) in zip(stroke, stroke.dropFirst()) {
            let removed = merge(capsules.compactMap { interval(from: a, to: b, capsule: $0.0, $0.1, radius: radius) })
            if removed.isEmpty {
                if current.isEmpty { current = [a] }
                current.append(b)
                continue
            }
            touched = true
            let segmentLength = hypot(b.x - a.x, b.y - a.y)
            let kept = complement(of: removed).filter { ($0.upperBound - $0.lowerBound) * segmentLength > 1e-6 }
            let startsAtA = kept.first.map { $0.lowerBound <= epsilon } ?? false
            if !startsAtA { flush() }
            for (index, piece) in kept.enumerated() {
                let start = piece.lowerBound <= epsilon ? a : lerp(a, b, piece.lowerBound)
                let end = piece.upperBound >= 1 - epsilon ? b : lerp(a, b, piece.upperBound)
                if index == 0, startsAtA, !current.isEmpty {
                    current.append(end)
                } else {
                    flush()
                    current = [start, end]
                }
                if piece.upperBound < 1 - epsilon { flush() }
            }
        }
        flush()
        guard touched else { return nil }
        return pieces.filter { length(of: $0) >= minimumLength }
    }

    private static let epsilon: CGFloat = 1e-9

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// Sorted, overlapping intervals joined.
    private static func merge(_ intervals: [ClosedRange<CGFloat>]) -> [ClosedRange<CGFloat>] {
        var result: [ClosedRange<CGFloat>] = []
        for next in intervals.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, next.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, next.upperBound)
            } else {
                result.append(next)
            }
        }
        return result
    }

    /// What is left of 0…1 outside the (merged, sorted) intervals.
    private static func complement(of removed: [ClosedRange<CGFloat>]) -> [ClosedRange<CGFloat>] {
        var result: [ClosedRange<CGFloat>] = []
        var start: CGFloat = 0
        for r in removed {
            if r.lowerBound > start { result.append(start...r.lowerBound) }
            start = max(start, r.upperBound)
        }
        if start < 1 { result.append(start...1) }
        return result
    }

    // MARK: A segment against a capsule

    /// The part (as parameters 0…1 of a→b) of the segment a→b that lies within `radius` of the segment c→d,
    /// or nil when they do not meet.
    static func interval(from a: CGPoint, to b: CGPoint, capsule c: CGPoint, _ d: CGPoint,
                         radius r: CGFloat) -> ClosedRange<CGFloat>? {
        let dx = b.x - a.x, dy = b.y - a.y
        if dx * dx + dy * dy < 1e-18 {
            // A segment of no length (a repeated point) is all in or all out.
            return distance(from: a, toSegment: c, d) <= r ? 0...1 : nil
        }
        // The capsule is the union of the discs at its ends and the band along it; being convex, it meets the line
        // in one interval, which is the span of what the three parts give.
        var low = CGFloat.infinity, high = -CGFloat.infinity
        for centre in [c, d] {
            if let range = discInterval(a: a, dx: dx, dy: dy, centre: centre, radius: r) {
                low = min(low, range.lowerBound); high = max(high, range.upperBound)
            }
        }
        if let range = bandInterval(a: a, dx: dx, dy: dy, c: c, d: d, radius: r) {
            low = min(low, range.lowerBound); high = max(high, range.upperBound)
        }
        let lower = max(low, 0), upper = min(high, 1)
        return lower <= upper ? lower...upper : nil
    }

    /// Where the line a + t·(dx, dy) is inside the disc.
    private static func discInterval(a: CGPoint, dx: CGFloat, dy: CGFloat, centre: CGPoint, radius r: CGFloat) -> ClosedRange<CGFloat>? {
        let fx = a.x - centre.x, fy = a.y - centre.y
        let qa = dx * dx + dy * dy, qb = 2 * (fx * dx + fy * dy), qc = fx * fx + fy * fy - r * r
        let discriminant = qb * qb - 4 * qa * qc
        guard discriminant >= 0 else { return nil }
        let root = discriminant.squareRoot()
        return ((-qb - root) / (2 * qa))...((-qb + root) / (2 * qa))
    }

    /// Where the line a + t·(dx, dy) is inside the band of width 2r along c→d (between the perpendiculars at c and d).
    private static func bandInterval(a: CGPoint, dx: CGFloat, dy: CGFloat, c: CGPoint, d: CGPoint, radius r: CGFloat) -> ClosedRange<CGFloat>? {
        let ex = d.x - c.x, ey = d.y - c.y
        let length = (ex * ex + ey * ey).squareRoot()
        guard length > 1e-9 else { return nil }
        let ux = ex / length, uy = ey / length
        let fx = a.x - c.x, fy = a.y - c.y
        // Along the eraser segment: 0 ≤ s ≤ length; across it: |h| ≤ r. Both are linear in t.
        let s0 = fx * ux + fy * uy, s1 = dx * ux + dy * uy
        let h0 = fx * uy - fy * ux, h1 = dx * uy - dy * ux
        guard let along = linearInterval(v0: s0, v1: s1, low: 0, high: length),
              let across = linearInterval(v0: h0, v1: h1, low: -r, high: r) else { return nil }
        let lower = max(along.lowerBound, across.lowerBound), upper = min(along.upperBound, across.upperBound)
        return lower <= upper ? lower...upper : nil
    }

    /// The t for which low ≤ v0 + v1·t ≤ high (all t: a very wide interval).
    private static func linearInterval(v0: CGFloat, v1: CGFloat, low: CGFloat, high: CGFloat) -> ClosedRange<CGFloat>? {
        if abs(v1) < 1e-12 { return (low...high).contains(v0) ? -1e12...1e12 : nil }
        let t1 = (low - v0) / v1, t2 = (high - v0) / v1
        return min(t1, t2)...max(t1, t2)
    }

    /// Distance from a point to the segment c→d.
    public static func distance(from p: CGPoint, toSegment c: CGPoint, _ d: CGPoint) -> CGFloat {
        let ex = d.x - c.x, ey = d.y - c.y
        let lengthSquared = ex * ex + ey * ey
        var t: CGFloat = 0
        if lengthSquared > 0 { t = min(1, max(0, ((p.x - c.x) * ex + (p.y - c.y) * ey) / lengthSquared)) }
        return hypot(p.x - (c.x + t * ex), p.y - (c.y + t * ey))
    }
}
