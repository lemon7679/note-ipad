#if canImport(UIKit)
import SwiftUI
import UIKit

// "Quiet Ink" design tokens, translated 1:1 from the Claude Design canvas
// (Tokens artboard). Light values are the design's; dark values keep each
// role's contrast.

extension UIColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0
        if s.count == 8 {
            self.init(red: CGFloat((v >> 24) & 0xFF) / 255, green: CGFloat((v >> 16) & 0xFF) / 255,
                      blue: CGFloat((v >> 8) & 0xFF) / 255, alpha: CGFloat(v & 0xFF) / 255)
        } else {
            self.init(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                      blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
    }

    static func dynamic(_ light: String, _ dark: String) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) }
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        func c(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }
}

extension Color {
    init(hex: String) { self.init(uiColor: UIColor(hex: hex)) }
}

enum NoteTheme {
    // MARK: Colors (role → light / dark)
    static let backgroundUI = UIColor.dynamic("#F6F7F9", "#111317")
    static let sidebarUI = UIColor.dynamic("#EEF0F3", "#171A1F")
    static let deskUI = UIColor.dynamic("#E9EBEF", "#0B0C0F")
    static let surfaceUI = UIColor.dynamic("#FFFFFF", "#1E2128")
    static let separatorUI = UIColor.dynamic("#E2E5EA", "#2C3038")
    static let accentUI = UIColor.dynamic("#2F5BD3", "#7A9CFF")

    static let background = Color(uiColor: backgroundUI)
    static let sidebar = Color(uiColor: sidebarUI)
    static let desk = Color(uiColor: deskUI)
    static let surface = Color(uiColor: surfaceUI)
    static let separator = Color(uiColor: separatorUI)
    static let controlBorder = Color(uiColor: .dynamic("#D5D9E0", "#3A3F4A"))
    static let fieldFill = Color(uiColor: .dynamic("#E8EBF0", "#262A32"))
    static let textPrimary = Color(uiColor: .dynamic("#15171C", "#F2F3F5"))
    static let textSecondary = Color(uiColor: .dynamic("#5B616E", "#A3A9B5"))
    static let textTertiary = Color(uiColor: .dynamic("#6B7280", "#8A909C"))
    static let iconMuted = Color(uiColor: .dynamic("#3A3F4A", "#C9CDD5"))
    static let accent = Color(uiColor: accentUI)
    static let accentSoft = Color(uiColor: .dynamic("#E8EEFC", "#1F2A47"))
    static let synced = Color(uiColor: .dynamic("#1F7A55", "#4CC08C"))
    static let syncedSoft = Color(uiColor: .dynamic("#E6F3EE", "#173A2C"))
    static let conflict = Color(uiColor: .dynamic("#B45309", "#F0A453"))
    static let conflictSoft = Color(uiColor: .dynamic("#FDF1E3", "#3A2A16"))
    static let danger = Color(uiColor: .dynamic("#C0362C", "#FF7A6E"))
    static let dangerSoft = Color(uiColor: .dynamic("#FBEAE8", "#3D1C19"))
    static let offline = Color(uiColor: .dynamic("#9AA0AC", "#6B7280"))
    static let chipSelected = Color(uiColor: .dynamic("#15171C", "#F2F3F5"))
    static let chipSelectedText = Color(uiColor: .dynamic("#FFFFFF", "#15171C"))

    // Paper (always light: ink colors are designed for light paper).
    static let paperRule = UIColor(hex: "#DCE3F0")
    static let paperRuleStrong = UIColor(hex: "#C9CED6")
    static let paperDot = UIColor(hex: "#B8C1D1")
    static let paperMargin = UIColor(hex: "#F2C9C9")

    static let penColors = ["#1C1C1E", "#1F4FD1", "#D12F2F", "#12805C", "#7A3FC4", "#E07A1F"]
    static let highlighterColors = ["#FFE45C", "#8EF0A8", "#7FD3FF", "#FF9ECF"]

    // MARK: Shape & space
    enum Radius {
        static let control: CGFloat = 10
        static let card: CGFloat = 14
        static let popover: CGFloat = 18
        static let sheet: CGFloat = 20
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let page: CGFloat = 28
    }

    static let minTouch: CGFloat = 44

    // MARK: Type (SF Pro / Apple SD Gothic Neo via the system font)
    enum Fonts {
        static let largeTitle = Font.system(size: 28, weight: .bold)
        static let folderTitle = Font.system(size: 22, weight: .semibold)
        static let sheetTitle = Font.system(size: 17, weight: .semibold)
        static let body = Font.system(size: 15)
        static let bodyEmphasized = Font.system(size: 15, weight: .semibold)
        static let cardTitle = Font.system(size: 14, weight: .semibold)
        static let sectionLabel = Font.system(size: 13, weight: .semibold)
        static let caption = Font.system(size: 12)
    }
}
#endif
