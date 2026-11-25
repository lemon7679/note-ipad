#if canImport(UIKit)
import InkBridge
import NoteKit
import PDFKit
import SwiftUI
import UIKit

/// What the canvas must react to when the model changes underneath it.
@MainActor
protocol CanvasControlling: AnyObject {
    func pagesDidChange()
    func inkDidChange(pageID: UUID, rect: CGRect)
    func elementsDidChange(pageID: UUID)
    func scrollToPage(_ index: Int, animated: Bool)
    func highlight(pageIndex: Int, rect: CGRect)
    func clearSelection()
}

struct OutlineEntry: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let pageIndex: Int
    let depth: Int
}

struct SearchHit: Identifiable, Hashable {
    let id = UUID()
    let pageIndex: Int
    /// Page units (top-left origin); `.null` when unknown.
    let rect: CGRect
    let context: String
}

/// One open notebook: document, lazily loaded ink pages, undo across pages, autosave.
@MainActor
final class EditorModel: ObservableObject {
    private enum UndoEntry {
        case ink(UUID)
        case document(before: NotebookDocument, after: NotebookDocument)
    }

    let ref: LibraryRef
    let package: NotebookPackage
    @Published private(set) var document: NotebookDocument
    @Published var tools: ToolState { didSet { tools.save() } }
    @Published var currentPageIndex = 0
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published var showsSidebar = true
    /// Pencil-button tool palette is open around this point (canvas coordinates: where the pencil was).
    @Published var toolWheel: CGPoint?
    @Published private(set) var thumbnailRevision = 0
    @Published var searchResults: [SearchHit] = []
    /// Pages picked in the page list to make a new notebook from (nil: not picking).
    @Published var pageSelection: Set<UUID>?
    @Published var lastError: String?

    let pdf: CGPDFDocument?
    private(set) lazy var pdfKitDocument: PDFDocument? = document.pdf.flatMap { PDFDocument(url: package.assetURL($0.file)) }
    weak var canvas: CanvasControlling?
    unowned let app: AppModel

    private var pages: [UUID: InkPage] = [:]
    private var dirtyInk: Set<UUID> = []
    private var documentDirty = false
    private var undoStack: [UndoEntry] = []
    private var redoStack: [UndoEntry] = []
    private var autosave: Task<Void, Never>?
    private var thumbnails: [UUID: UIImage] = [:]

    init(ref: LibraryRef, url: URL, app: AppModel) throws {
        self.ref = ref
        self.app = app
        package = NotebookPackage(url: url)
        var doc = try package.readDocument()
        if doc.pages.isEmpty { doc.pages.append(doc.makePage()) }
        document = doc
        pdf = doc.pdf.flatMap { PDFSupport.document(at: NotebookPackage(url: url).assetURL($0.file)) }
        tools = ToolState.load()
        currentPageIndex = min(max(doc.lastPageIndex, 0), doc.pages.count - 1)
    }

    var title: String { document.title }
    var pageCount: Int { document.pages.count }
    var currentPage: NotebookPage { document.pages[min(currentPageIndex, document.pages.count - 1)] }

    func pdfPage(for page: NotebookPage) -> CGPDFPage? {
        page.background.pdfPageIndex.flatMap { pdf?.page(at: $0 + 1) }
    }

    // MARK: Ink pages

    func inkPage(_ id: UUID) -> InkPage {
        if let page = pages[id] { return page }
        let info = document.pages.first { $0.id == id }
        let ink = InkPage(width: Float(info?.size.width ?? 595), height: Float(info?.size.height ?? 842))
        if let data = package.readInk(pageID: id) { ink.load(data) }
        pages[id] = ink
        return ink
    }

    /// Call after every ink edit on a page (stroke, erase, lasso operation).
    func noteInkEdit(_ id: UUID) {
        undoStack.append(.ink(id))
        if undoStack.count > 500 { undoStack.removeFirst() }
        redoStack.removeAll()
        dirtyInk.insert(id)
        thumbnails[id] = nil
        updateUndoFlags()
        scheduleSave()
    }

