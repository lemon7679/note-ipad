import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// CI-only stand-in for `Sources/InkBridge` (selected with NOTE_ENGINE_STUB=1).
// It has the same public API with no-op bodies so the app can be type-checked
// where the private note-core engine is not available. It draws nothing and
// is never shipped. Keep it in step with Sources/InkBridge/InkBridge.swift
// (scripts/check-bridge-api.sh compares the two).

public typealias StrokeID = UInt64

public enum BrushKind: Int, CaseIterable, Codable, Sendable {
    case ballpoint = 0
    case pencil = 1
    case highlighter = 2
    case fountainPen = 3
    case brushPen = 4
    case calligraphy = 5
    case marker = 6
}

public struct InkRGBA: Equatable, Hashable, Codable, Sendable {
    public var r: Float, g: Float, b: Float, a: Float

    public init(r: Float, g: Float, b: Float, a: Float = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
}

public enum StabilizerMode: Int, Codable, Sendable {
    case none = 0
    case pulledString = 1   // amount = string length (view points)
    case movingAverage = 2  // amount = window (ms)
}

public enum EraserMode: Int, Codable, Sendable {
    case stroke = 0
    case precise = 1
}

public enum SnappedShape: Int, Sendable {
    case none = 0, line, polyline, triangle, rectangle, quad, ellipse, circle, arc, polygon
}

/// Row-major 2D affine transform (x' = a·x + c·y + tx, y' = b·x + d·y + ty).
public struct InkAffine: Equatable, Sendable {
    public var a: Float, b: Float, c: Float, d: Float, tx: Float, ty: Float

    public init(a: Float, b: Float, c: Float, d: Float, tx: Float, ty: Float) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }

    public static func translation(_ x: Float, _ y: Float) -> InkAffine {
        InkAffine(a: 1, b: 0, c: 0, d: 1, tx: x, ty: y)
    }

    /// Uniform scale `s` around (cx, cy), then a translation.
    public static func scale(_ s: Float, aroundX cx: Float, y cy: Float, thenTranslate dx: Float = 0, _ dy: Float = 0) -> InkAffine {
        InkAffine(a: s, b: 0, c: 0, d: s, tx: cx - s * cx + dx, ty: cy - s * cy + dy)
    }
}

/// One Apple Pencil / finger sample in page units.
public struct PenSample: Sendable {
    public var x: Float
    public var y: Float
    public var pressure: Float
    public var altitude: Float
    public var azimuth: Float
    public var time: Double
    public var updateID: UInt64
    public var expectsPressureUpdate: Bool
    public var expectsTiltUpdate: Bool
    public var isPencil: Bool

    public init(x: Float, y: Float, pressure: Float = -1, altitude: Float = -1, azimuth: Float = 0, time: Double,
                updateID: UInt64 = 0, expectsPressureUpdate: Bool = false, expectsTiltUpdate: Bool = false,
                isPencil: Bool = true) {
        self.x = x
        self.y = y
        self.pressure = pressure
        self.altitude = altitude
        self.azimuth = azimuth
        self.time = time
        self.updateID = updateID
        self.expectsPressureUpdate = expectsPressureUpdate
        self.expectsTiltUpdate = expectsTiltUpdate
        self.isPencil = isPencil
    }
}

// MARK: - Stroke builder

public final class StrokeBuilder {
    private var active = false

    public init(kind: BrushKind) {}

