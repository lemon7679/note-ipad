import Foundation
import InkEngine

// Swift face of note-core's InkEngine C API (`ink_c.h`). The app talks only to
// these types; `Sources/InkBridgeStub` mirrors them for CI builds without the
// engine, so keep the two files' public API identical.
//
// Engine objects are not thread-safe: use them from the main thread.

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
    /// force / maximumPossibleForce; < 0 when unavailable (finger).
    public var pressure: Float
    /// Radians, π/2 = upright; < 0 when unavailable.
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

    var raw: InkInputPoint {
        var p = InkInputPoint()
        p.x = x
        p.y = y
        p.pressure = pressure
        p.altitude = altitude
        p.azimuth = azimuth
        p.time = time
        p.update_id = updateID
        var flags: UInt32 = 0
        if expectsPressureUpdate { flags |= INK_INPUT_PRESSURE_EXPECTS_UPDATE.rawValue }
        if expectsTiltUpdate { flags |= INK_INPUT_TILT_EXPECTS_UPDATE.rawValue }
        p.flags = flags
        p.source = isPencil ? INK_SOURCE_PENCIL.rawValue : INK_SOURCE_TOUCH.rawValue
        return p
    }
}

private extension InkRGBA {
    var raw: InkColor { InkColor(r: r, g: g, b: b, a: a) }
}

private func rect(_ r: InkRect) -> CGRect {
    r.width > 0 && r.height > 0
        ? CGRect(x: CGFloat(r.x), y: CGFloat(r.y), width: CGFloat(r.width), height: CGFloat(r.height))
        : .null
}

// MARK: - Stroke builder

/// The stroke being drawn (input filtering, dynamics, draw-and-hold shapes).
public final class StrokeBuilder {
    let raw: OpaquePointer

    public init(kind: BrushKind) {
        raw = ink_builder_create(InkBrushKind(rawValue: UInt32(kind.rawValue)))
    }

    deinit { ink_builder_destroy(raw) }

    public func setBrush(_ kind: BrushKind, color: InkRGBA, width: Float) {
        ink_builder_set_brush(raw, InkBrushKind(rawValue: UInt32(kind.rawValue)), color.raw, width)
    }

    public func setColor(_ color: InkRGBA) { ink_builder_set_color(raw, color.raw) }
    public func setWidth(_ width: Float) { ink_builder_set_width(raw, width) }
    public func setOpacity(_ opacity: Float) { ink_builder_set_opacity(raw, opacity) }

    public func setStabilizer(_ mode: StabilizerMode, amount: Float) {
        ink_builder_set_stabilizer(raw, InkStabilizerMode(rawValue: UInt32(mode.rawValue)), amount)
    }

    public func setPressureCurve(_ c1x: Float, _ c1y: Float, _ c2x: Float, _ c2y: Float) {
        ink_builder_set_pressure_curve(raw, c1x, c1y, c2x, c2y)
    }

    public func setSnapOnHold(_ enabled: Bool) { ink_builder_set_snap_on_hold(raw, enabled) }
    /// View points per page unit (zoom).
    public func setViewScale(_ scale: Float) { ink_builder_set_view_scale(raw, scale) }
    /// 글씨 보정 0 (off) … 1 (strong).
    public func setCorrection(_ strength: Float) { ink_builder_set_correction(raw, strength) }

    public func setCorrectionOptions(live: Bool, smoothCurves: Bool, straightenLines: Bool, snapToAxes: Bool) {
        ink_builder_set_correction_options(raw, live, smoothCurves, straightenLines, snapToAxes)
    }

    /// Perfect shapes while a second finger rests on the screen.
    public func setShapeConstraint(_ constrained: Bool) { ink_builder_set_shape_constraint(raw, constrained) }

    public func begin(_ sample: PenSample) {
        var p = sample.raw
        ink_builder_begin(raw, &p)
    }

    public func add(_ samples: [PenSample]) {
        guard !samples.isEmpty else { return }
        let pts = samples.map(\.raw)
        ink_builder_add_points(raw, pts, pts.count)
    }

    public func setPredicted(_ samples: [PenSample]) {
        let pts = samples.map(\.raw)
        if pts.isEmpty {
            ink_builder_set_predicted(raw, nil, 0)
        } else {
            ink_builder_set_predicted(raw, pts, pts.count)
        }
    }

    @discardableResult
    public func updateEstimated(id: UInt64, pressure: Float, altitude: Float, azimuth: Float) -> Bool {
        ink_builder_update_estimated(raw, id, pressure, altitude, azimuth)
    }