    private func updateUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    func undo() {
        guard let entry = undoStack.popLast() else { return }
        canvas?.clearSelection()
        switch entry {
        case .ink(let id):
            let ink = inkPage(id)
            if ink.undo() {
                dirtyInk.insert(id)
                thumbnails[id] = nil
                canvas?.inkDidChange(pageID: id, rect: ink.takeDirty())
            }
            redoStack.append(entry)
        case .document(let before, let after):
            applyDocument(before)
            redoStack.append(.document(before: before, after: after))
        }
        updateUndoFlags()
        scheduleSave()
    }

    func redo() {
        guard let entry = redoStack.popLast() else { return }
        canvas?.clearSelection()
        switch entry {
        case .ink(let id):
            let ink = inkPage(id)
            if ink.redo() {
                dirtyInk.insert(id)
                thumbnails[id] = nil
                canvas?.inkDidChange(pageID: id, rect: ink.takeDirty())
            }
            undoStack.append(entry)
        case .document(let before, let after):
            applyDocument(after)
            undoStack.append(.document(before: before, after: after))
        }
        updateUndoFlags()
        scheduleSave()
    }

    // MARK: Document changes (pages, paper, elements) — undoable

    private func changeDocument(_ change: (inout NotebookDocument) -> Void) {
        let before = document
        var after = document
        change(&after)
        guard after != before else { return }
        undoStack.append(.document(before: before, after: after))
        redoStack.removeAll()
        applyDocument(after)
        updateUndoFlags()
        scheduleSave()
    }

    private func applyDocument(_ doc: NotebookDocument) {
        let structureChanged = doc.pages.map(\.id) != document.pages.map(\.id)
            || zip(doc.pages, document.pages).contains { $0.size != $1.size || $0.paper != $1.paper || $0.background != $1.background }
        let elementPages = Set(zip(doc.pages, document.pages).filter { $0.elements != $1.elements }.map(\.0.id))
        // Pages coming back (undo of a delete) must be written again: saving pruned their ink files.
        let previous = Set(document.pages.map(\.id))
        for page in doc.pages where !previous.contains(page.id) && pages[page.id] != nil {
            dirtyInk.insert(page.id)
        }
        document = doc
        documentDirty = true
        currentPageIndex = min(currentPageIndex, doc.pages.count - 1)
        if structureChanged {
            thumbnails.removeAll()
            canvas?.pagesDidChange()
        } else {
            for id in elementPages {
                thumbnails[id] = nil
                canvas?.elementsDidChange(pageID: id)
            }
        }
        thumbnailRevision += 1
    }

    func addPage(after index: Int, like template: NotebookPage? = nil) {
        let source = template ?? (document.pages.indices.contains(index) ? document.pages[index] : nil)
        var page = document.makePage(like: source)
        if source?.background.pdfPageIndex != nil {
            page.paper = document.defaultPaper.template == .blank ? PaperStyle(template: .blank) : document.defaultPaper
        }
        let insertAt = min(max(index + 1, 0), document.pages.count)
        changeDocument { $0.pages.insert(page, at: insertAt) }
        currentPageIndex = insertAt
        canvas?.scrollToPage(insertAt, animated: true)
    }

    func insertPage(before index: Int) { addPage(after: index - 1, like: document.pages[safe: index]) }

    func duplicatePage(at index: Int) {
        guard let original = document.pages[safe: index] else { return }
        var copy = original
        copy.id = UUID()
        copy.elements = original.elements.map { var e = $0; e.id = UUID(); return e }
        if let data = inkPage(original.id).save() {
            let ink = InkPage(width: Float(copy.size.width), height: Float(copy.size.height))
            ink.load(data)
            pages[copy.id] = ink
            dirtyInk.insert(copy.id)
        }
        changeDocument { $0.pages.insert(copy, at: index + 1) }
    }

    func deletePage(at index: Int) {
        guard document.pages.count > 1, document.pages.indices.contains(index) else { return }
        _ = inkPage(document.pages[index].id)   // keep the ink in memory so undo can restore it
        changeDocument { $0.pages.remove(at: index) }
    }

    func movePage(from source: IndexSet, to destination: Int) {
        changeDocument { $0.pages.move(fromOffsets: source, toOffset: destination) }
    }

