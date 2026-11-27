#if canImport(UIKit)
import Foundation
import NoteKit
import SwiftUI

/// Where a document opens in the workspace (the screen that covers the library while
/// documents are open: up to two panes side by side plus floating windows).
enum DocumentPlacement: Equatable {
    /// From the library: the only pane. While documents are already open, a floating window.
    case main
    /// In place of an open document (e.g. "필기 시작" in a PDF pane).
    case replacing(String)
    /// Split screen next to this pane (replaces the other pane when there are two).
    case beside(String)
    /// A floating window over the panes.
    case floating
}

/// How a pane shows its document.
enum PaneRole: Equatable {
    /// Alone on the screen.
    case single
    /// Left / right half of the split screen.
    case left, right
    /// Inside a floating window.
    case floating

    /// The leading button closes every document and goes back to the library.
    var closesWorkspace: Bool { self == .single || self == .left }
}

/// A document in a floating window.
struct FloatingDocument: Identifiable, Equatable {
    var document: OpenDocument
    /// In workspace coordinates; nil until moved or resized (a default spot is used).
    var frame: CGRect?
    var collapsed = false
    /// Stacking order (higher is in front).
    var z: Int
    /// Offsets the default spot so new windows don't cover each other exactly.
    var cascade: Int

    var id: String { document.id }
}

/// Asks for the "문서 열기" sheet.
struct DocumentPickerRequest: Identifiable {
    let id = UUID()
    let placement: DocumentPlacement

    var title: String {
        switch placement {
        case .beside: return "옆에 열기"
        case .floating: return "떠 있는 창으로 열기"
        case .replacing: return "이 창에 열기"
        case .main: return "문서 열기"
        }
    }
}

/// Editor and reader state of the open documents, kept while a document moves between
/// panes and floating windows (the views are rebuilt; the models are not).
@MainActor
final class DocumentSessions {
    private(set) var editors: [String: EditorModel] = [:]
    private var readers: [String: PDFReaderModel] = [:]

    /// The notebook's editor, made on first use. Nil once the document has been closed.
    func editor(for document: OpenDocument, app: AppModel) throws -> EditorModel? {
        if let editor = editors[document.id] { return editor }
        guard app.isOpen(document.id) else { return nil }
        let editor = try EditorModel(ref: document.ref, url: document.url, app: app)
        editors[document.id] = editor
        return editor
    }

    func reader(for document: OpenDocument, app: AppModel) -> PDFReaderModel {
        if let reader = readers[document.id] { return reader }
        let reader = PDFReaderModel()
        if app.isOpen(document.id) { readers[document.id] = reader }
        return reader
    }

    func discard(_ id: String) {
        editors[id] = nil
        readers[id] = nil
    }
}

// MARK: - Workspace actions

extension AppModel {
    static let maxFloatingWindows = 3
    /// Panes narrower than this would not fit the editor's tool row.
    static let minPaneWidth: CGFloat = 320

    var isWorkspaceOpen: Bool { !panes.isEmpty }
    var openDocumentCount: Int { panes.count + floating.count }

    func isOpen(_ id: String) -> Bool {
        panes.contains { $0.id == id } || floating.contains { $0.id == id }
    }

    func openDocument(withID id: String) -> OpenDocument? {
        panes.first { $0.id == id } ?? floating.first { $0.id == id }?.document
    }

    /// Shows `document`; if it is already open somewhere, brings that one forward instead
    /// (a notebook is never edited in two places at once).
    func present(_ document: OpenDocument, placement: DocumentPlacement = .main) {
        if isOpen(document.id) {
            focus(document.id, reveal: true)
            return
        }
        if document.kind == .notebook { openNotebooks[document.ref.source, default: []].insert(document.ref.path) }
        switch placement {
        case .main:
            if panes.isEmpty { panes = [document] } else { addFloating(document) }
        case .replacing(let id):
            replaceDocument(id, with: document)
        case .beside(let id):
            if panes.isEmpty {
                panes = [document]
            } else if panes.count == 1 {
                panes.append(document)
                splitFraction = 0.5
            } else {
                let other = panes.first { $0.id != id } ?? panes[1]
                replaceDocument(other.id, with: document)
            }
        case .floating:
            if panes.isEmpty { panes = [document] } else { addFloating(document) }
        }
        focusedDocumentID = document.id
    }

    private func addFloating(_ document: OpenDocument, frame: CGRect? = nil) {
        if floating.count >= Self.maxFloatingWindows, let oldest = floating.min(by: { $0.z < $1.z }) {
            closeDocument(oldest.id)
        }
        floatingCounter += 1
        floating.append(FloatingDocument(document: document, frame: frame, z: floatingCounter, cascade: floatingCounter))
    }

    private func replaceDocument(_ id: String, with document: OpenDocument) {
        guard let old = openDocument(withID: id) else {
            if panes.isEmpty { panes = [document] } else { addFloating(document) }
            return
        }
        if let index = panes.firstIndex(where: { $0.id == id }) {
            panes[index] = document
        } else if let index = floating.firstIndex(where: { $0.id == id }) {
            floating[index].document = document
            floating[index].collapsed = false
        }
        if focusedDocumentID == id { focusedDocumentID = document.id }
        finishClosing(old)
    }

