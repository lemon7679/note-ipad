import Foundation

public enum LibraryItemKind: String, Codable, Sendable {
    case folder, notebook, pdf, image, other

    public static func classify(name: String, isDirectory: Bool) -> LibraryItemKind {
        let ext = RemotePath.pathExtension(name)
        if ext == FileNaming.notebookExtension { return .notebook }
        if isDirectory { return .folder }
        switch ext {
        case "pdf": return .pdf
        case "png", "jpg", "jpeg", "heic", "gif", "webp": return .image
        default: return .other
        }
    }
}

/// One entry of a library folder listing.
public struct LibraryEntry: Identifiable, Hashable, Sendable {
    public var id: String { path }
    /// Path inside the library source ("/강의/선형대수.inknote").
    public let path: String
    public let fileName: String
    public let kind: LibraryItemKind
    public let modified: Date?
    public let size: Int64
    /// Listed from the NAS but not downloaded yet (opened on demand).
    public let isPlaceholder: Bool

    public init(path: String, kind: LibraryItemKind, modified: Date?, size: Int64, isPlaceholder: Bool = false) {
        self.path = RemotePath.normalize(path)
        self.fileName = RemotePath.name(path)
        self.kind = kind
        self.modified = modified
        self.size = size
        self.isPlaceholder = isPlaceholder
    }

    /// Name without the `.inknote` extension (other files keep theirs).
    public var displayName: String {
        kind == .notebook ? FileNaming.split(fileName).base : fileName
    }

    public var isDocument: Bool { kind == .notebook || kind == .pdf }
}

public enum LibrarySort: String, CaseIterable, Identifiable, Codable, Sendable {
    case modified, name, kind

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .modified: return "수정일"
        case .name: return "이름"
        case .kind: return "종류"
        }
    }

    public func sort(_ items: [LibraryEntry]) -> [LibraryEntry] {
        items.sorted { a, b in
            switch self {
            case .modified:
                return (a.modified ?? .distantPast) > (b.modified ?? .distantPast)
            case .name:
                return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
            case .kind:
                if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
                return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
            }
        }
    }
}

/// Lightweight facts about a notebook for library cards.
public struct NotebookSummary: Equatable, Sendable {
    public var title: String
    public var pageCount: Int
    public var coverHex: String?
    public var isPDF: Bool
    public var modified: Date
    /// Paper and size of the first page (placeholder cover before a thumbnail exists).
    public var firstPaper: PaperStyle?
    public var firstPageSize: PageSize?
}

/// File operations on one library source rooted at a local directory: "이 iPad"
/// (Documents) or the local mirror of a NAS account.
public final class LibraryFileSystem: @unchecked Sendable {
    public enum LibraryError: Error, LocalizedError {
        case alreadyExists(String)
        case invalidName
        case notFound(String)
        case incompleteCopy(String)

        public var errorDescription: String? {
            switch self {
            case .alreadyExists(let n): return "‘\(n)’ 이름이 이미 있습니다."
            case .invalidName: return "사용할 수 없는 이름입니다."
            case .notFound(let p): return "\(RemotePath.name(p))을(를) 찾을 수 없습니다."
            case .incompleteCopy(let n): return "‘\(n)’을(를) 끝까지 복사하지 못했습니다."
            }
        }
    }

    public let root: URL
    private let fm = FileManager.default

    public init(root: URL) {
        self.root = root
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func url(for path: String) -> URL { root.appendingRemotePath(path) }

    public func exists(_ path: String) -> Bool { fm.fileExists(atPath: url(for: path).path) }

    // MARK: Listing

    public func list(_ folder: String) throws -> [LibraryEntry] {
        let dir = url(for: folder)
        let names = try fm.contentsOfDirectory(atPath: dir.path)
        var items: [LibraryEntry] = []
        for name in names where !FileNaming.isIgnored(name) {
            let itemURL = dir.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: itemURL.path) else { continue }
            let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
            let kind = LibraryItemKind.classify(name: name, isDirectory: isDir)
            var modified = attrs[.modificationDate] as? Date
            if kind == .notebook {
                // A package's own mtime does not change when a page inside it does.
                let docAttrs = try? fm.attributesOfItem(atPath: itemURL.appendingPathComponent(NotebookPackage.documentFile).path)
                modified = (docAttrs?[.modificationDate] as? Date) ?? modified
            }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            items.append(LibraryEntry(path: RemotePath.join(folder, name), kind: kind, modified: modified, size: size))
        }
        return items
    }

