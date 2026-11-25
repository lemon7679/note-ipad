#if canImport(UIKit)
import InkBridge
import NoteKit
import SwiftUI

/// Tool palette opened by the Apple Pencil button (double tap / squeeze), shown around the pencil tip
/// (GoodNotes-style palette):
///  - a curved band wrapping the upper left of the tip with the tools, and undo at its lower end;
///  - at the band's top end, the width presets and the current color (tap the color for all colors);
///  - a small column to the left: pen settings, pen kinds and redo.
/// Tapping outside closes it, as does picking a tool or a color.
struct ToolWheel: View {
    @ObservedObject var model: EditorModel
    var onPenSettings: () -> Void

    /// Name of the option the pencil is hovering over, shown under the palette.
    @State private var hoverLabel: String?
    /// The pop-out under the width/color bar: all colors or the pen kinds.
    @State private var panel: Panel?
    @State private var appeared = false

    private enum Panel { case colors, kinds }

    /// Geometry around the anchor (the pencil tip), in points.
    /// Angles are degrees on screen: 0 = right, 90 = down, 180 = left, 270 = up.
    fileprivate enum Layout {
        static let radius: CGFloat = 140
        static let band: CGFloat = 56
        static let item: CGFloat = 42
        static let bandStart: CGFloat = 160
        static let bandEnd: CGFloat = 297
        static let undoAngle: CGFloat = 173
        static let dividerAngle: CGFloat = 183.5
        static let firstTool: CGFloat = 194
        static let toolStep: CGFloat = 18.5

        /// Width/color bar attached to the band's top end.
        static let barHeight: CGFloat = 48
        static let barSlot: CGFloat = 36
        static let barLead: CGFloat = 30
        static let barWidth: CGFloat = barLead + 4 * barSlot + 1 + 4 * 4 + 8
        /// Left column (pen settings, pen kinds, redo).
        static let columnWidth: CGFloat = 48
        static let columnHeight: CGFloat = 3 * 40 + 2 * 4 + 8
        static let columnCenter = CGPoint(x: -200, y: -62)
        static let panelWidth: CGFloat = 236

        /// Extent of everything around the anchor, for keeping the palette on screen.
        static let minX: CGFloat = -230, maxX: CGFloat = 282, minY: CGFloat = -172, maxY: CGFloat = 110

        static func point(_ angle: CGFloat, _ r: CGFloat = radius) -> CGPoint {
            let rad = angle * .pi / 180
            return CGPoint(x: r * cos(rad), y: r * sin(rad))
        }

        /// The band's top end, where the bar starts.
        static var barStart: CGPoint { point(bandEnd) }
    }

    private static let tools: [EditorTool] = [.pen, .highlighter, .eraser, .lasso, .text, .laser]

    /// The ink tool the colors and widths apply to.
    private var inkTarget: EditorTool {
        let t = model.tools.tool
        return t.inks || t == .text ? t : model.tools.lastInkTool
    }

    private var highlighter: Bool { inkTarget == .highlighter }

    private var palette: [String] {
        let base = highlighter ? NoteTheme.highlighterColors : NoteTheme.penColors
        var seen = Set<String>()
        return (base + model.tools.customColors).filter { seen.insert($0.uppercased()).inserted }
    }

    private var activeColor: String { highlighter ? model.tools.highlighterColor : model.tools.penColor }
    private var widths: [Double] { highlighter ? model.tools.highlighterWidths : model.tools.currentPenWidths }
    private var widthIndex: Int {
        min(max(highlighter ? model.tools.highlighterWidthIndex : model.tools.penWidthIndex, 0), widths.count - 1)
    }