    func toggleBookmark(at index: Int) {
        guard document.pages.indices.contains(index) else { return }
        changeDocument { $0.pages[index].bookmarked.toggle() }
    }

    func setPaper(_ paper: PaperStyle, forAll: Bool) {
        changeDocument { doc in
            if forAll {
                for i in doc.pages.indices where doc.pages[i].background == .paper { doc.pages[i].paper = paper }
                doc.defaultPaper = paper
            } else if doc.pages.indices.contains(currentPageIndex) {
                doc.pages[currentPageIndex].paper = paper
            }
        }
    }

    func rename(_ title: String) {
        let clean = title.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        changeDocument { $0.title = clean }
    }

    func setCover(_ hex: String?) {
        changeDocument { $0.cover = CoverStyle(colorHex: hex) }
    }

    // Elements

    func addElement(_ element: PageElement, toPage id: UUID) {
        changeDocument { doc in
            guard let i = doc.pageIndex(of: id) else { return }
            doc.pages[i].elements.append(element)
        }
    }

    func updateElement(_ element: PageElement, onPage id: UUID) {
        changeDocument { doc in
            guard let i = doc.pageIndex(of: id), let j = doc.pages[i].elements.firstIndex(where: { $0.id == element.id }) else { return }
            doc.pages[i].elements[j] = element
        }
    }

    func removeElement(_ elementID: UUID, fromPage id: UUID) {
        changeDocument { doc in
            guard let i = doc.pageIndex(of: id) else { return }
            doc.pages[i].elements.removeAll { $0.id == elementID }
        }
    }