    /// Every folder (not notebook packages) below `folder`, depth-first, for move pickers.
    public func allFolders(under folder: String = "/") -> [String] {
        var out: [String] = []
        for item in (try? list(folder)) ?? [] where item.kind == .folder {
            out.append(item.path)
            out.append(contentsOf: allFolders(under: item.path))
        }
        return out
    }

    /// Case-insensitive name search through the whole source.
    public func search(_ query: String, in folder: String = "/") -> [LibraryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var out: [LibraryEntry] = []
        for item in (try? list(folder)) ?? [] {
            if item.displayName.localizedCaseInsensitiveContains(q) { out.append(item) }
            if item.kind == .folder { out.append(contentsOf: search(q, in: item.path)) }
        }
        return out
    }

    public func summary(ofNotebook path: String) -> NotebookSummary? {
        let package = NotebookPackage(url: url(for: path))
        guard let doc = try? package.readDocument() else { return nil }
        return NotebookSummary(title: doc.title, pageCount: doc.pages.count, coverHex: doc.cover.colorHex,
                               isPDF: doc.pdf != nil, modified: doc.modified,
                               firstPaper: doc.pages.first?.paper, firstPageSize: doc.pages.first?.size)
    }

    // MARK: Changes

    @discardableResult
    public func createFolder(named name: String, in folder: String) throws -> String {
        let clean = FileNaming.sanitize(name, fallback: "새 폴더")
        let unique = FileNaming.unique(base: clean, ext: "") { exists(RemotePath.join(folder, $0)) }
        let path = RemotePath.join(folder, unique)
        try fm.createDirectory(at: url(for: path), withIntermediateDirectories: true)
        return path
    }

    /// Renames an item; for notebooks the title inside the package follows.
    @discardableResult
    public func rename(_ path: String, to newName: String) throws -> String {
        guard exists(path) else { throw LibraryError.notFound(path) }
        let isNotebook = RemotePath.pathExtension(path) == FileNaming.notebookExtension
        let ext = isNotebook ? FileNaming.notebookExtension : RemotePath.pathExtension(path)
        var base = FileNaming.sanitize(newName, fallback: "")
        guard !base.isEmpty else { throw LibraryError.invalidName }
        if !isNotebook, !ext.isEmpty, base.lowercased().hasSuffix("." + ext) {
            base = String(base.dropLast(ext.count + 1))
        }
        let fileName = ext.isEmpty ? base : base + "." + ext
        let target = RemotePath.join(RemotePath.parent(path), fileName)
        if target == path { return path }
        if exists(target), target.lowercased() != path.lowercased() { throw LibraryError.alreadyExists(fileName) }
        try fm.moveItem(at: url(for: path), to: url(for: target))
        if isNotebook {
            let package = NotebookPackage(url: url(for: target))
            if var doc = try? package.readDocument() {
                doc.title = base
                doc.modified = Date()
                try package.write(doc)
            }
        }
        return target
    }

    @discardableResult
    public func move(_ path: String, toFolder folder: String) throws -> String {
        guard exists(path) else { throw LibraryError.notFound(path) }
        if RemotePath.parent(path) == RemotePath.normalize(folder) { return path }
        guard !RemotePath.isAncestor(path, of: folder) else { throw LibraryError.invalidName }
        let fileName = RemotePath.name(path)
        let attrs = try? fm.attributesOfItem(atPath: url(for: path).path)
        let isFolder = (attrs?[.type] as? FileAttributeType) == .typeDirectory
            && RemotePath.pathExtension(path) != FileNaming.notebookExtension
        let (base, ext) = isFolder ? (fileName, "") : FileNaming.split(fileName)
        let name = FileNaming.unique(base: base, ext: ext) { exists(RemotePath.join(folder, $0)) }
        let target = RemotePath.join(folder, name)
        try fm.createDirectory(at: url(for: folder), withIntermediateDirectories: true)
        try fm.moveItem(at: url(for: path), to: url(for: target))
        return target
    }

