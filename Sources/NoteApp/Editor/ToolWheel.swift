#if canImport(UIKit)
import NoteKit
import SwiftUI

/// Radial tool menu opened by the Apple Pencil button (double tap / squeeze) at the pencil tip.
///
/// Outer ring: tools, undo/redo and pen settings. Inner ring: colors of the current pen
/// (or highlighter). Center: the width presets, tapped to cycle. Tapping outside closes it.
struct ToolWheel: View {
    @ObservedObject var model: EditorModel
    /// Requested center in this view's coordinates (clamped so the wheel stays on screen).
    let anchor: CGPoint
    var onPenSettings: () -> Void

    /// Name of the option the pencil is hovering over, shown above the wheel.
    @State private var hoverLabel: String?

    static let outerRadius: CGFloat = 100
    static let innerRadius: CGFloat = 54
    static let itemSize: CGFloat = 48
    static var diameter: CGFloat { (outerRadius + itemSize / 2 + 8) * 2 }

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

    private var palette: [String] {
        let base = inkTarget == .highlighter ? NoteTheme.highlighterColors : NoteTheme.penColors
        return Array((base + model.tools.customColors.prefix(2)).prefix(6))
    }

    private var activeColor: String { inkTarget == .highlighter ? model.tools.highlighterColor : model.tools.penColor }

    var body: some View {
        GeometryReader { geo in
            let r = Self.diameter / 2
            let center = CGPoint(
                x: min(max(anchor.x, r + 8), max(r + 8, geo.size.width - r - 8)),
                y: min(max(anchor.y, r + 8), max(r + 8, geo.size.height - r - 8)))
            ZStack {
                // Tap anywhere outside the wheel to close it (and swallow the touch so it doesn't draw).
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { close() }
                wheel
                    .position(center)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                if let hoverLabel {
                    let above = center.y - r - 8 - 15
                    Text(hoverLabel)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Color.black.opacity(0.75), in: Capsule())
                        .allowsHitTesting(false)
                        .position(x: center.x, y: above >= 15 ? above : center.y + r + 8 + 15)
                }
            }
        }
    }

    private var wheel: some View {
        ZStack {
            Circle()
                .fill(.regularMaterial)
                .overlay(Circle().stroke(NoteTheme.separator))
                .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
            Circle()
                .fill(NoteTheme.surface.opacity(0.7))
                .frame(width: (Self.innerRadius + 22) * 2, height: (Self.innerRadius + 22) * 2)
            ForEach(Array(Self.items.enumerated()), id: \.element) { index, item in
                itemButton(item)
                    .offset(offset(index: index, count: Self.items.count, radius: Self.outerRadius))
            }
            ForEach(Array(palette.enumerated()), id: \.element) { index, hex in
                colorButton(hex)
                    .offset(offset(index: index, count: palette.count, radius: Self.innerRadius))
            }
            widthButton
        }
        .frame(width: Self.diameter, height: Self.diameter)
    }

    /// Hover callback that shows `label` while hovering and clears it on exit.
    private func hovering(_ label: String) -> (Bool) -> Void {
        { on in
            if on { hoverLabel = label } else if hoverLabel == label { hoverLabel = nil }
        }
    }

    private func offset(index: Int, count: Int, radius: CGFloat) -> CGSize {
        let angle = -Double.pi / 2 + Double(index) / Double(max(count, 1)) * 2 * .pi
        return CGSize(width: cos(angle) * radius, height: sin(angle) * radius)
    }

    private func isOn(_ item: Item) -> Bool {
        if case .tool(let t) = item { return model.tools.tool == t }
        return false
    }

    private func isEnabled(_ item: Item) -> Bool {
        switch item {
        case .undo: return model.canUndo
        case .redo: return model.canRedo
        default: return true
        }
    }

    private func itemButton(_ item: Item) -> some View {
        let on = isOn(item)
        return Button {
            perform(item)
        } label: {
            Image(systemName: item.symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(on ? Color.white : NoteTheme.textPrimary)
                .frame(width: Self.itemSize, height: Self.itemSize)
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
        return Button {
            if model.tools.tool != inkTarget { model.tools.select(inkTarget) }
            model.tools.setColor(hex)
            close()
        } label: {
            Circle().fill(Color(hex: hex))
                .overlay(Circle().stroke(NoteTheme.controlBorder.opacity(hex == "#FFFFFF" ? 1 : 0)))
                .padding(3)
                .frame(width: 32, height: 32)
                .overlay(Circle().stroke(selected ? NoteTheme.accent : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .hoverHighlight(scale: 1.18, onHover: hovering(inkTarget == .highlighter ? "형광펜 색" : "펜 색"))
        .accessibilityLabel("색 \(hex)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Center: current width preset; each tap moves to the next one.
    private var widthButton: some View {
        let highlighter = inkTarget == .highlighter
        let widths = highlighter ? model.tools.highlighterWidths : model.tools.currentPenWidths
        let index = highlighter ? model.tools.highlighterWidthIndex : model.tools.penWidthIndex
        let width = widths[min(max(index, 0), widths.count - 1)]
        let maxWidth = widths.max() ?? 1
        return Button {
            if model.tools.tool != inkTarget { model.tools.select(inkTarget) }
            let next = (index + 1) % max(widths.count, 1)
            if highlighter { model.tools.highlighterWidthIndex = next } else { model.tools.penWidthIndex = next }
        } label: {
            VStack(spacing: 3) {
                Capsule()
                    .fill(Color(hex: activeColor))
                    .frame(width: 22, height: max(2, width / maxWidth * 9))
                Text(highlighter ? String(format: "%.0fpt", width) : String(format: "%.1fmm", width / 72 * 25.4))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(NoteTheme.textSecondary)
            }
            .frame(width: 52, height: 52)
            .background(Circle().fill(NoteTheme.surface))
            .overlay(Circle().stroke(NoteTheme.controlBorder))
        }
        .buttonStyle(.plain)
        .hoverHighlight(scale: 1.1, onHover: hovering("굵기 바꾸기"))
        .accessibilityLabel("굵기 \(index + 1) / \(widths.count)")
        .accessibilityHint("탭하면 다음 굵기로 바뀝니다")
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
#endif
