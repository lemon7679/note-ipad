#if canImport(UIKit)
import NoteKit
import SwiftUI

/// 44×44 icon button; `isOn` shows the selected tool state (accent on soft accent).
struct IconButton: View {
    let systemName: String
    let label: String
    var isOn = false
    var isEnabled = true
    var size: CGFloat = 20
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .regular))
                .frame(width: NoteTheme.minTouch, height: NoteTheme.minTouch)
                .foregroundStyle(isOn ? NoteTheme.accent : (isEnabled ? NoteTheme.iconMuted : NoteTheme.offline))
                .background(isOn ? NoteTheme.accentSoft : Color.clear,
                            in: RoundedRectangle(cornerRadius: NoteTheme.Radius.control))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(NoteTheme.Fonts.bodyEmphasized)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(minHeight: 40)
            .background(NoteTheme.accent.opacity(configuration.isPressed ? 0.8 : 1),
                        in: RoundedRectangle(cornerRadius: NoteTheme.Radius.control))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(NoteTheme.textPrimary)
            .padding(.horizontal, 16)
            .frame(minHeight: 40)
            .background(NoteTheme.surface.opacity(configuration.isPressed ? 0.7 : 1),
                        in: RoundedRectangle(cornerRadius: NoteTheme.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: NoteTheme.Radius.control).stroke(NoteTheme.controlBorder))
    }
}

/// Filter chip (전체 / 노트 / PDF / 폴더).
struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: selected ? .medium : .regular))
                .padding(.horizontal, 14)
                .frame(height: 34)
                .foregroundStyle(selected ? NoteTheme.chipSelectedText : NoteTheme.iconMuted)
                .background(selected ? NoteTheme.chipSelected : NoteTheme.surface, in: Capsule())
                .overlay(Capsule().stroke(selected ? Color.clear : NoteTheme.controlBorder))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

enum SyncBadgeState: Equatable {
    case synced, syncing, conflict, localOnly, cloudOnly, error

    var symbol: String {
        switch self {
        case .synced: return "checkmark.circle"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .conflict: return "exclamationmark.triangle"
        case .localOnly: return "icloud.slash"
        case .cloudOnly: return "icloud.and.arrow.down"
        case .error: return "exclamationmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .synced: return NoteTheme.synced
        case .syncing, .cloudOnly: return NoteTheme.accent
        case .conflict: return NoteTheme.conflict
        case .localOnly: return NoteTheme.offline
        case .error: return NoteTheme.danger
        }
    }

    var label: String {
        switch self {
        case .synced: return "동기화됨"
        case .syncing: return "동기화 중"
        case .conflict: return "충돌"
        case .localOnly: return "이 iPad에만 있음"
        case .cloudOnly: return "NAS에만 있음 · 열면 다운로드"
        case .error: return "동기화 오류"
        }
    }
}

struct SyncBadge: View {
    let state: SyncBadgeState
    var size: CGFloat = 16

    var body: some View {
        Image(systemName: state.symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(state.color)
            .accessibilityLabel(state.label)
    }
}

/// Pill used for statuses ("동기화됨", "충돌 1").
struct StatusPill: View {
    let text: String
    let foreground: Color
    let background: Color
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
            Text(text).font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(background, in: Capsule())
    }
}

struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(NoteTheme.Fonts.sectionLabel)
            .foregroundStyle(NoteTheme.textSecondary)
            .padding(.horizontal, 4)
    }
}

/// Grouped settings-style container (white card with hairline rows).
struct CardGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(NoteTheme.surface, in: RoundedRectangle(cornerRadius: NoteTheme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: NoteTheme.Radius.card).stroke(NoteTheme.separator))
    }
}

struct CardDivider: View {
    var body: some View {
        Rectangle().fill(NoteTheme.separator).frame(height: 1).padding(.leading, 16)
    }
}

extension View {
    /// Notebook cover shadow from the design (0 6 16 / 14%).
    func coverShadow() -> some View {
        shadow(color: Color.black.opacity(0.14), radius: 8, x: 0, y: 6)
    }
}

extension Date {
    /// "오늘", "어제", "11월 21일", "2025년 3월 2일".
    var libraryLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return "오늘" }
        if cal.isDateInYesterday(self) { return "어제" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = cal.isDate(self, equalTo: Date(), toGranularity: .year) ? "M월 d일" : "yyyy년 M월 d일"
        return f.string(from: self)
    }

    var relativeLabel: String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.unitsStyle = .short
        return f.localizedString(for: self, relativeTo: Date())
    }
}

extension Int64 {
    var byteLabel: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
#endif