    @discardableResult
    public func duplicate(_ path: String) throws -> String {
        guard exists(path) else { throw LibraryError.notFound(path) }
        let folder = RemotePath.parent(path)
        if RemotePath.pathExtension(path) == FileNaming.notebookExtension {
            let source = NotebookPackage(url: url(for: path))
            let title = FileNaming.split(RemotePath.name(path)).base + " 사본"
            let copy = try source.duplicate(into: url(for: folder), title: title)
            return RemotePath.join(folder, copy.url.lastPathComponent)
        }
        let (base, ext) = FileNaming.split(RemotePath.name(path))
        let name = FileNaming.unique(base: base + " 사본", ext: ext) { exists(RemotePath.join(folder, $0)) }
        let target = RemotePath.join(folder, name)
        try fm.copyItem(at: url(for: path), to: url(for: target))
        return target
    }

    /// Deletes an item; when `trash` is given it is moved there instead (restorable).
    public func delete(_ path: String, trash: TrashBin? = nil) throws {
        guard exists(path) else { return }
        if let trash {
            try trash.store(url(for: path), originalPath: path)
        } else {
            try fm.removeItem(at: url(for: path))
        }
    }

    /// Copies an outside file (Files app import, AirDrop…) into `folder`.
    @discardableResult
    public func importFile(from source: URL, into folder: String, preferredName: String? = nil) throws -> String {
        let fileName = preferredName ?? source.lastPathComponent
        let (base, ext) = FileNaming.split(FileNaming.sanitize(fileName))
        let name = FileNaming.unique(base: base, ext: ext) { exists(RemotePath.join(folder, $0)) }
        let target = RemotePath.join(folder, name)
        try fm.createDirectory(at: url(for: folder), withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: url(for: target))
        return target
    }
}

/// Deleted items, kept until emptied. One bin per library source.
public final class TrashBin: @unchecked Sendable {
    public struct Entry: Codable, Identifiable, Hashable, Sendable {
        public var id: String { storedName }
        public var storedName: String
        public var originalPath: String
        public var deletedAt: Date

        public var displayName: String {
            let name = RemotePath.name(originalPath)
            return RemotePath.pathExtension(name) == FileNaming.notebookExtension ? FileNaming.split(name).base : name
        }
    }

    public let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private let fm = FileManager.default

    public init(directory: URL) {
        self.directory = directory
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func entries() -> [Entry] {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? NotebookDocument.decoder.decode([Entry].self, from: data) else { return [] }
        return list.sorted { $0.deletedAt > $1.deletedAt }
    }

    private func save(_ list: [Entry]) throws {
        try NotebookDocument.encoder.encode(list).write(to: indexURL, options: .atomic)
    }

    public func url(of entry: Entry) -> URL { directory.appendingPathComponent(entry.storedName) }

    public func store(_ item: URL, originalPath: String) throws {
        let stored = UUID().uuidString + "-" + item.lastPathComponent
        try fm.moveItem(at: item, to: directory.appendingPathComponent(stored))
        var list = entries()
        list.append(Entry(storedName: stored, originalPath: originalPath, deletedAt: Date()))
        try save(list)
    }

    /// Moves the entry back into `library` (to its folder, or the root if that is gone).
    @discardableResult
    public func restore(_ entry: Entry, into library: LibraryFileSystem) throws -> String {
        var folder = RemotePath.parent(entry.originalPath)
        if !library.exists(folder) { folder = "/" }
        let (base, ext) = FileNaming.split(RemotePath.name(entry.originalPath))
        let name = FileNaming.unique(base: base, ext: ext) { library.exists(RemotePath.join(folder, $0)) }
        let target = RemotePath.join(folder, name)
        try fm.moveItem(at: url(of: entry), to: library.url(for: target))
        try save(entries().filter { $0.storedName != entry.storedName })
        return target
    }

    public func remove(_ entry: Entry) throws {
        try? fm.removeItem(at: url(of: entry))
        try save(entries().filter { $0.storedName != entry.storedName })
    }

    public func empty() throws {
        for entry in entries() { try? fm.removeItem(at: url(of: entry)) }
        try save([])
    }
}
