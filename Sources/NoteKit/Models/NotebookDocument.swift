import Foundation

/// What is drawn under a page's ink.
public enum PageBackground: Codable, Equatable, Hashable, Sendable {
    case paper
    /// A page of the notebook's PDF (`NotebookDocument.pdf`), zero-based.
    case pdf(pageIndex: Int)

    private enum CodingKeys: String, CodingKey { case kind, pageIndex }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "pdf": self = .pdf(pageIndex: try c.decode(Int.self, forKey: .pageIndex))
        default: self = .paper
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .paper:
            try c.encode("paper", forKey: .kind)
        case .pdf(let index):
            try c.encode("pdf", forKey: .kind)
            try c.encode(index, forKey: .pageIndex)
        }
    }

    public var pdfPageIndex: Int? {
        if case .pdf(let i) = self { return i }
        return nil
    }
}

public struct ElementFrame: Codable, Equatable, Hashable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// Non-ink content placed on a page (page units).
public struct PageElement: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, image }

    public var id: UUID
    public var kind: Kind
    public var frame: ElementFrame
    /// Text content (kind == .text).
    public var text: String?
    public var fontSize: Double?
    public var colorHex: String?
    /// File name inside the package's `assets/` (kind == .image).
    public var asset: String?

    public init(id: UUID = UUID(), kind: Kind, frame: ElementFrame, text: String? = nil, fontSize: Double? = nil,
                colorHex: String? = nil, asset: String? = nil) {
        self.id = id
        self.kind = kind
        self.frame = frame
        self.text = text
        self.fontSize = fontSize
        self.colorHex = colorHex
        self.asset = asset
    }
}

public struct NotebookPage: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var size: PageSize
    public var paper: PaperStyle
    public var background: PageBackground
    public var bookmarked: Bool
    public var elements: [PageElement]

    public init(id: UUID = UUID(), size: PageSize, paper: PaperStyle, background: PageBackground = .paper,
                bookmarked: Bool = false, elements: [PageElement] = []) {
        self.id = id
        self.size = size
        self.paper = paper
        self.background = background
        self.bookmarked = bookmarked
        self.elements = elements
    }

    /// Ink file of this page inside the package.
    public var inkFileName: String { id.uuidString + ".ink" }
}

public struct PDFSource: Codable, Equatable, Sendable {
    /// File inside `assets/`.
    public var file: String
    /// Name the PDF had when it was imported (shown in the UI, used for export).
    public var originalName: String
    /// Library path of the PDF this notebook annotates, when it was opened from a
    /// PDF that stays next to the notebook ("/강의자료/운영체제.pdf").
    public var linkedPath: String?

    public init(file: String, originalName: String, linkedPath: String? = nil) {
        self.file = file
        self.originalName = originalName
        self.linkedPath = linkedPath
    }
}

/// `document.json` inside a `.inknote` package.
public struct NotebookDocument: Codable, Equatable, Identifiable, Sendable {
    public static let currentFormat = 1

    public var format: Int
    public var id: UUID
    public var title: String
    public var created: Date
    public var modified: Date
    public var cover: CoverStyle
    public var defaultPaper: PaperStyle
    public var defaultSize: PageSize
    public var pages: [NotebookPage]
    public var pdf: PDFSource?
    public var lastPageIndex: Int

    public init(id: UUID = UUID(), title: String, cover: CoverStyle = CoverStyle(colorHex: CoverStyle.palette[0]),
                paper: PaperStyle = PaperStyle(), size: PageSize = PageSizePreset.a4.size, pageCount: Int = 1,
                now: Date = Date()) {
        self.format = Self.currentFormat
        self.id = id
        self.title = title
        self.created = now
        self.modified = now
        self.cover = cover
        self.defaultPaper = paper
        self.defaultSize = size
        self.pages = (0..<max(pageCount, 0)).map { _ in NotebookPage(size: size, paper: paper) }
        self.pdf = nil
        self.lastPageIndex = 0
    }

    public func pageIndex(of id: UUID) -> Int? { pages.firstIndex { $0.id == id } }

    /// A new page with the notebook's defaults (or copying `template`'s paper and size).
    public func makePage(like template: NotebookPage? = nil) -> NotebookPage {
        NotebookPage(size: template?.size ?? defaultSize, paper: template?.paper ?? defaultPaper)
    }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
