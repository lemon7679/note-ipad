import Foundation

/// Ruling printed on a page. Drawn by the app (vector) under the ink.
public enum PaperTemplate: String, Codable, CaseIterable, Identifiable, Sendable {
    case blank
    case ruled        // 줄 노트 (8 mm)
    case narrowRuled  // 좁은 줄 (6 mm)
    case grid         // 모눈 (5 mm)
    case dotted       // 점 (5 mm)
    case cornell      // 코넬
    case music        // 오선지

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .blank: return "빈 종이"
        case .ruled: return "줄 노트"
        case .narrowRuled: return "좁은 줄"
        case .grid: return "모눈"
        case .dotted: return "점"
        case .cornell: return "코넬"
        case .music: return "오선지"
        }
    }

    /// Default line pitch in points.
    public var defaultSpacing: Double {
        switch self {
        case .blank: return 0
        case .ruled, .cornell: return Units.mm(8)
        case .narrowRuled: return Units.mm(6)
        case .grid, .dotted: return Units.mm(5)
        case .music: return Units.mm(2)
        }
    }
}

public enum PaperColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case white
    case ivory
    case gray

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .white: return "흰색"
        case .ivory: return "미색"
        case .gray: return "연회색"
        }
    }

    public var hex: String {
        switch self {
        case .white: return "#FFFFFF"
        case .ivory: return "#FBF8F1"
        case .gray: return "#F3F4F6"
        }
    }
}

public struct PaperStyle: Codable, Equatable, Hashable, Sendable {
    public var template: PaperTemplate
    public var color: PaperColor
    /// Line pitch in points; 0 = template default.
    public var spacing: Double

    public init(template: PaperTemplate = .ruled, color: PaperColor = .white, spacing: Double = 0) {
        self.template = template
        self.color = color
        self.spacing = spacing
    }

    public var effectiveSpacing: Double { spacing > 0 ? spacing : template.defaultSpacing }
}

public enum Units {
    public static func mm(_ v: Double) -> Double { v * 72.0 / 25.4 }
}

/// Page size presets in points (portrait).
public enum PageSizePreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case a4, b5, a5, letter, screen

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .a4: return "A4"
        case .b5: return "B5"
        case .a5: return "A5"
        case .letter: return "Letter"
        case .screen: return "화면"
        }
    }

    public var size: PageSize {
        switch self {
        case .a4: return PageSize(width: 595.28, height: 841.89)
        case .b5: return PageSize(width: 498.9, height: 708.66)
        case .a5: return PageSize(width: 419.53, height: 595.28)
        case .letter: return PageSize(width: 612, height: 792)
        case .screen: return PageSize(width: 600, height: 800)  // iPad 3:4
        }
    }
}

public struct PageSize: Codable, Equatable, Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public var landscape: PageSize { PageSize(width: max(width, height), height: min(width, height)) }
    public var portrait: PageSize { PageSize(width: min(width, height), height: max(width, height)) }

    /// Allowed side length of a custom page, in millimeters.
    public static let customRangeMM: ClosedRange<Double> = 50...1200

    /// A custom page size from millimeters, each side clamped to `customRangeMM`.
    public static func millimeters(width: Double, height: Double) -> PageSize {
        func side(_ v: Double) -> Double {
            Units.mm(min(max(v.isFinite ? v : 0, customRangeMM.lowerBound), customRangeMM.upperBound))
        }
        return PageSize(width: side(width), height: side(height))
    }

    public var widthMM: Double { width * 25.4 / 72 }
    public var heightMM: Double { height * 25.4 / 72 }

    /// "210 × 297 mm".
    public var millimeterLabel: String {
        String(format: "%.0f × %.0f mm", widthMM.rounded(), heightMM.rounded())
    }
}

/// Notebook cover. `nil` color = no cover (first page is shown).
public struct CoverStyle: Codable, Equatable, Hashable, Sendable {
    public var colorHex: String?

    public init(colorHex: String?) { self.colorHex = colorHex }

    public static let palette: [String] = [
        "#2F5BD3", "#1F7A55", "#2B2F38", "#B45309", "#6D4BC3", "#C0362C", "#0E7490",
    ]
}
