#if canImport(UIKit)
import Foundation
import InkBridge
import NoteKit

enum EditorTool: String, Codable, CaseIterable, Identifiable {
    case pen, highlighter, eraser, lasso, text, image, laser

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pen: return "펜"
        case .highlighter: return "형광펜"
        case .eraser: return "지우개"
        case .lasso: return "올가미 선택"
        case .text: return "텍스트"
        case .image: return "이미지"
        case .laser: return "레이저 포인터"
        }
    }

    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .eraser: return "eraser"
        case .lasso: return "lasso"
        case .text: return "textformat"
        case .image: return "photo"
        case .laser: return "cursorarrow.rays"
        }
    }

    /// Tools whose strokes go into the page.
    var inks: Bool { self == .pen || self == .highlighter }
}

extension BrushKind {
    var label: String {
        switch self {
        case .ballpoint: return "볼펜"
        case .pencil: return "연필"
        case .highlighter: return "형광펜"
        case .fountainPen: return "만년필"
        case .brushPen: return "붓펜"
        case .calligraphy: return "캘리그라피"
        case .marker: return "마커"
        }
    }

    /// Pens offered in the pen picker (the highlighter has its own tool).
    static let pens: [BrushKind] = [.ballpoint, .fountainPen, .pencil, .brushPen, .calligraphy, .marker]

    var defaultWidths: [Double] {
        switch self {
        case .ballpoint: return [0.9, 1.4, 2.2]
        case .fountainPen: return [1.0, 1.6, 2.6]
        case .pencil: return [1.0, 1.6, 2.6]
        case .brushPen: return [1.6, 2.8, 4.5]
        case .calligraphy: return [2.0, 3.5, 5.5]
        case .marker: return [2.5, 4.0, 6.0]
        case .highlighter: return [8, 12, 18]
        }
    }
}

extension InkRGBA {
    init(hex: String, alpha: Float = 1) {
        let c = RGBAColor(hex: hex) ?? RGBAColor(r: 0, g: 0, b: 0)
        self.init(r: Float(c.r), g: Float(c.g), b: Float(c.b), a: alpha)
    }
}

/// The tool palette, shared by all notebooks (UserDefaults).
struct ToolState: Codable, Equatable {
    var tool: EditorTool = .pen
    var lastInkTool: EditorTool = .pen

    var penKind: BrushKind = .ballpoint
    var penColor = "#1C1C1E"
    /// Three width presets per pen kind (page points).
    var penWidths: [BrushKind: [Double]] = [:]
    var penWidthIndex = 1

    var highlighterColor = "#FFE45C"
    var highlighterWidths: [Double] = [8, 12, 18]
    var highlighterWidthIndex = 1
    /// Highlighter snaps to a straight line when the pen rests.
    var highlighterStraight = true

    var eraserMode: EraserMode = .precise
    /// Eraser diameter in screen points.
    var eraserSize: Double = 14
    var eraseHighlighterOnly = false
    /// Switch back to the previous tool after an erase stroke made with a double tap.
    var eraserReturns = false

    /// Draw-and-hold shapes.
    var snapShapes = true
    /// Handwriting correction 0…1.
    var correction: Double = 0.3
    /// Extra stabilizer (moving average window, ms). 0 = off.
    var stabilizer: Double = 0

    /// Colors picked with the custom color picker (most recent first).
    var customColors: [String] = []

    var currentPenWidths: [Double] { penWidths[penKind] ?? penKind.defaultWidths }

    var penWidth: Double {
        let w = currentPenWidths
        return w[min(max(penWidthIndex, 0), w.count - 1)]
    }

    var highlighterWidth: Double {
        highlighterWidths[min(max(highlighterWidthIndex, 0), highlighterWidths.count - 1)]
    }

    var activeColor: String { tool == .highlighter ? highlighterColor : penColor }

    mutating func select(_ newTool: EditorTool) {
        if newTool.inks { lastInkTool = newTool }
        tool = newTool
    }

    mutating func setColor(_ hex: String) {
        if tool == .highlighter { highlighterColor = hex } else { penColor = hex }
    }

    mutating func setWidth(_ width: Double, at index: Int) {
        if tool == .highlighter {
            highlighterWidths[index] = width
            highlighterWidthIndex = index
        } else {
            var widths = currentPenWidths
            widths[index] = width
            penWidths[penKind] = widths
            penWidthIndex = index
        }
    }

    mutating func rememberCustomColor(_ hex: String) {
        customColors.removeAll { $0 == hex }
        customColors.insert(hex, at: 0)
        if customColors.count > 8 { customColors.removeLast() }
    }

    /// Configures the engine's stroke builder for the next stroke.
    func configure(_ builder: StrokeBuilder, viewScale: Float) {
        if tool == .highlighter {
            builder.setBrush(.highlighter, color: InkRGBA(hex: highlighterColor), width: Float(highlighterWidth))
            builder.setSnapOnHold(highlighterStraight)
            builder.setCorrection(0)
        } else {
            builder.setBrush(penKind, color: InkRGBA(hex: penColor), width: Float(penWidth))
            builder.setSnapOnHold(snapShapes)
            builder.setCorrection(Float(correction))
        }
        builder.setStabilizer(stabilizer > 0 ? .movingAverage : .none, amount: Float(stabilizer))
        builder.setViewScale(viewScale)
    }

    static func load() -> ToolState {
        guard let data = UserDefaults.standard.data(forKey: "tools"),
              let state = try? JSONDecoder().decode(ToolState.self, from: data) else { return ToolState() }
        return state
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "tools") }
    }
}
#endif
