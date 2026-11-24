import Foundation

/// 낙서로 지우기 (scratch-out): recognizes a pen stroke scribbled back and forth over ink.
///
/// A scribble is a stroke that mostly moves along one axis, reverses direction at least
/// `minTurns` times, sweeps most of its range on every pass, and turns sharply (V-shaped
/// or tight loops) — unlike handwriting such as "m"/"ㅡ", whose arches turn gently, or
/// a single zigzag line. The caller erases the strokes enclosed by `Scribble.hull`
/// and keeps the pen stroke as ink when nothing lies under it.
///
/// Same rules as note-android's `ScribbleDetector`; platform-neutral so it runs in the
/// Linux test suite.
public enum ScribbleDetector {
    /// Direction reversals needed (4 = five passes: → ← → ← →).
    public static let minTurns = 4

    public struct Point: Equatable, Hashable, Sendable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public struct Scribble: Sendable {
        /// Convex hull of the stroke, counter-clockwise (page units).
        public let hull: [Point]
        public let turns: Int
    }

    private static let sharpTurn = 100 * Double.pi / 180

    /// - Parameters:
    ///   - points: the raw pen samples in page units.
    ///   - minSize: smallest pass length (page units); shorter jitter is not a scribble.
    public static func detect(_ points: [Point], minSize: Double = 6) -> Scribble? {
        let pts = dedupe(points)
        guard pts.count >= 2 * minTurns + 2 else { return nil }

        // Dominant motion axis: the direction along which the pen travelled the most.
        var bestAngle = 0.0
        var bestTravel = -1.0
        for k in 0..<36 {
            let a = Double(k) * Double.pi / 36
            let c = cos(a), s = sin(a)
            var travel = 0.0
            for i in 1..<pts.count {
                travel += abs((pts[i].x - pts[i - 1].x) * c + (pts[i].y - pts[i - 1].y) * s)
            }
            if travel > bestTravel {
                bestTravel = travel
                bestAngle = a
            }
        }
        let c = cos(bestAngle), s = sin(bestAngle)
        let u = pts.map { $0.x * c + $0.y * s }
        guard let uMin = u.min(), let uMax = u.max() else { return nil }
        let range = uMax - uMin
        guard range >= minSize else { return nil }

        // Reversals along the axis, with hysteresis so jitter doesn't count.
        let h = 0.35 * range
        var turns: [Int] = []
        var dir = 0
        var peak = u[0]
        var peakIndex = 0
        for i in 1..<u.count {
            switch dir {
            case 0:
                if u[i] - u[0] >= h {
                    dir = 1; peak = u[i]; peakIndex = i
                } else if u[0] - u[i] >= h {
                    dir = -1; peak = u[i]; peakIndex = i
                }
            case 1:
                if u[i] > peak {
                    peak = u[i]; peakIndex = i
                } else if peak - u[i] >= h {
                    turns.append(peakIndex); dir = -1; peak = u[i]; peakIndex = i
                }
            default:
                if u[i] < peak {
                    peak = u[i]; peakIndex = i
                } else if u[i] - peak >= h {
                    turns.append(peakIndex); dir = 1; peak = u[i]; peakIndex = i
                }
            }
        }
        guard turns.count >= minTurns else { return nil }

        // Every inner pass sweeps most of the range (back and forth over the same ink).
        let amplitudes = (1..<turns.count).map { abs(u[turns[$0]] - u[turns[$0 - 1]]) }.sorted()
        let median = amplitudes[amplitudes.count / 2]
        guard median >= 0.55 * range, median >= minSize else { return nil }

        // Turns are sharp: the path arrives and leaves in nearly opposite directions.
        var arc = [Double](repeating: 0, count: pts.count)
        for i in 1..<pts.count {
            arc[i] = arc[i - 1] + hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)
        }
        let reach = 0.25 * median
        let sharp = turns.filter { turnAngle(pts, arc, $0, reach) < sharpTurn }.count
        guard Double(sharp) >= 0.7 * Double(turns.count) else { return nil }

        let hull = convexHull(pts)
        guard hull.count >= 3 else { return nil }
        return Scribble(hull: hull, turns: turns.count)
    }

    /// Interior angle (radians) at a turn, between the chords `reach` back and ahead along the path.
    private static func turnAngle(_ pts: [Point], _ arc: [Double], _ t: Int, _ reach: Double) -> Double {
        var a = t
        while a > 0 && arc[t] - arc[a] < reach { a -= 1 }
        var b = t
        while b < pts.count - 1 && arc[b] - arc[t] < reach { b += 1 }
        let ax = pts[a].x - pts[t].x, ay = pts[a].y - pts[t].y
        let bx = pts[b].x - pts[t].x, by = pts[b].y - pts[t].y
        let la = hypot(ax, ay), lb = hypot(bx, by)
        guard la > 1e-6, lb > 1e-6 else { return 0 }
        return acos(min(max((ax * bx + ay * by) / (la * lb), -1), 1))
    }

    private static func dedupe(_ points: [Point]) -> [Point] {
        var out: [Point] = []
        out.reserveCapacity(points.count)
        for p in points {
            if let last = out.last, hypot(p.x - last.x, p.y - last.y) <= 0.05 { continue }
            out.append(p)
        }
        return out
    }

    /// Andrew's monotone chain, counter-clockwise.
    public static func convexHull(_ points: [Point]) -> [Point] {
        var seen = Set<Point>()
        let p = points.filter { seen.insert($0).inserted }.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard p.count >= 3 else { return p }
        func cross(_ o: Point, _ a: Point, _ b: Point) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var hull: [Point] = []
        hull.reserveCapacity(2 * p.count)
        for pt in p {
            while hull.count >= 2 && cross(hull[hull.count - 2], hull[hull.count - 1], pt) <= 0 { hull.removeLast() }
            hull.append(pt)
        }
        let lower = hull.count + 1
        for pt in p.dropLast().reversed() {
            while hull.count >= lower && cross(hull[hull.count - 2], hull[hull.count - 1], pt) <= 0 { hull.removeLast() }
            hull.append(pt)
        }
        hull.removeLast()
        return hull
    }
}