    var body: some View {
        GeometryReader { geo in
            let a = anchor(in: geo.size)
            ZStack(alignment: .topLeading) {
                // Tap anywhere outside the palette to close it (and swallow the touch so it doesn't draw).
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { close() }
                paletteView(at: a)
                    .scaleEffect(appeared ? 1 : 0.6,
                                 anchor: UnitPoint(x: a.x / max(geo.size.width, 1), y: a.y / max(geo.size.height, 1)))
                    .opacity(appeared ? 1 : 0)
                if let hoverLabel {
                    Text(hoverLabel)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Color.black.opacity(0.75), in: Capsule())
                        .fixedSize()
                        .allowsHitTesting(false)
                        .position(x: a.x - 60, y: min(a.y + 96, geo.size.height - 18))
                }
            }
        }
        .onAppear { withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { appeared = true } }
    }

    /// Where the pencil was, moved just enough to keep the whole palette on screen.
    private func anchor(in size: CGSize) -> CGPoint {
        let p = model.toolWheel ?? CGPoint(x: size.width / 2, y: size.height / 2)
        func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { lo > hi ? (lo + hi) / 2 : min(max(v, lo), hi) }
        let m: CGFloat = 8
        return CGPoint(x: clamp(p.x, -Layout.minX + m, size.width - Layout.maxX - m),
                       y: clamp(p.y, -Layout.minY + m, size.height - Layout.maxY - m))
    }

    private func paletteView(at a: CGPoint) -> some View {
        ZStack(alignment: .topLeading) {
            backgrounds(at: a)
            bandItems(at: a)
            bar(at: a)
            column(at: a)
            if let panel {
                panelView(panel)
                    .offset(x: a.x + Layout.barStart.x - 22,
                            y: a.y + Layout.barStart.y + Layout.barHeight / 2 + 8)
                    .transition(.scale(scale: 0.9, anchor: .topLeading).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.15), value: panel)
    }

    /// Band, bar and column surfaces, drawn as one group so their shadow is shared.
    private func backgrounds(at a: CGPoint) -> some View {
        let bar = Layout.barStart
        return ZStack(alignment: .topLeading) {
            ArcBand(center: a, radius: Layout.radius, start: Layout.bandStart, end: Layout.bandEnd)
                .stroke(NoteTheme.surface, style: StrokeStyle(lineWidth: Layout.band, lineCap: .round))
            Capsule()
                .fill(NoteTheme.surface)
                .frame(width: Layout.barWidth, height: Layout.barHeight)
                .position(x: a.x + bar.x - 22 + Layout.barWidth / 2, y: a.y + bar.y)
            Capsule()
                .fill(NoteTheme.surface)
                .frame(width: Layout.columnWidth, height: Layout.columnHeight)
                .position(x: a.x + Layout.columnCenter.x, y: a.y + Layout.columnCenter.y)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
        // Taps on the palette's own surfaces must not close it.
        .contentShape(PaletteShape(anchor: a))
        .onTapGesture {}
    }

    // MARK: Band

    private func bandItems(at a: CGPoint) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(Self.tools.enumerated()), id: \.element) { index, tool in
                let p = Layout.point(Layout.firstTool + CGFloat(index) * Layout.toolStep)
                toolButton(tool).position(x: a.x + p.x, y: a.y + p.y)
            }
            let d = Layout.point(Layout.dividerAngle)
            Capsule()
                .fill(NoteTheme.controlBorder)
                .frame(width: 22, height: 1.5)
                .rotationEffect(.degrees(Double(Layout.dividerAngle)))
                .position(x: a.x + d.x, y: a.y + d.y)
                .allowsHitTesting(false)
            let u = Layout.point(Layout.undoAngle)
            iconButton("arrow.uturn.backward", label: "실행 취소", enabled: model.canUndo) { model.undo() }
                .position(x: a.x + u.x, y: a.y + u.y)
        }
    }

    private func toolButton(_ tool: EditorTool) -> some View {
        let on = model.tools.tool == tool
        return Button {
            model.tools.select(tool)
            close()
        } label: {
            Image(systemName: tool.symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(on ? Color.white : NoteTheme.textPrimary)
                .frame(width: Layout.item, height: Layout.item)
                .background(Circle().fill(on ? NoteTheme.accent : Color.clear))
                .overlay(alignment: .bottomTrailing) {
                    if tool.inks {
                        // Small dot with the tool's current color.
                        Circle()
                            .fill(Color(hex: tool == .highlighter ? model.tools.highlighterColor : model.tools.penColor))
                            .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                            .frame(width: 11, height: 11)
                            .offset(x: -2, y: -2)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(scale: 1.14, onHover: hovering(tool.label))
        .accessibilityLabel(tool.label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func iconButton(_ symbol: String, label: String, enabled: Bool = true, selected: Bool = false,
                            size: CGFloat = Layout.item, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(selected ? NoteTheme.accent : NoteTheme.textPrimary)
                .frame(width: size, height: size)
                .background(Circle().fill(selected ? NoteTheme.accentSoft : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .hoverHighlight(scale: 1.12, isEnabled: enabled, onHover: hovering(label))
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Width / color bar

    private func bar(at a: CGPoint) -> some View {
        let start = Layout.barStart
        return HStack(spacing: 4) {
            ForEach(Array(widths.enumerated()), id: \.offset) { index, width in
                widthButton(index, width)
            }
            Rectangle()
                .fill(NoteTheme.controlBorder)
                .frame(width: 1, height: 24)
            colorDot
        }
        .padding(.leading, Layout.barLead)
        .padding(.trailing, 8)
        .frame(width: Layout.barWidth, height: Layout.barHeight, alignment: .leading)
        .position(x: a.x + start.x - 22 + Layout.barWidth / 2, y: a.y + start.y)
    }

    private func widthButton(_ index: Int, _ width: Double) -> some View {
        let on = index == widthIndex
        let maxWidth = widths.max() ?? 1
        let label = highlighter ? String(format: "%.0fpt", width) : String(format: "%.1fmm", width / 72 * 25.4)
        return Button {
            if model.tools.tool != inkTarget { model.tools.select(inkTarget) }
            if highlighter { model.tools.highlighterWidthIndex = index } else { model.tools.penWidthIndex = index }
        } label: {
            Capsule()
                .fill(Color(hex: activeColor))
                .overlay(Capsule().stroke(NoteTheme.controlBorder.opacity(activeColor.uppercased() == "#FFFFFF" ? 1 : 0)))
                .frame(width: 18, height: max(2, CGFloat(width / maxWidth) * 8))
                .rotationEffect(.degrees(-35))
                .frame(width: Layout.barSlot, height: Layout.barSlot)
                .background(Circle().fill(on ? NoteTheme.accentSoft : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(scale: 1.12, onHover: hovering("굵기 \(label)"))
        .accessibilityLabel("굵기 \(label)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// The current color; tap to show all colors.
    private var colorDot: some View {
        let open = panel == .colors
        return Button {
            panel = open ? nil : .colors
        } label: {
            Circle()
                .fill(Color(hex: activeColor))
                .overlay(Circle().stroke(NoteTheme.controlBorder.opacity(activeColor.uppercased() == "#FFFFFF" ? 1 : 0)))
                .frame(width: 24, height: 24)
                .padding(4)
                .overlay(Circle().stroke(open ? NoteTheme.accent : NoteTheme.controlBorder, lineWidth: open ? 2 : 1))
                .frame(width: Layout.barSlot, height: Layout.barSlot)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(scale: 1.12, onHover: hovering(highlighter ? "형광펜 색" : "펜 색"))
        .accessibilityLabel(highlighter ? "형광펜 색" : "펜 색")
    }

    // MARK: Left column

    private func column(at a: CGPoint) -> some View {
        VStack(spacing: 4) {
            iconButton("slider.horizontal.3", label: "펜 설정", size: 40) {
                let t = model.tools.tool
                if !(t.inks || t == .eraser) { model.tools.select(model.tools.lastInkTool) }
                close()
                onPenSettings()
            }
            iconButton("scribble.variable", label: "펜 종류", enabled: !highlighter,
                       selected: panel == .kinds, size: 40) {
                panel = panel == .kinds ? nil : .kinds
            }
            iconButton("arrow.uturn.forward", label: "다시 실행", enabled: model.canRedo, size: 40) { model.redo() }
        }
        .frame(width: Layout.columnWidth, height: Layout.columnHeight)
        .position(x: a.x + Layout.columnCenter.x, y: a.y + Layout.columnCenter.y)
    }

    // MARK: Pop-out panel

    @ViewBuilder
    private func panelView(_ panel: Panel) -> some View {
        Group {
            switch panel {
            case .colors: colorsGrid
            case .kinds: kindsGrid
            }
        }
        .padding(7)
        .frame(width: Layout.panelWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(NoteTheme.surface))
        .compositingGroup()
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture {}
    }

    private var colorsGrid: some View {
        let columns = Array(repeating: GridItem(.fixed(32), spacing: 6), count: 6)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(palette, id: \.self) { hex in
                colorSwatch(hex)
            }
        }
    }

    private func colorSwatch(_ hex: String) -> some View {
        let selected = activeColor.uppercased() == hex.uppercased()
        return Button {
            if model.tools.tool != inkTarget { model.tools.select(inkTarget) }
            model.tools.setColor(hex)
            close()
        } label: {
            Circle().fill(Color(hex: hex))
                .overlay(Circle().stroke(NoteTheme.controlBorder.opacity(hex.uppercased() == "#FFFFFF" ? 1 : 0)))
                .padding(4)
                .frame(width: 32, height: 32)
                .overlay(Circle().stroke(selected ? NoteTheme.accent : Color.clear, lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(scale: 1.18, onHover: hovering(highlighter ? "형광펜 색" : "펜 색"))
        .accessibilityLabel("색 \(hex)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var kindsGrid: some View {
        let columns = Array(repeating: GridItem(.fixed(70), spacing: 6), count: 3)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(BrushKind.pens, id: \.self) { kind in
                kindButton(kind)
            }
        }
    }

    private func kindButton(_ kind: BrushKind) -> some View {
        let on = model.tools.penKind == kind
        return Button {
            if model.tools.tool != .pen { model.tools.select(.pen) }
            model.tools.penKind = kind
            panel = nil
        } label: {
            Text(kind.label)
                .font(.system(size: 12, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Color.white : NoteTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 70, height: 34)
                .background(Capsule().fill(on ? NoteTheme.accent : NoteTheme.fieldFill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hoverHighlight(Capsule(), scale: 1.06, onHover: hovering(kind.label))
        .accessibilityLabel(kind.label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Helpers

    /// Hover callback that shows `label` while hovering and clears it on exit.
    private func hovering(_ label: String) -> (Bool) -> Void {
        { on in
            if on { hoverLabel = label } else if hoverLabel == label { hoverLabel = nil }
        }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.15)) { model.toolWheel = nil }
    }
}

/// Arc around `center` from `start` to `end` degrees (screen angles), for stroking as a band.
private struct ArcBand: Shape {
    let center: CGPoint
    let radius: CGFloat
    let start: CGFloat
    let end: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addArc(center: center, radius: radius, startAngle: .degrees(Double(start)),
                 endAngle: .degrees(Double(end)), clockwise: false)
        return p
    }
}

/// Hit area of the palette's surfaces (band, bar and column) around `anchor`.
private struct PaletteShape: Shape {
    let anchor: CGPoint

    func path(in rect: CGRect) -> Path {
        typealias L = ToolWheel.Layout
        var p = ArcBand(center: anchor, radius: L.radius, start: L.bandStart, end: L.bandEnd)
            .path(in: rect)
            .strokedPath(StrokeStyle(lineWidth: L.band, lineCap: .round))
        let bar = L.barStart
        p.addRoundedRect(in: CGRect(x: anchor.x + bar.x - 22, y: anchor.y + bar.y - L.barHeight / 2,
                                    width: L.barWidth, height: L.barHeight),
                         cornerSize: CGSize(width: L.barHeight / 2, height: L.barHeight / 2))
        p.addRoundedRect(in: CGRect(x: anchor.x + L.columnCenter.x - L.columnWidth / 2,
                                    y: anchor.y + L.columnCenter.y - L.columnHeight / 2,
                                    width: L.columnWidth, height: L.columnHeight),
                         cornerSize: CGSize(width: L.columnWidth / 2, height: L.columnWidth / 2))
        return p
    }
}
#endif