    /// Call every display frame while drawing; true when the stroke just snapped to a shape.
    public func tick(now: Double) -> Bool { ink_builder_tick(raw, now) }
    public func end() { ink_builder_end(raw) }
    public func cancel() { ink_builder_cancel(raw) }

    public var isActive: Bool { ink_builder_is_active(raw) }
    public var pointCount: Int { Int(ink_builder_point_count(raw)) }
    public var snappedShape: SnappedShape { SnappedShape(rawValue: Int(ink_builder_snapped_shape(raw).rawValue)) ?? .none }

    /// Highlighter-style strokes composite with Multiply.
    public var blendsMultiply: Bool {
        var info = InkStyleInfo()
        ink_builder_get_style(raw, &info)
        return info.blend == 1
    }

    /// Advances the incremental geometry; returns the page area that changed (`.null` if none).
    public func updateGeometry(pixelsPerUnit: Float) -> CGRect {
        var live = InkLiveGeometry()
        guard ink_builder_update_geometry(raw, pixelsPerUnit, &live) else { return .null }
        return rect(live.dirty)
    }

    /// Draws the live stroke (from the last `updateGeometry`) over premultiplied RGBA8 pixels.
    public func renderOver(_ pixels: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int,
                           scale: Float, offsetX: Float, offsetY: Float) {
        ink_builder_render_over_rgba(raw, pixels.assumingMemoryBound(to: UInt8.self), Int32(width), Int32(height),
                                     bytesPerRow, scale, offsetX, offsetY)
    }
}

// MARK: - Page

/// One page of ink with its own undo history.
public final class InkPage {
    let raw: OpaquePointer

    public init(width: Float, height: Float) {
        raw = ink_editor_create(width, height)
    }

    deinit { ink_editor_destroy(raw) }

    public static var engineVersion: String { String(cString: ink_version()) }

    public var pageWidth: Float { ink_editor_page_width(raw) }
    public var pageHeight: Float { ink_editor_page_height(raw) }
    public var strokeCount: Int { Int(ink_editor_stroke_count(raw)) }
    public var canUndo: Bool { ink_editor_can_undo(raw) }
    public var canRedo: Bool { ink_editor_can_redo(raw) }

    /// Adds the builder's finished stroke (after `end()`); 0 on failure.
    @discardableResult
    public func commit(_ builder: StrokeBuilder) -> StrokeID { ink_editor_commit(raw, builder.raw) }

    @discardableResult public func undo() -> Bool { ink_editor_undo(raw) }
    @discardableResult public func redo() -> Bool { ink_editor_redo(raw) }

    // Eraser

    public func eraseBegin(mode: EraserMode, radius: Float, highlighterOnly: Bool, at point: CGPoint) {
        let mask: UInt32 = highlighterOnly ? (1 << UInt32(BrushKind.highlighter.rawValue)) : 0
        ink_editor_erase_begin(raw, InkEraserMode(rawValue: UInt32(mode.rawValue)), radius, mask,
                               Float(point.x), Float(point.y))
    }

    @discardableResult
    public func eraseMove(to point: CGPoint) -> Bool { ink_editor_erase_move(raw, Float(point.x), Float(point.y)) }
    public func eraseEnd() { ink_editor_erase_end(raw) }

    // Selection & editing

    public func selectLasso(_ points: [CGPoint]) -> [StrokeID] {
        guard points.count >= 3 else { return [] }
        var xy: [Float] = []
        xy.reserveCapacity(points.count * 2)
        for p in points {
            xy.append(Float(p.x))
            xy.append(Float(p.y))
        }
        let capacity = max(strokeCount, 1)
        var out = [StrokeID](repeating: 0, count: capacity)
        let n = ink_editor_select_lasso(raw, xy, points.count, &out, capacity)
        return Array(out.prefix(min(Int(n), capacity)))
    }

    @discardableResult
    public func transform(_ ids: [StrokeID], _ t: InkAffine) -> Bool {
        guard !ids.isEmpty else { return false }
        return ink_editor_transform(raw, ids, ids.count, t.a, t.b, t.c, t.d, t.tx, t.ty)
    }

    @discardableResult
    public func recolor(_ ids: [StrokeID], _ color: InkRGBA) -> Bool {
        guard !ids.isEmpty else { return false }
        return ink_editor_recolor(raw, ids, ids.count, color.raw)
    }

    @discardableResult
    public func delete(_ ids: [StrokeID]) -> Bool {
        guard !ids.isEmpty else { return false }
        return ink_editor_delete(raw, ids, ids.count)
    }