    public func setBrush(_ kind: BrushKind, color: InkRGBA, width: Float) {}
    public func setColor(_ color: InkRGBA) {}
    public func setWidth(_ width: Float) {}
    public func setOpacity(_ opacity: Float) {}
    public func setStabilizer(_ mode: StabilizerMode, amount: Float) {}
    public func setPressureCurve(_ c1x: Float, _ c1y: Float, _ c2x: Float, _ c2y: Float) {}
    public func setSnapOnHold(_ enabled: Bool) {}
    public func setViewScale(_ scale: Float) {}
    public func setCorrection(_ strength: Float) {}
    public func setCorrectionOptions(live: Bool, smoothCurves: Bool, straightenLines: Bool, snapToAxes: Bool) {}
    public func setShapeConstraint(_ constrained: Bool) {}
    public func begin(_ sample: PenSample) { active = true }
    public func add(_ samples: [PenSample]) {}
    public func setPredicted(_ samples: [PenSample]) {}
    @discardableResult
    public func updateEstimated(id: UInt64, pressure: Float, altitude: Float, azimuth: Float) -> Bool { false }
    public func tick(now: Double) -> Bool { false }
    public func end() { active = false }
    public func cancel() { active = false }
    public var isActive: Bool { active }
    public var pointCount: Int { 0 }
    public var snappedShape: SnappedShape { .none }
    public var blendsMultiply: Bool { false }
    public func updateGeometry(pixelsPerUnit: Float) -> CGRect { .null }
    public func renderOver(_ pixels: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int,
                           scale: Float, offsetX: Float, offsetY: Float) {}
}

// MARK: - Snapshot

public final class InkSnapshot: @unchecked Sendable {
    init() {}

    public var strokeCount: Int { 0 }
    public func renderOver(_ pixels: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int,
                           scale: Float, offsetX: Float, offsetY: Float) {}
    public func save() -> Data? { Data() }
}

// MARK: - Page

public final class InkPage {
    private let width: Float
    private let height: Float

    public init(width: Float, height: Float) {
        self.width = width
        self.height = height
    }

    public static var engineVersion: String { "stub" }

    public private(set) var version: UInt64 = 0
    public func snapshot() -> InkSnapshot { InkSnapshot() }

    public var pageWidth: Float { width }
    public var pageHeight: Float { height }
    public var strokeCount: Int { 0 }
    public var canUndo: Bool { false }
    public var canRedo: Bool { false }
    @discardableResult
    public func commit(_ builder: StrokeBuilder) -> StrokeID { 0 }
    @discardableResult public func undo() -> Bool { false }
    @discardableResult public func redo() -> Bool { false }
    public func eraseBegin(mode: EraserMode, radius: Float, highlighterOnly: Bool, at point: CGPoint) {}
    @discardableResult
    public func eraseMove(to point: CGPoint) -> Bool { false }
    public func eraseEnd() {}
    public func selectLasso(_ points: [CGPoint]) -> [StrokeID] { [] }
    @discardableResult
    public func transform(_ ids: [StrokeID], _ t: InkAffine) -> Bool { false }
    @discardableResult
    public func recolor(_ ids: [StrokeID], _ color: InkRGBA) -> Bool { false }
    @discardableResult
    public func delete(_ ids: [StrokeID]) -> Bool { false }
    public func duplicate(_ ids: [StrokeID], dx: Float, dy: Float) -> [StrokeID] { [] }
    public func bounds(of ids: [StrokeID]) -> CGRect { .null }
    public func copyStrokes(_ ids: [StrokeID]) -> Data? { nil }
    public func paste(_ data: Data, dx: Float, dy: Float) -> [StrokeID] { [] }
    @discardableResult
    public func correct(_ ids: [StrokeID], strength: Float) -> Bool { false }
    @discardableResult
    public func straighten(_ ids: [StrokeID], strength: Float) -> Bool { false }
    public func takeDirty() -> CGRect { .null }
    public func renderOver(_ pixels: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int,
                           scale: Float, offsetX: Float, offsetY: Float) {}
    public func renderStrokesOver(_ ids: [StrokeID], _ pixels: UnsafeMutableRawPointer, width: Int, height: Int,
                                  bytesPerRow: Int, scale: Float, offsetX: Float, offsetY: Float) {}
    public func setHidden(_ ids: [StrokeID]) {}
    public func save() -> Data? { Data() }
    @discardableResult
    public func load(_ data: Data) -> Bool { true }
    public func exportSVG() -> String { "" }
}
