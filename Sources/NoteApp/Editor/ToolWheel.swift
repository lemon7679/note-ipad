#if canImport(UIKit)
import InkBridge
import NoteKit
import SwiftUI

/// Tool menu opened by the Apple Pencil button (double tap / squeeze), docked in the top-left
/// corner of the page area as a quarter circle so it covers little of the page.
///
/// Three arcs, each dragged along its curve to show more options:
///  - outer: tools, undo/redo and pen settings;
///  - middle: all colors of the current pen (or highlighter), including recent custom colors;
///  - inner: width presets and, for the pen, the pen kinds.
/// The corner button (current tool) closes it, as does tapping outside.
struct ToolWheel: View {
    @ObservedObject var model: EditorModel
    var onPenSettings: () -> Void

    /// Name of the option the pencil is hovering over, shown next to the wheel.
    @State private var hoverLabel: String?
    /// Scroll angle (degrees) of each arc: tools, colors, options.
    @State private var scroll: [CGFloat]?
    @State private var dragArc: Int?
    @State private var dragAngle: CGFloat = 0
    /// While dragging (and just after) item taps are ignored so a drag never picks an option.
    @State private var dragging = false
    @State private var dragEnded = Date.distantPast

    /// Radius of the quarter disk.
    static let radius: CGFloat = 268

    /// One arc of options around the corner. Angles are degrees from the top edge (0°) to the left edge (90°).
    fileprivate struct Arc {
        let radius: CGFloat
        let step: CGFloat
        let itemSize: CGFloat

        /// Angle of the first item when not scrolled.
        var start: CGFloat { step * 0.6 }

        /// Largest scroll angle: the last item sits as far from the left edge as the first from the top.
        func maxScroll(_ count: Int) -> CGFloat { max(0, CGFloat(count - 1) * step + 2 * start - 90) }

        func angle(_ index: Int, scroll: CGFloat) -> CGFloat { start + CGFloat(index) * step - scroll }
    }

    private static let toolsArc = Arc(radius: 222, step: 17, itemSize: 46)
    private static let colorsArc = Arc(radius: 158, step: 18, itemSize: 36)
    private static let optionsArc = Arc(radius: 98, step: 27, itemSize: 40)
    private static let arcs = [toolsArc, colorsArc, optionsArc]

    /// Which arc a touch at `distance` from the corner belongs to (nil = the corner button).
    private static func arc(at distance: CGFloat) -> Int? {
        if distance >= (toolsArc.radius + colorsArc.radius) / 2 { return 0 }
        if distance >= (colorsArc.radius + optionsArc.radius) / 2 { return 1 }
        if distance >= 56 { return 2 }
        return nil
    }

    private enum Item: Hashable {
        case tool(EditorTool)
        case undo, redo, settings

        var symbol: String {
            switch self {
            case .tool(let t): return t.symbol
            case .undo: return "arrow.uturn.backward"
            case .redo: return "arrow.uturn.forward"
            case .settings: return "slider.horizontal.3"
            }
        }

        var label: String {
            switch self {
            case .tool(let t): return t.label
            case .undo: return "실행 취소"
            case .redo: return "다시 실행"
            case .settings: return "펜 설정"
            }
        }
    }

