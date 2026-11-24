import Foundation
@testable import NoteKit
import XCTest

final class ScribbleDetectorTests: XCTestCase {
    typealias P = ScribbleDetector.Point

    /// Dense samples along a polyline (≈ 0.5 units apart, like a 240 Hz pen).
    private func path(_ corners: [(Double, Double)]) -> [P] {
        var out: [P] = []
        for k in 1..<corners.count {
            let (ax, ay) = corners[k - 1], (bx, by) = corners[k]
            let n = max(Int(hypot(bx - ax, by - ay) / 0.5), 1)
            for i in 0..<n {
                let t = Double(i) / Double(n)
                out.append(P(x: ax + (bx - ax) * t, y: ay + (by - ay) * t))
            }
        }
        out.append(P(x: corners.last!.0, y: corners.last!.1))
        return out
    }

    /// Back and forth horizontally over a word, drifting down a little.
    func testHorizontalScratchOutIsAScribble() {
        let pts = path([(100, 100), (160, 103), (102, 106), (158, 109), (101, 112), (159, 115), (103, 118)])
        let s = ScribbleDetector.detect(pts)
        XCTAssertNotNil(s)
        XCTAssertGreaterThanOrEqual(s?.turns ?? 0, ScribbleDetector.minTurns)
        XCTAssertGreaterThanOrEqual(s?.hull.count ?? 0, 3)
    }

    /// Up and down zigzag across a long word ("WWWW" motion).
    func testVerticalZigzagAcrossAWordIsAScribble() {
        let corners = (0...12).map { i in (100 + Double(i) * 6, i % 2 == 0 ? 100.0 : 125.0) }
        XCTAssertNotNil(ScribbleDetector.detect(path(corners)))
    }

    /// Diagonal scribble with tight loops at the turns.
    func testLoopyDiagonalScribbleIsAScribble() {
        var pts: [P] = []
        let dir = (cos(Double.pi / 4), sin(Double.pi / 4))
        for pass in 0..<7 {
            for i in 0...60 {
                let k = Double(i) / 60
                let along = pass % 2 == 0 ? k : 1 - k
                let d = along * 50
                let side = Double(pass) * 2 + 1.5 * sin(k * Double.pi)
                pts.append(P(x: 200 + dir.0 * d - dir.1 * side, y: 200 + dir.1 * d + dir.0 * side))
            }
        }
        XCTAssertNotNil(ScribbleDetector.detect(pts))
    }

    func testTooFewPassesIsNot() {
        // "Z" and "N" shapes: 2 turns.
        XCTAssertNil(ScribbleDetector.detect(path([(0, 0), (40, 0), (0, 30), (40, 30)])))
        // Three turns (four passes) is still not enough.
        XCTAssertNil(ScribbleDetector.detect(path([(0, 0), (40, 2), (0, 4), (40, 6), (0, 8)])))
    }

    func testOrdinaryStrokesAreNot() {
        XCTAssertNil(ScribbleDetector.detect(path([(0, 0), (200, 3)])))   // line
        let circle = (0...200).map { i -> P in
            let a = Double(i) * 2 * Double.pi / 200
            return P(x: 50 + 30 * cos(a), y: 50 + 30 * sin(a))
        }
        XCTAssertNil(ScribbleDetector.detect(circle))
        let spiral = (0...600).map { i -> P in
            let a = Double(i) * 6 * Double.pi / 600, r = 5 + Double(i) * 0.05
            return P(x: 100 + r * cos(a), y: 100 + r * sin(a))
        }
        XCTAssertNil(ScribbleDetector.detect(spiral))
    }

    /// Cursive "mmm": arched tops turn gently, so it is handwriting, not a scratch-out.
    func testCursiveArchesAreNot() {
        var pts: [P] = []
        var x = 0.0
        let h = 20.0, r = 4.0
        for _ in 0..<6 {
            for i in 0...40 { pts.append(P(x: x, y: h - Double(i) * (h - r) / 40)) }
            for i in 0...40 {
                let a = Double.pi - Double(i) * Double.pi / 40
                pts.append(P(x: x + r + r * cos(a), y: r - r * sin(a)))
            }
            x += 2 * r
            for i in 0...40 { pts.append(P(x: x, y: r + Double(i) * (h - r) / 40)) }
        }
        XCTAssertNil(ScribbleDetector.detect(pts))
    }

    func testTinyJitterIsNot() {
        let corners = (0...12).map { i in (Double(i) * 0.3, i % 2 == 0 ? 0.0 : 2.0) }
        XCTAssertNil(ScribbleDetector.detect(path(corners)))
    }

    func testConvexHullOfASquare() {
        let hull = ScribbleDetector.convexHull([P(x: 0, y: 0), P(x: 1, y: 0), P(x: 1, y: 1), P(x: 0, y: 1),
                                                P(x: 0.5, y: 0.5), P(x: 0.2, y: 0.7)])
        XCTAssertEqual(hull.count, 4)
    }
}
