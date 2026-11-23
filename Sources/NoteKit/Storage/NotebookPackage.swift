import Foundation

/// A notebook on disk: a `.inknote` directory, synced file by file so that only
/// changed pages travel to the NAS.
///
///     선형대수 필기.inknote/
///       document.json         NotebookDocument (pages, paper, PDF source)
///       pages/<uuid>.ink       InkEngine page data, one file per page
///       assets/source.pdf      imported PDF (when the notebook annotates one)
///       assets/<uuid>.png      inserted images
///       thumbnail.png          cover / first page, for library grids on every device
public struct NotebookPackage: Hashable, Sendable {
    public static let documentFile = "document.json"
    public static let pagesDirectory = "pages"
    public static let assetsDirectory = "assets"
    public static let thumbnailFile = "thumbnail.png"

    public enum PackageError: Error, LocalizedError {
        case notANotebook(URL)
        case unsupportedFormat(Int)

        public var errorDescription: String? {
            switch self {
            case .notANotebook(let url): return "\(url.lastPathComponent)은(는) 노트 파일이 아닙니다."
            case .unsupportedFormat(let v): return "이 노트는 더 새로운 버전(\(v))의 앱에서 만들어졌습니다."
            }
        }
    }

    public let url: URL

    public init(url: URL) { self.url = url }

    public var documentURL: URL { url.appendingPathComponent(Self.documentFile) }
    public var pagesURL: URL { url.appendingPathComponent(Self.pagesDirectory, isDirectory: true) }
    public var assetsURL: URL { url.appendingPathComponent(Self.assetsDirectory, isDirectory: true) }
    public var thumbnailURL: URL { url.appendingPathComponent(Self.thumbnailFile) }

    public static func isPackage(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == FileNaming.notebookExtension
    }

    // MARK: Creating

    /// Creates a package named after the document's title (made unique) inside `directory`.
    @discardableResult
    public static func create(in directory: URL, document: NotebookDocument,
                              fileManager: FileManager = .default) throws -> NotebookPackage {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = FileNaming.sanitize(document.title)
        let name = FileNaming.unique(base: base, ext: FileNaming.notebookExtension) {
            fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        let package = NotebookPackage(url: directory.appendingPathComponent(name, isDirectory: true))
        try fileManager.createDirectory(at: package.pagesURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: package.assetsURL, withIntermediateDirectories: true)
        try package.write(document)
        return package
    }

    /// Creates a notebook whose pages are the pages of `pdfURL` (sizes measured by the caller).
    @discardableResult
    public static func createAnnotating(pdfURL: URL, title: String, pageSizes: [PageSize], in directory: URL,
                                        linkedPath: String? = nil, cover: CoverStyle = CoverStyle(colorHex: nil),
                                        fileManager: FileManager = .default) throws -> NotebookPackage {
        var doc = NotebookDocument(title: title, cover: cover, paper: PaperStyle(template: .blank),
                                   size: pageSizes.first ?? PageSizePreset.a4.size, pageCount: 0)
        doc.pages = pageSizes.enumerated().map { index, size in
            NotebookPage(size: size, paper: PaperStyle(template: .blank), background: .pdf(pageIndex: index))
        }
        doc.pdf = PDFSource(file: "source.pdf", originalName: pdfURL.lastPathComponent, linkedPath: linkedPath)
        let package = try create(in: directory, document: doc, fileManager: fileManager)
        try fileManager.copyItem(at: pdfURL, to: package.assetsURL.appendingPathComponent("source.pdf"))
        return package
    }

    // MARK: Document

    public func readDocument() throws -> NotebookDocument {
        guard FileManager.default.fileExists(atPath: documentURL.path) else { throw PackageError.notANotebook(url) }
        let doc = try NotebookDocument.decoder.decode(NotebookDocument.self, from: Data(contentsOf: documentURL))
        if doc.format > NotebookDocument.currentFormat { throw PackageError.unsupportedFormat(doc.format) }
        return doc
    }

    public func write(_ document: NotebookDocument) throws {
        let data = try NotebookDocument.encoder.encode(document)
        try data.write(to: documentURL, options: .atomic)
    }

    // MARK: Pages

    public func inkURL(pageID: UUID) -> URL {
        pagesURL.appendingPathComponent(pageID.uuidString + ".ink")
    }

    public func readInk(pageID: UUID) -> Data? {
        try? Data(contentsOf: inkURL(pageID: pageID))
    }

    public func writeInk(_ data: Data, pageID: UUID) throws {
        try FileManager.default.createDirectory(at: pagesURL, withIntermediateDirectories: true)
        try data.write(to: inkURL(pageID: pageID), options: .atomic)
    }

    public func deleteInk(pageID: UUID) {
        try? FileManager.default.removeItem(at: inkURL(pageID: pageID))
    }

    /// Removes ink files of pages that are no longer in `document`.
    public func pruneInk(keeping document: NotebookDocument) {
        let keep = Set(document.pages.map(\.inkFileName))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: pagesURL.path)) ?? []
        for file in files where file.hasSuffix(".ink") && !keep.contains(file) {
            try? FileManager.default.removeItem(at: pagesURL.appendingPathComponent(file))
        }
    }

    // MARK: Assets

    public func assetURL(_ name: String) -> URL { assetsURL.appendingPathComponent(name) }

    public var pdfURL: URL? {
        guard let doc = try? readDocument(), let pdf = doc.pdf else { return nil }
        return assetURL(pdf.file)
    }

    /// Stores `data` as a new asset and returns its file name.
    public func addAsset(data: Data, fileExtension: String) throws -> String {
        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        let name = UUID().uuidString + "." + fileExtension
        try data.write(to: assetURL(name), options: .atomic)
        return name
    }

    public func writeThumbnail(_ png: Data) throws {
        try png.write(to: thumbnailURL, options: .atomic)
    }

    // MARK: Copies

    /// Copies the package into `directory` with a fresh notebook id (a separate notebook,
    /// e.g. "복제" or a sync conflict copy).
    @discardableResult
    public func duplicate(into directory: URL, title: String? = nil,
                          fileManager: FileManager = .default) throws -> NotebookPackage {
        var doc = try readDocument()
        doc.id = UUID()
        if let title { doc.title = title }
        doc.modified = Date()
        let base = FileNaming.sanitize(title ?? FileNaming.split(url.lastPathComponent).base)
        let name = FileNaming.unique(base: base, ext: FileNaming.notebookExtension) {
            fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        let target = NotebookPackage(url: directory.appendingPathComponent(name, isDirectory: true))
        try fileManager.copyItem(at: url, to: target.url)
        try target.write(doc)
        return target
    }
}