    private static let items: [Item] = [
        .tool(.pen), .tool(.highlighter), .tool(.eraser), .tool(.lasso), .tool(.text), .tool(.laser),
        .undo, .redo, .settings,
    ]

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
    private var kinds: [BrushKind] { highlighter ? [] : BrushKind.pens }
    private var counts: [Int] { [Self.items.count, palette.count, widths.count + kinds.count] }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Tap anywhere outside the wheel to close it (and swallow the touch so it doesn't draw).
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { close() }
            wheel
                .transition(.scale(scale: 0.4, anchor: .topLeading).combined(with: .opacity))
            if let hoverLabel {
                Text(hoverLabel)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Color.black.opacity(0.75), in: Capsule())
                    .allowsHitTesting(false)
                    .offset(x: Self.radius + 10, y: 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { if scroll == nil { scroll = initialScroll() } }
    }

    private var wheel: some View {
        let s = scroll ?? [0, 0, 0]
        return ZStack(alignment: .topLeading) {
            QuarterDisk()
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
                // Taps on the wheel's own background must not close it.
                .contentShape(QuarterDisk())
                .onTapGesture {}
            // Tracks behind each arc.
            ForEach(0..<Self.arcs.count, id: \.self) { i in
                let arc = Self.arcs[i]
                Circle()
                    .stroke(NoteTheme.fieldFill.opacity(0.55), lineWidth: arc.itemSize + 12)
                    .frame(width: arc.radius * 2, height: arc.radius * 2)
                    .position(x: 0, y: 0)
                    .allowsHitTesting(false)
            }
            ForEach(Array(Self.items.enumerated()), id: \.element) { index, item in
                slot(Self.toolsArc, index, scroll: s[0]) { itemButton(item) }
            }
            ForEach(Array(palette.enumerated()), id: \.element) { index, hex in
                slot(Self.colorsArc, index, scroll: s[1]) { colorButton(hex) }
            }
            ForEach(Array(widths.enumerated()), id: \.offset) { index, width in
                slot(Self.optionsArc, index, scroll: s[2]) { widthButton(index, width) }
            }
            ForEach(Array(kinds.enumerated()), id: \.element) { index, kind in
                slot(Self.optionsArc, widths.count + index, scroll: s[2]) { kindButton(kind) }
            }
            cornerButton
                .position(x: 6 + 22, y: 6 + 22)
        }
        .frame(width: Self.radius, height: Self.radius)
        .clipShape(QuarterDisk())
        .contentShape(QuarterDisk())
        .coordinateSpace(name: "toolWheel")
        .simultaneousGesture(arcDrag)
    }

    /// Dragging along an arc scrolls that arc.
    private var arcDrag: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("toolWheel"))
            .onChanged { value in
                if !dragging {
                    dragging = true
                    let p = value.startLocation
                    dragArc = Self.arc(at: hypot(p.x, p.y))
                    dragAngle = Self.angle(of: p)
                }
                let a = Self.angle(of: value.location)
                if let i = dragArc, var s = scroll {
                    s[i] = min(max(s[i] - (a - dragAngle), 0), Self.arcs[i].maxScroll(counts[i]))
                    scroll = s
                }
                dragAngle = a
            }
            .onEnded { _ in
                dragging = false
                dragArc = nil
                dragEnded = Date()
            }
    }

    private static func angle(of p: CGPoint) -> CGFloat { atan2(p.y, p.x) * 180 / .pi }

    /// Start with the current tool, color and pen kind in view.
    private func initialScroll() -> [CGFloat] {
        func initial(_ arc: Arc, _ index: Int, _ count: Int) -> CGFloat {
            min(max(arc.angle(index, scroll: 0) - 60, 0), arc.maxScroll(count))
        }
        let toolIndex = Self.items.firstIndex(of: .tool(model.tools.tool)) ?? 0
        let colorIndex = palette.firstIndex { $0.uppercased() == activeColor.uppercased() } ?? 0
        let kindIndex = widths.count + (kinds.firstIndex(of: model.tools.penKind) ?? 0)
        return [
            initial(Self.toolsArc, toolIndex, counts[0]),
            initial(Self.colorsArc, colorIndex, counts[1]),
            kinds.isEmpty ? 0 : initial(Self.optionsArc, kindIndex, counts[2]),
        ]
    }

    /// Places `content` at position `index` on `arc`. Items fade out near the top and left edges
    /// and are left out once fully outside.
    @ViewBuilder
    private func slot<Content: View>(_ arc: Arc, _ index: Int, scroll: CGFloat,
                                     @ViewBuilder content: () -> Content) -> some View {
        let angle = arc.angle(index, scroll: scroll)
        let alpha = min(max(min(angle + 2, 92 - angle) / 9, 0), 1)
        if alpha > 0.05 {
            let rad = angle * .pi / 180
            content()
                .opacity(alpha)
                .position(x: arc.radius * cos(rad), y: arc.radius * sin(rad))
        }
    }

    /// Item taps are ignored while an arc is being dragged.
    private var tapAllowed: Bool { !dragging && Date().timeIntervalSince(dragEnded) > 0.15 }

    /// Hover callback that shows `label` while hovering and clears it on exit.
    private func hovering(_ label: String) -> (Bool) -> Void {
        { on in
            if on { hoverLabel = label } else if hoverLabel == label { hoverLabel = nil }
        }
    }

    private func isEnabled(_ item: Item) -> Bool {
        switch item {
        case .undo: return model.canUndo
        case .redo: return model.canRedo
        default: return true
        }
    }

    private func itemButton(_ item: Item) -> some View {
        let on: Bool = { if case .tool(let t) = item { return model.tools.tool == t }; return false }()
        let size = Self.toolsArc.itemSize
        return Button {
            guard tapAllowed else { return }
            perform(item)
        } label: {
            Image(systemName: item.symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(on ? Color.white : NoteTheme.textPrimary)
                .frame(width: size, height: size)
                .background(Circle().fill(on ? NoteTheme.accent : NoteTheme.surface))
                .overlay(Circle().stroke(on ? Color.clear : NoteTheme.controlBorder))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled(item))
        .opacity(isEnabled(item) ? 1 : 0.35)
        .hoverHighlight(scale: 1.14, isEnabled: isEnabled(item), onHover: hovering(item.label))
        .accessibilityLabel(item.label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func colorButton(_ hex: String) -> some View {
        let selected = activeColor.uppercased() == hex.uppercased()
        let size = Self.colorsArc.itemSize
        return Button {
            guard tapAllowed else { return }
            if model.tools.tool != inkTarget { model.tools.select(inkTarget) }
            model.tools.setColor(hex)
            close()
        } label: {
            Circle().fill(Color(hex: hex))
                .overlay(Circle().stroke(NoteTheme.controlBorder.opacity(hex.uppercased() == "#FFFFFF" ? 1 : 0)))
                .padding(4)
                .frame(width: size, height: size)
                .overlay(Circle().stroke(selected ? NoteTheme.accent : Color.clear, lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(scale: 1.18, onHover: hovering(highlighter ? "형광펜 색" : "펜 색"))
        .accessibilityLabel("색 \(hex)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func widthButton(_ index: Int, _ width: Double) -> some View {
        let on = index == widthIndex
        let maxWidth = widths.max() ?? 1
        let label = highlighter ? String(format: "%.0fpt", width) : String(format: "%.1fmm", width / 72 * 25.4)
        let size = Self.optionsArc.itemSize
        return Button {
            guard tapAllowed else { return }
            if model.tools.tool != inkTarget { model.tools.select(inkTarget) }
            if highlighter { model.tools.highlighterWidthIndex = index } else { model.tools.penWidthIndex = index }
        } label: {
            VStack(spacing: 2) {
                Capsule()
                    .fill(Color(hex: activeColor))
                    .frame(width: 20, height: max(2, width / maxWidth * 8))
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(NoteTheme.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: size, height: size)
            .background(Circle().fill(on ? NoteTheme.accentSoft : NoteTheme.surface))
            .overlay(Circle().stroke(on ? NoteTheme.accent : NoteTheme.controlBorder))
        }
        .buttonStyle(.plain)
        .hoverHighlight(scale: 1.12, onHover: hovering("굵기 \(label)"))
        .accessibilityLabel("굵기 \(label)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func kindButton(_ kind: BrushKind) -> some View {
        let on = model.tools.penKind == kind
        let size = Self.optionsArc.itemSize
        return Button {
            guard tapAllowed else { return }
            if model.tools.tool != inkTarget { model.tools.select(inkTarget) }
            model.tools.penKind = kind
        } label: {
            Text(kind == .calligraphy ? "캘리" : kind.label)
                .font(.system(size: 11, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Color.white : NoteTheme.textPrimary)
                .lineLimit(1)
                .frame(width: size, height: size)
                .background(Circle().fill(on ? NoteTheme.accent : NoteTheme.surface))
                .overlay(Circle().stroke(on ? Color.clear : NoteTheme.controlBorder))
        }
        .buttonStyle(.plain)
        .hoverHighlight(scale: 1.12, onHover: hovering(kind.label))
        .accessibilityLabel(kind.label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Corner: the current tool; tap to close.
    private var cornerButton: some View {
        Button {
            close()
        } label: {
            Image(systemName: model.tools.tool.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(NoteTheme.accent))
        }
        .buttonStyle(.plain)
        .hoverHighlight(scale: 1.1, onHover: hovering("닫기"))
        .accessibilityLabel("도구 휠 닫기")
    }

    private func perform(_ item: Item) {
        switch item {
        case .tool(let t):
            model.tools.select(t)
            close()
        case .undo:
            model.undo()
        case .redo:
            model.redo()
        case .settings:
            let t = model.tools.tool
            if !(t.inks || t == .eraser) { model.tools.select(model.tools.lastInkTool) }
            close()
            onPenSettings()
        }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.15)) { model.toolWheel = nil }
    }
}

/// Quarter of a circle centered on the top-left corner of its frame.
private struct QuarterDisk: Shape {
    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height)
        var p = Path()
        p.move(to: rect.origin)
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY))
        p.addArc(center: rect.origin, radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.closeSubpath()
        return p
    }
}
#endif