    func addImage(_ image: UIImage, toPage id: UUID, center: CGPoint) {
        guard let data = image.jpegData(compressionQuality: 0.85),
              let page = document.pages.first(where: { $0.id == id }) else { return }
        do {
            let name = try package.addAsset(data: data, fileExtension: "jpg")
            let maxW = page.size.width * 0.6, maxH = page.size.height * 0.5
            let scale = min(maxW / Double(image.size.width), maxH / Double(image.size.height), 1)
            let w = Double(image.size.width) * scale, h = Double(image.size.height) * scale
            let frame = ElementFrame(x: min(max(Double(center.x) - w / 2, 0), page.size.width - w),
                                     y: min(max(Double(center.y) - h / 2, 0), page.size.height - h), width: w, height: h)
            addElement(PageElement(kind: .image, frame: frame, asset: name), toPage: id)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Navigation, search, outline

    func go(to index: Int) {
        guard document.pages.indices.contains(index) else { return }
        currentPageIndex = index
        canvas?.scrollToPage(index, animated: true)
    }

    var bookmarkedIndices: [Int] { document.pages.indices.filter { document.pages[$0].bookmarked } }

    /// Table of contents of the underlying PDF, mapped to notebook pages.
    func outline() -> [OutlineEntry] {
        guard let pdfDoc = pdfKitDocument, let root = pdfDoc.outlineRoot else { return [] }
        var out: [OutlineEntry] = []
        func walk(_ node: PDFOutline, depth: Int) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                if let page = child.destination?.page {
                    let pdfIndex = pdfDoc.index(for: page)
                    if let notebookIndex = document.pages.firstIndex(where: { $0.background.pdfPageIndex == pdfIndex }) {
                        out.append(OutlineEntry(title: child.label ?? "", pageIndex: notebookIndex, depth: depth))
                    }
                }
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return out
    }

    func search(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let pdfDoc = pdfKitDocument else {
            searchResults = []
            return
        }
        var hits: [SearchHit] = []
        for selection in pdfDoc.findString(query, withOptions: [.caseInsensitive]) {
            guard let page = selection.pages.first else { continue }
            let pdfIndex = pdfDoc.index(for: page)
            guard let notebookIndex = document.pages.firstIndex(where: { $0.background.pdfPageIndex == pdfIndex }) else { continue }
            var rect = CGRect.null
            if page.rotation == 0 {
                let crop = page.bounds(for: .cropBox)
                let b = selection.bounds(for: page)
                rect = CGRect(x: b.minX - crop.minX, y: crop.maxY - b.maxY, width: b.width, height: b.height)
            }
            let context = selection.copy() as? PDFSelection
            context?.extendForLineBoundaries()
            hits.append(SearchHit(pageIndex: notebookIndex, rect: rect, context: context?.string ?? query))
        }
        searchResults = hits
    }

    func show(_ hit: SearchHit) {
        go(to: hit.pageIndex)
        if !hit.rect.isNull { canvas?.highlight(pageIndex: hit.pageIndex, rect: hit.rect) }
    }

    // MARK: Thumbnails

    func thumbnail(for page: NotebookPage, width: Int = 180) -> UIImage? {
        if let cached = thumbnails[page.id] { return cached }
        guard let cg = PageImageRenderer.image(page: page, ink: inkPage(page.id), pdf: pdf, package: package,
                                               pixelWidth: width) else { return nil }
        let image = UIImage(cgImage: cg)
        thumbnails[page.id] = image
        return image
    }

    func thumbnailsChanged() { thumbnailRevision += 1 }

    // MARK: Saving
    //
    // What to write is captured on the main thread — ink snapshots (pointer copies, no
    // serialization) and the document value — and written on one serial writer queue:
    // serializing big pages, file I/O and the cover thumbnail never stall drawing. The
    // writer runs saves strictly in capture order, and a synchronous save (close, export,
    // background) waits for the ones queued before it, so an older autosave can never land
    // after newer data.

    private let writer = DispatchQueue(label: "note.save", qos: .utility)

    private struct SaveWork: @unchecked Sendable {
        var ink: [(UUID, InkSnapshot)]
        var document: NotebookDocument
        var cover: (NotebookPage, InkSnapshot)?
        var package: NotebookPackage
        var pdf: CGPDFDocument?
    }

    private func scheduleSave() {
        autosave?.cancel()
        autosave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self, let work = self.captureSave() else { return }
            self.writer.async {
                let error = Self.write(work)
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if let error { self.saveFailed(work, error) }
                        self.thumbnailsChanged()
                    }
                }
            }
        }
    }

    var hasUnsavedChanges: Bool { documentDirty || !dirtyInk.isEmpty }

    /// Saves now and waits for it (and for any autosave still being written).
    func save() {
        autosave?.cancel()
        guard let work = captureSave() else {
            writer.sync {}   // nothing new, but an autosave may still be writing
            return
        }
        if let error = writer.sync(execute: { Self.write(work) }) { saveFailed(work, error) }
    }

    private func captureSave() -> SaveWork? {
        guard hasUnsavedChanges else { return nil }
        let ink = dirtyInk.filter { document.pageIndex(of: $0) != nil }.compactMap { id in pages[id].map { (id, $0.snapshot()) } }
        dirtyInk.removeAll()
        document.modified = Date()
        document.lastPageIndex = currentPageIndex
        documentDirty = false
        let cover = document.pages.first.map { ($0, inkPage($0.id).snapshot()) }
        return SaveWork(ink: ink, document: document, cover: cover, package: package, pdf: pdf)
    }

    /// On the writer queue. Returns an error message, or nil.
    private nonisolated static func write(_ work: SaveWork) -> String? {
        do {
            for (id, snapshot) in work.ink {
                if let data = snapshot.save() { try work.package.writeInk(data, pageID: id) }
            }
            try work.package.write(work.document)
            work.package.pruneInk(keeping: work.document)
            if let (page, snapshot) = work.cover,
               let cg = PageImageRenderer.image(page: page, snapshot: snapshot, pdf: work.pdf, package: work.package,
                                                pixelWidth: 360),
               let png = UIImage(cgImage: cg).pngData() {
                try? work.package.writeThumbnail(png)
                ThumbnailCache.shared.invalidate(work.package.url)
            }
            return nil
        } catch {
            return "저장하지 못했습니다. \(error.localizedDescription)"
        }
    }

    private func saveFailed(_ work: SaveWork, _ error: String) {
        lastError = error
        // Try again with the next save.
        dirtyInk.formUnion(work.ink.map(\.0))
        documentDirty = true
    }

    /// Saves and returns a flattened PDF when the account wants PDF copies.
    func close() {
        if document.lastPageIndex != currentPageIndex { documentDirty = true }
        save()
        let exporter: () -> URL? = { [weak self] in try? self?.exportPDF() }
        app.documentClosed(OpenDocument(ref: ref, url: package.url, kind: .notebook), exportPDF: exporter)
    }

    // MARK: New notebook from pages

    func beginPageSelection(with index: Int? = nil) {
        pageSelection = Set([document.pages[safe: index ?? currentPageIndex]?.id].compactMap { $0 })
        showsSidebar = true
    }

    func togglePageSelection(_ id: UUID) {
        guard var selection = pageSelection else { return }
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        pageSelection = selection
    }

    func selectAllPages() {
        guard pageSelection != nil else { return }
        pageSelection = pageSelection?.count == pageCount ? [] : Set(document.pages.map(\.id))
    }

    /// "운영체제 3–5, 8쪽": the default title for a notebook made of the selected pages.
    func suggestedTitle(for selection: Set<UUID>) -> String {
        let numbers = document.pages.indices.filter { selection.contains(document.pages[$0].id) }.map { $0 + 1 }
        var parts: [String] = []
        var i = 0
        while i < numbers.count {
            var j = i
            while j + 1 < numbers.count, numbers[j + 1] == numbers[j] + 1 { j += 1 }
            parts.append(i == j ? "\(numbers[i])" : "\(numbers[i])–\(numbers[j])")
            i = j + 1
        }
        return "\(document.title) \(parts.joined(separator: ", "))쪽"
    }

    /// Saves, then writes the selected pages as a new notebook next to this one.
    func makeNotebook(from selection: Set<UUID>, title: String) -> LibraryRef? {
        save()
        let clean = title.trimmingCharacters(in: .whitespaces)
        let folder = RemotePath.parent(ref.path)
        let lib = app.library(ref.source)
        let ids = document.pages.map(\.id).filter { selection.contains($0) }
        do {
            let made = try package.extractPages(ids, title: clean.isEmpty ? suggestedTitle(for: selection) : clean,
                                                into: lib.url(for: folder), subsetPDF: Self.writePDFSubset)
            app.refreshLibrary()
            app.localChange(in: ref.source)
            pageSelection = nil
            return LibraryRef(source: ref.source, path: RemotePath.join(folder, made.url.lastPathComponent))
        } catch {
            lastError = "새 노트를 만들지 못했습니다. \(error.localizedDescription)"
            return nil
        }
    }

    /// A PDF of only the given pages (zero-based, in order), so the new notebook stays small.
    nonisolated static func writePDFSubset(source: URL, pageIndices: [Int], destination: URL) -> Bool {
        guard let original = PDFDocument(url: source) else { return false }
        let subset = PDFDocument()
        for (n, index) in pageIndices.enumerated() {
            guard let page = original.page(at: index)?.copy() as? PDFPage else { return false }
            subset.insert(page, at: n)
        }
        return subset.pageCount == pageIndices.count && subset.write(to: destination)
    }

    /// Closes this notebook and opens another one (e.g. the one just made from its pages).
    func closeAndOpen(_ other: LibraryRef) {
        close()
        let app = self.app
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { app.openNotebook(other) }
    }

    // MARK: Export

    func exportPDF() throws -> URL {
        save()
        let name = FileNaming.sanitize(document.title) + ".pdf"
        let url = AppPaths.exports.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        var inks: [UUID: InkPage] = [:]
        for page in document.pages { inks[page.id] = inkPage(page.id) }
        try NotebookPDFExporter.export(document: document, package: package, inkPages: inks, to: url)
        return url
    }

    func exportPageImage(_ index: Int) -> URL? {
        guard let page = document.pages[safe: index],
              let cg = PageImageRenderer.image(page: page, ink: inkPage(page.id), pdf: pdf, package: package,
                                               pixelWidth: Int(page.size.width * 3)),
              let png = UIImage(cgImage: cg).pngData() else { return nil }
        let url = AppPaths.exports.appendingPathComponent("\(FileNaming.sanitize(document.title))-\(index + 1).png")
        try? png.write(to: url)
        return url
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif
