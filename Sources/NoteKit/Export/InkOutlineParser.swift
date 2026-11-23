import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// One filled stroke outline from InkEngine's SVG export, ready to be drawn
/// into a vector PDF (page units).
public struct InkOutline: Equatable, Sendable {
    public struct Point: Equatable, Sendable {
        public var x: Double
        public var y: Double
    }

    public var points: [Point]
    /// "#rrggbb"
    public var colorHex: String
    /// > 0: also stroke the outline with round joins (flat-nib pens).
    public var strokeWidth: Double
    /// Path opacity multiplied by its layer's opacity.
    public var opacity: Double
    public var multiply: Bool
}

/// Reads the SVG produced by `ink_editor_export_svg`.
public enum InkOutlineParser {
    public static func parse(_ svg: String) -> [InkOutline] {
        guard let data = svg.data(using: .utf8) else { return [] }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.outlines
    }

    /// "M1,2 L3,4 5,6Z" → points.
    public static func parsePath(_ d: String) -> [InkOutline.Point] {
        var points: [InkOutline.Point] = []
        let cleaned = d.map { "MLZmlz".contains($0) ? " " : $0 }
        for token in String(cleaned).split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let parts = token.split(separator: ",")
            guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { continue }
            points.append(InkOutline.Point(x: x, y: y))
        }
        return points
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var outlines: [InkOutline] = []
        private var groupOpacity: [Double] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String] = [:]) {
            switch elementName {
            case "g":
                groupOpacity.append(Double(attributes["opacity"] ?? "") ?? 1)
            case "path":
                guard let d = attributes["d"], let fill = attributes["fill"] else { return }
                let pts = InkOutlineParser.parsePath(d)
                guard pts.count >= 2 else { return }
                let layer = groupOpacity.reduce(1, *)
                outlines.append(InkOutline(
                    points: pts,
                    colorHex: fill,
                    strokeWidth: Double(attributes["stroke-width"] ?? "") ?? 0,
                    opacity: (Double(attributes["opacity"] ?? "") ?? 1) * layer,
                    multiply: (attributes["style"] ?? "").contains("multiply")))
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            if elementName == "g", !groupOpacity.isEmpty { groupOpacity.removeLast() }
        }
    }
}

/// "#2F5BD3" ↔ components.
public struct RGBAColor: Equatable, Hashable, Codable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255)
        } else {
            self.init(r: Double((v >> 24) & 0xFF) / 255, g: Double((v >> 16) & 0xFF) / 255,
                      b: Double((v >> 8) & 0xFF) / 255, a: Double(v & 0xFF) / 255)
        }
    }

    public var hex: String {
        func c(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }
}