    public func duplicate(_ ids: [StrokeID], dx: Float, dy: Float) -> [StrokeID] {
        guard !ids.isEmpty else { return [] }
        let capacity = ids.count
        var out = [StrokeID](repeating: 0, count: capacity)
        let n = ink_editor_duplicate(raw, ids, ids.count, dx, dy, &out, capacity)
        return Array(out.prefix(min(Int(n), capacity)))
    }

    /// Ink bounds of the strokes in page units (`.null` if none).
    public func bounds(of ids: [StrokeID]) -> CGRect {
        guard !ids.isEmpty else { return .null }
        return rect(ink_editor_bounds_of(raw, ids, ids.count))
    }

    /// Serialized strokes for the clipboard.
    public func copyStrokes(_ ids: [StrokeID]) -> Data? {
        guard !ids.isEmpty else { return nil }
        var size = 0
        guard let ptr = ink_editor_copy_strokes(raw, ids, ids.count, &size) else { return nil }
        defer { ink_free(ptr) }
        return Data(bytes: ptr, count: size)
    }

    /// Pastes clipboard strokes moved by (dx, dy); one undo step. Returns the new ids.
    public func paste(_ data: Data, dx: Float, dy: Float) -> [StrokeID] {
        guard !data.isEmpty else { return [] }
        let capacity = 4096
        var out = [StrokeID](repeating: 0, count: capacity)
        let count = data.count
        let n = data.withUnsafeBytes { buf -> Int in
            guard let base = buf.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return Int(ink_editor_paste_strokes(raw, base, count, dx, dy, &out, capacity))
        }
        return Array(out.prefix(min(n, capacity)))
    }

    /// 글씨 다듬기 on written strokes (one undo step).
    @discardableResult
    public func correct(_ ids: [StrokeID], strength: Float) -> Bool {
        guard !ids.isEmpty else { return false }
        return ink_editor_correct(raw, ids, ids.count, strength)
    }

    /// 줄 정렬 (one undo step).
    @discardableResult
    public func straighten(_ ids: [StrokeID], strength: Float) -> Bool {
        guard !ids.isEmpty else { return false }
        return ink_editor_straighten(raw, ids, ids.count, strength)
    }

    /// Page area changed since the last call (`.null` if none).
    public func takeDirty() -> CGRect { rect(ink_editor_take_dirty(raw)) }

    // Rendering (premultiplied RGBA8, Core Graphics `premultipliedLast`)

    /// Composites the page's ink over pixels that already hold the background.
    public func renderOver(_ pixels: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int,
                           scale: Float, offsetX: Float, offsetY: Float) {
        ink_editor_render_over_rgba(raw, pixels.assumingMemoryBound(to: UInt8.self), Int32(width), Int32(height),
                                    bytesPerRow, scale, offsetX, offsetY)
    }

    /// Draws only `ids` (lasso drag preview layer).
    public func renderStrokesOver(_ ids: [StrokeID], _ pixels: UnsafeMutableRawPointer, width: Int, height: Int,
                                  bytesPerRow: Int, scale: Float, offsetX: Float, offsetY: Float) {
        guard !ids.isEmpty else { return }
        ink_editor_render_strokes_over_rgba(raw, ids, ids.count, pixels.assumingMemoryBound(to: UInt8.self),
                                            Int32(width), Int32(height), bytesPerRow, scale, offsetX, offsetY)
    }

    /// Strokes skipped by `renderOver` (while a selection is being dragged).
    public func setHidden(_ ids: [StrokeID]) {
        if ids.isEmpty {
            ink_editor_set_hidden(raw, nil, 0)
        } else {
            ink_editor_set_hidden(raw, ids, ids.count)
        }
    }

    // Persistence

    public func save() -> Data? {
        var size = 0
        guard let ptr = ink_editor_save(raw, &size) else { return nil }
        defer { ink_free(ptr) }
        return Data(bytes: ptr, count: size)
    }

    @discardableResult
    public func load(_ data: Data) -> Bool {
        let count = data.count
        return data.withUnsafeBytes { buf -> Bool in
            guard let base = buf.bindMemory(to: UInt8.self).baseAddress else { return false }
            return ink_editor_load(raw, base, count)
        }
    }

    /// Vector outlines (SVG) for PDF export.
    public func exportSVG() -> String {
        guard let ptr = ink_editor_export_svg(raw) else { return "" }
        defer { ink_free(ptr) }
        return String(cString: ptr)
    }
}
