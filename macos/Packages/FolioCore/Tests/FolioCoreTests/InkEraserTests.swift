import CoreGraphics
import Foundation
import Testing
@testable import FolioCore

@Suite struct InkEraserTests {
    private func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    private func close(_ a: [[CGPoint]]?, _ b: [[CGPoint]], tolerance: CGFloat = 1e-6) -> Bool {
        guard let a, a.count == b.count else { return false }
        return zip(a, b).allSatisfy { lhs, rhs in
            lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { abs($0.x - $1.x) <= tolerance && abs($0.y - $1.y) <= tolerance }
        }
    }

    @Test func cutsAStrokeWhereTheEraserCrossesIt() {
        let result = InkEraser.erase([[p(0, 0), p(100, 0)]], along: [p(50, -20), p(50, 20)], radius: 5)
        #expect(close(result, [[p(0, 0), p(45, 0)], [p(55, 0), p(100, 0)]]))
    }

    @Test func untouchedStrokesGiveNil() {
        #expect(InkEraser.erase([[p(0, 0), p(100, 0)]], along: [p(50, 10), p(60, 10)], radius: 5) == nil)
        #expect(InkEraser.erase([[p(0, 0), p(100, 0)]], along: [], radius: 5) == nil)
        #expect(InkEraser.erase([[p(0, 0), p(100, 0)]], along: [p(50, 0)], radius: 0) == nil)
    }

    @Test func erasingAlongTheWholeStrokeLeavesNothing() {
        let result = InkEraser.erase([[p(0, 0), p(40, 5), p(100, 0)]], along: [p(-5, 0), p(105, 0)], radius: 8)
        #expect(result == [])
    }

    @Test func keepsTheVerticesOfWhatRemains() {
        // A zigzag cut in its second segment: the first piece keeps the corner at (20, 20).
        let stroke = [p(0, 0), p(20, 20), p(40, 0), p(60, 20)]
        let result = InkEraser.erase([stroke], along: [p(30, -10), p(30, 30)], radius: 2)
        #expect(close(result, [[p(0, 0), p(20, 20), p(28, 12)], [p(32, 8), p(40, 0), p(60, 20)]]))
    }

    @Test func shortStubsAreDropped() {
        // The disc reaches from x = 0.5 to 10.5: the 0.5 pt left at the start is not worth keeping.
        let result = InkEraser.erase([[p(0, 0), p(100, 0)]], along: [p(5.5, 0)], radius: 5)
        #expect(close(result, [[p(10.5, 0), p(100, 0)]]))
        // With no minimum it stays.
        let all = InkEraser.erase([[p(0, 0), p(100, 0)]], along: [p(5.5, 0)], radius: 5, minimumLength: 0)
        #expect(close(all, [[p(0, 0), p(0.5, 0)], [p(10.5, 0), p(100, 0)]]))
    }

    @Test func aClickErasesADisc() {
        let result = InkEraser.erase([[p(0, 0), p(100, 0)]], along: [p(50, 3)], radius: 5)
        #expect(close(result, [[p(0, 0), p(46, 0)], [p(54, 0), p(100, 0)]]))
    }

    @Test func dotsGoWhenCovered() {
        #expect(InkEraser.erase([[p(10, 10)]], along: [p(12, 10)], radius: 3) == [])
        #expect(InkEraser.erase([[p(10, 10)]], along: [p(20, 10)], radius: 3) == nil)
    }

    @Test func diagonalCrossingIsExact() {
        let result = InkEraser.erase([[p(-10, -10), p(10, 10)]], along: [p(-50, 0), p(50, 0)], radius: 5)
        #expect(close(result, [[p(-10, -10), p(-5, -5)], [p(5, 5), p(10, 10)]]))
    }

    @Test func roundEndsOfTheTrackErase() {
        // Past the end of the track at (100, 0), its round cap still reaches x = 103 for |y| ≤ 4.
        let result = InkEraser.erase([[p(103, -20), p(103, 20)]], along: [p(0, 0), p(100, 0)], radius: 5)
        #expect(close(result, [[p(103, -20), p(103, -4)], [p(103, 4), p(103, 20)]]))
    }

    @Test func onlyTouchedStrokesChangeAndOrderStays() {
        let a = [p(0, 0), p(100, 0)], b = [p(0, 50), p(100, 50)], c = [p(0, 100), p(100, 100)]
        let result = InkEraser.erase([a, b, c], along: [p(50, 40), p(50, 60)], radius: 2)
        #expect(close(result, [a, [p(0, 50), p(48, 50)], [p(52, 50), p(100, 50)], c]))
    }

    @Test func erasingPieceByPieceMatchesErasingAtOnce() {
        let strokes = [[p(0, 0), p(30, 25), p(60, 0), p(90, 25), p(120, 0)], [p(0, 40), p(120, 40)]]
        let track = [p(10, -10), p(35, 30), p(70, 45), p(100, 10), p(115, -5)]
        let atOnce = InkEraser.erase(strokes, along: track, radius: 4)
        var stepwise = strokes
        for (from, to) in zip(track, track.dropFirst()) {
            stepwise = InkEraser.erase(stepwise, along: [from, to], radius: 4) ?? stepwise
        }
        #expect(close(atOnce, stepwise, tolerance: 1e-6))
    }

    @Test func repeatedPointsInAStrokeAreHandled() {
        let result = InkEraser.erase([[p(0, 0), p(0, 0), p(50, 0), p(50, 0), p(100, 0)]], along: [p(50, -9), p(50, 9)], radius: 5)
        #expect(result?.count == 2)
        #expect(result?.first?.last.map { abs($0.x - 45) < 1e-6 } == true)
        #expect(result?.last?.first.map { abs($0.x - 55) < 1e-6 } == true)
    }

    @Test func sizesAreEightSixteenThirtyTwo() {
        #expect(InkEraser.Size.allCases.map(\.diameter) == [8, 16, 32])
        #expect(InkEraser.Size(rawValue: "medium") == .medium)
    }
}