    /// Closes one document (saving it). The other documents stay; a floating window moves
    /// into the panes when the last pane closes.
    func closeDocument(_ id: String) {
        guard let document = openDocument(withID: id) else { return }
        removeFromLayout(id)
        finishClosing(document)
    }

    /// Closes every open document and goes back to the library.
    func closeWorkspace() {
        // Floating windows first, so none of them is promoted into a pane on the way.
        for window in floating { closeDocument(window.id) }
        for pane in panes.reversed() { closeDocument(pane.id) }
    }

    private func finishClosing(_ document: OpenDocument) {
        if let editor = sessions.editors[document.id] {
            editor.close()   // saves, then calls documentClosed
        } else {
            documentClosed(document)
        }
        sessions.discard(document.id)
    }

    func removeFromLayout(_ id: String) {
        if let index = panes.firstIndex(where: { $0.id == id }) {
            panes.remove(at: index)
            if panes.isEmpty, let front = floating.max(by: { $0.z < $1.z }) {
                floating.removeAll { $0.id == front.id }
                panes = [front.document]
            }
        } else {
            floating.removeAll { $0.id == id }
        }
        if focusedDocumentID == id || (focusedDocumentID.map { !isOpen($0) } ?? false) {
            focusedDocumentID = floating.filter { !$0.collapsed }.max(by: { $0.z < $1.z })?.id ?? panes.first?.id
        }
    }

    /// The pane or window the user last touched; a floating window also comes to the front.
    func focus(_ id: String, reveal: Bool = false) {
        if focusedDocumentID != id { focusedDocumentID = id }
        guard let index = floating.firstIndex(where: { $0.id == id }) else { return }
        if reveal && floating[index].collapsed { floating[index].collapsed = false }
        if floating[index].z != floating.map(\.z).max() {
            floatingCounter += 1
            floating[index].z = floatingCounter
        }
    }

    func requestDocument(_ placement: DocumentPlacement) {
        documentPicker = DocumentPickerRequest(placement: placement)
    }

    func swapPanes() {
        guard panes.count == 2 else { return }
        panes.reverse()
        splitFraction = 1 - splitFraction
    }

    /// A split pane becomes a floating window (the other pane fills the screen).
    func moveToFloating(_ id: String) {
        guard panes.count == 2, let index = panes.firstIndex(where: { $0.id == id }) else { return }
        let document = panes.remove(at: index)
        floatingCounter += 1
        floating.append(FloatingDocument(document: document, frame: nil, z: floatingCounter, cascade: floatingCounter))
        focusedDocumentID = id
    }

    /// A floating window joins the split screen; with two panes already, it trades places
    /// with the right one (which takes over the window).
    func moveToSplit(_ id: String) {
        guard let index = floating.firstIndex(where: { $0.id == id }) else { return }
        let document = floating[index].document
        if panes.count < 2 {
            floating.remove(at: index)
            panes.append(document)
            splitFraction = 0.5
        } else {
            let right = panes[1]
            panes[1] = document
            floating[index].document = right
            floating[index].collapsed = false
        }
        focusedDocumentID = id
    }

    func setCollapsed(_ id: String, _ collapsed: Bool) {
        guard let index = floating.firstIndex(where: { $0.id == id }) else { return }
        floating[index].collapsed = collapsed
        if collapsed, focusedDocumentID == id {
            focusedDocumentID = floating.filter { !$0.collapsed }.max(by: { $0.z < $1.z })?.id ?? panes.first?.id
        } else if !collapsed {
            focus(id)
        }
    }

    func setFloatingFrame(_ id: String, _ frame: CGRect) {
        guard let index = floating.firstIndex(where: { $0.id == id }) else { return }
        floating[index].frame = frame
    }

    // MARK: Apple Pencil

    /// Every canvas on screen has its own pencil interaction. The first one to report a
    /// double tap / squeeze passes it here; copies of the same event from the other canvases
    /// are dropped, and the event goes to the focused notebook (or the frontmost one).
    func routePencil(_ key: String, from source: EditorModel) -> EditorModel? {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastPencilEvent, last.key == key, now - last.time < 0.08 { return nil }
        lastPencilEvent = (key, now)
        if key == "squeeze-ended" || key == "squeeze-cancelled", let held = squeezeTarget {
            squeezeTarget = nil
            return held
        }
        let target = pencilTarget ?? source
        if key == "squeeze-began" { squeezeTarget = target }
        return target
    }

    private var pencilTarget: EditorModel? {
        if let id = focusedDocumentID, let editor = sessions.editors[id] { return editor }
        let order = floating.filter { !$0.collapsed }.sorted { $0.z > $1.z }.map(\.id) + panes.map(\.id)
        return order.lazy.compactMap { self.sessions.editors[$0] }.first
    }
}
#endif
