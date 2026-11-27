#if canImport(UIKit)
import NoteKit
import SwiftUI

/// The open documents over the library: one pane, or two side by side (split screen),
/// plus floating windows that can be moved, resized and minimized.
struct WorkspaceView: View {
    static let space = "workspace"
    @EnvironmentObject private var app: AppModel

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                panes(width: geo.size.width)
                ForEach(app.floating) { window in
                    FloatingWindowView(window: window, bounds: geo.size)
                        .zIndex(10 + Double(window.z))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .coordinateSpace(name: Self.space)
        }
        .background(NoteTheme.desk)
        .sheet(item: $app.documentPicker) { request in
            DocumentPickerSheet(request: request).environmentObject(app)
        }
    }

    /// Panes keep their identity (by document) when the second one comes and goes, so the
    /// first document is not rebuilt.
    private func panes(width: CGFloat) -> some View {
        let split = app.panes.count == 2
        let usable = max(width - SplitDivider.width, 0)
        let fraction = SplitDivider.clamp(app.splitFraction, width: width)
        return HStack(spacing: 0) {
            ForEach(Array(app.panes.enumerated()), id: \.element.id) { index, document in
                if index == 1 { SplitDivider(totalWidth: width) }
                DocumentPane(document: document, role: split ? (index == 0 ? .left : .right) : .single)
                    .frame(width: split ? (index == 0 ? usable * fraction : usable * (1 - fraction)) : nil)
                    .frame(maxWidth: split ? nil : .infinity)
            }
        }
    }
}

/// A notebook editor or a PDF reader in a pane or floating window.
struct DocumentPane: View {
    let document: OpenDocument
    let role: PaneRole
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Group {
            switch document.kind {
            case .notebook:
                NotebookEditorHost(document: document, role: role)
            case .pdf:
                PDFReaderView(document: document, reader: app.sessions.reader(for: document, app: app), role: role)
            }
        }
        .id(document.id)
    }
}

/// The bar between the two panes. Dragging shows where it will go and resizes the panes
/// when let go (live resizing would re-lay out both canvases on every frame).
struct SplitDivider: View {
    static let width: CGFloat = 12
    let totalWidth: CGFloat
    @EnvironmentObject private var app: AppModel
    @State private var dragX: CGFloat?

    static func clamp(_ fraction: CGFloat, width: CGFloat) -> CGFloat {
        let minFraction = min(AppModel.minPaneWidth / max(width, 1), 0.5)
        return min(max(fraction, minFraction), 1 - minFraction)
    }

    var body: some View {
        ZStack {
            Rectangle().fill(NoteTheme.separator).frame(width: 1)
            Capsule().fill(dragX == nil ? NoteTheme.offline : NoteTheme.accent)
                .frame(width: 5, height: 44)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(NoteTheme.surface)
        .contentShape(Rectangle().inset(by: -8))
        .overlay(alignment: .leading) {
            if let dragX {
                // Preview of the new position, relative to this divider.
                GeometryReader { geo in
                    let here = geo.frame(in: .named(WorkspaceView.space)).minX
                    Rectangle().fill(NoteTheme.accent).frame(width: 3)
                        .offset(x: dragX - here)
                }
                .allowsHitTesting(false)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(WorkspaceView.space))
                .onChanged { value in
                    let fraction = Self.clamp(value.location.x / max(totalWidth, 1), width: totalWidth)
                    dragX = fraction * totalWidth
                }
                .onEnded { value in
                    let fraction = Self.clamp(value.location.x / max(totalWidth, 1), width: totalWidth)
                    dragX = nil
                    withAnimation(.easeInOut(duration: 0.2)) { app.splitFraction = fraction }
                }
        )
        .onTapGesture(count: 2) {
            withAnimation(.easeInOut(duration: 0.2)) { app.splitFraction = 0.5 }
        }
        .accessibilityElement()
        .accessibilityLabel("분할 화면 크기")
        .accessibilityValue("\(Int(SplitDivider.clamp(app.splitFraction, width: totalWidth) * 100))%")
        .accessibilityAdjustableAction { direction in
            let step: CGFloat = direction == .increment ? 0.1 : -0.1
            app.splitFraction = Self.clamp(app.splitFraction + step, width: totalWidth)
        }
    }
}

// MARK: - Floating windows

/// Lets the title bar inside a floating window move the window.
struct FloatingWindowMover {
    var changed: (CGSize) -> Void
    var ended: (CGSize) -> Void
}

private struct FloatingWindowMoverKey: EnvironmentKey {
    static let defaultValue: FloatingWindowMover? = nil
}

extension EnvironmentValues {
    var floatingWindowMover: FloatingWindowMover? {
        get { self[FloatingWindowMoverKey.self] }
        set { self[FloatingWindowMoverKey.self] = newValue }
    }
}

struct FloatingWindowView: View {
    static let minSize = CGSize(width: 320, height: 300)
    let window: FloatingDocument
    let bounds: CGSize
    @EnvironmentObject private var app: AppModel
    @State private var move: CGSize = .zero
    @State private var resize: CGSize?

    var body: some View {
        let frame = currentFrame
        Group {
            if window.collapsed {
                collapsedChip
                    .offset(x: frame.minX + move.width, y: frame.minY + move.height)
            } else {
                DocumentPane(document: window.document, role: .floating)
                    .frame(width: frame.width, height: frame.height)
                    .clipShape(RoundedRectangle(cornerRadius: NoteTheme.Radius.card))
                    .overlay(RoundedRectangle(cornerRadius: NoteTheme.Radius.card)
                        .stroke(focused ? NoteTheme.accent : NoteTheme.controlBorder, lineWidth: focused ? 2 : 1))
                    .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
                    .overlay(alignment: .topLeading) { resizePreview(frame) }
                    .overlay(alignment: .bottomTrailing) { resizeHandle(frame) }
                    .offset(x: frame.minX + move.width, y: frame.minY + move.height)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .environment(\.floatingWindowMover, FloatingWindowMover(
            changed: { translation in
                app.focus(window.id)
                move = translation
            },
            ended: { translation in
                var moved = frame
                moved.origin.x += translation.width
                moved.origin.y += translation.height
                app.setFloatingFrame(window.id, clamped(moved))
                move = .zero
            }))
    }

    private var focused: Bool { app.focusedDocumentID == window.id && app.openDocumentCount > 1 }

    /// The stored frame kept inside the workspace (e.g. after rotating), or a default spot
    /// on the right, cascading for each new window.
    private var currentFrame: CGRect {
        if let frame = window.frame { return clamped(frame) }
        let width = min(max(bounds.width * 0.42, Self.minSize.width), 460)
        let height = min(max(bounds.height * 0.62, Self.minSize.height), 620)
        let step = CGFloat((window.cascade - 1) % 4) * 28
        return clamped(CGRect(x: bounds.width - width - 24 - step, y: 72 + step, width: width, height: height))
    }

    private func clamped(_ frame: CGRect) -> CGRect {
        var f = frame
        f.size.width = min(max(f.width, Self.minSize.width), bounds.width)
        f.size.height = min(max(f.height, Self.minSize.height), bounds.height)
        f.origin.x = min(max(f.minX, 0), max(bounds.width - f.width, 0))
        f.origin.y = min(max(f.minY, 0), max(bounds.height - f.height, 0))
        return f
    }

    /// Bottom-right corner: drag to resize (an outline shows the new size until let go).
    private func resizeHandle(_ frame: CGRect) -> some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 12, weight: .bold))
            .rotationEffect(.degrees(90))
            .foregroundStyle(NoteTheme.iconMuted)
            .frame(width: 28, height: 28)
            .background(NoteTheme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(NoteTheme.separator))
            .padding(6)
            .frame(width: NoteTheme.minTouch, height: NoteTheme.minTouch, alignment: .bottomTrailing)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(WorkspaceView.space))
                    .onChanged { value in
                        app.focus(window.id)
                        resize = value.translation
                    }
                    .onEnded { value in
                        var resized = frame
                        resized.size.width += value.translation.width
                        resized.size.height += value.translation.height
                        resize = nil
                        app.setFloatingFrame(window.id, clamped(resized))
                    }
            )
            .accessibilityLabel("창 크기 조절")
    }

    @ViewBuilder
    private func resizePreview(_ frame: CGRect) -> some View {
        if let resize {
            let target = clamped(CGRect(origin: frame.origin,
                                        size: CGSize(width: frame.width + resize.width, height: frame.height + resize.height)))
            RoundedRectangle(cornerRadius: NoteTheme.Radius.card)
                .stroke(NoteTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .background(NoteTheme.accentSoft.opacity(0.25), in: RoundedRectangle(cornerRadius: NoteTheme.Radius.card))
                .frame(width: target.width, height: target.height)
                .allowsHitTesting(false)
        }
    }

    /// A minimized window: a small chip that stays where the window was. Tap to open again.
    private var collapsedChip: some View {
        HStack(spacing: 8) {
            Image(systemName: window.document.kind == .notebook ? "book.closed" : "doc.richtext")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(NoteTheme.accent)
            Text(chipTitle).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                .foregroundStyle(NoteTheme.textPrimary)
                .frame(maxWidth: 180, alignment: .leading)
            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NoteTheme.iconMuted)
        }
        .padding(.horizontal, 14)
        .frame(height: NoteTheme.minTouch)
        .background(NoteTheme.surface, in: Capsule())
        .overlay(Capsule().stroke(NoteTheme.controlBorder))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
        .contentShape(Capsule())
        .onTapGesture { withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) { app.setCollapsed(window.id, false) } }
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named(WorkspaceView.space))
                .onChanged { move = $0.translation }
                .onEnded { value in
                    var moved = currentFrame
                    moved.origin.x += value.translation.width
                    moved.origin.y += value.translation.height
                    app.setFloatingFrame(window.id, clamped(moved))
                    move = .zero
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(chipTitle), 최소화된 창")
        .accessibilityHint("탭하면 창을 다시 엽니다")
        .accessibilityAddTraits(.isButton)
    }

    private var chipTitle: String {
        let name = RemotePath.name(window.document.ref.path)
        return window.document.kind == .notebook ? FileNaming.split(name).base : name
    }
}

/// Title bar of a floating window: drag to move; window menu, minimize and close.
/// `trailing` holds the document's own buttons (undo/redo, search).
struct FloatingHeader<Trailing: View>: View {
    let documentID: String
    let title: String
    let symbol: String
    @ViewBuilder var trailing: Trailing
    @EnvironmentObject private var app: AppModel
    @Environment(\.floatingWindowMover) private var mover

    var body: some View {
        HStack(spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NoteTheme.offline)
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(NoteTheme.accent)
                Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(NoteTheme.textPrimary)
            }
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, minHeight: NoteTheme.minTouch, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named(WorkspaceView.space))
                    .onChanged { mover?.changed($0.translation) }
                    .onEnded { mover?.ended($0.translation) }
            )
            .accessibilityElement(children: .combine)
            .accessibilityHint("끌어서 창을 옮깁니다")
            trailing
            Menu {
                Button { app.moveToSplit(documentID) } label: {
                    Label(app.panes.count == 2 ? "분할 화면의 오른쪽과 바꾸기" : "분할 화면으로", systemImage: "rectangle.split.2x1")
                }
                Button { app.requestDocument(.replacing(documentID)) } label: {
                    Label("이 창에 다른 문서 열기", systemImage: "doc.on.doc")
                }
                Button { app.requestDocument(.floating) } label: {
                    Label("떠 있는 창 하나 더 열기", systemImage: "macwindow.badge.plus")
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 18))
                    .frame(width: 40, height: NoteTheme.minTouch)
                    .foregroundStyle(NoteTheme.iconMuted)
            }
            .accessibilityLabel("창")
            IconButton(systemName: "minus", label: "최소화", size: 17) {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) { app.setCollapsed(documentID, true) }
            }
            IconButton(systemName: "xmark", label: "창 닫기", size: 17) {
                withAnimation(.easeInOut(duration: 0.2)) { app.closeDocument(documentID) }
            }
        }
        .padding(.trailing, 4)
        .frame(height: 48)
        .background(NoteTheme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(NoteTheme.separator).frame(height: 1) }
    }
}

/// "창" in a pane's top bar: open another document beside it or in a floating window,
/// and arrange the split screen.
struct WindowMenu: View {
    let documentID: String
    let role: PaneRole
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Menu {
            Section {
                Button { app.requestDocument(.beside(documentID)) } label: {
                    Label(app.panes.count == 2 ? "옆 창에 다른 문서 열기" : "옆에 열기 (분할 화면)", systemImage: "rectangle.split.2x1")
                }
                Button { app.requestDocument(.floating) } label: {
                    Label("떠 있는 창으로 열기", systemImage: "macwindow.on.rectangle")
                }
            }
            if app.panes.count == 2 {
                Section {
                    Button { withAnimation(.easeInOut(duration: 0.2)) { app.swapPanes() } } label: {
                        Label("좌우 바꾸기", systemImage: "arrow.left.arrow.right")
                    }
                    Button { withAnimation(.easeInOut(duration: 0.2)) { app.moveToFloating(documentID) } } label: {
                        Label("이 문서를 떠 있는 창으로", systemImage: "rectangle.on.rectangle")
                    }
                    Button { withAnimation(.easeInOut(duration: 0.2)) { app.closeDocument(documentID) } } label: {
                        Label("이 창 닫기", systemImage: "xmark")
                    }
                }
            }
            if app.floating.contains(where: \.collapsed) {
                Section("최소화된 창") {
                    ForEach(app.floating.filter(\.collapsed)) { window in
                        Button { app.setCollapsed(window.id, false) } label: {
                            Label(RemotePath.name(window.document.ref.path),
                                  systemImage: window.document.kind == .notebook ? "book.closed" : "doc.richtext")
                        }
                    }
                }
            }
            if app.openDocumentCount > 1 {
                Button(role: .destructive) { app.closeWorkspace() } label: {
                    Label("모두 닫고 라이브러리로", systemImage: "books.vertical")
                }
            }
        } label: {
            Image(systemName: app.panes.count == 2 ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                .font(.system(size: 19))
                .frame(width: NoteTheme.minTouch, height: NoteTheme.minTouch)
                .foregroundStyle(app.openDocumentCount > 1 ? NoteTheme.accent : NoteTheme.iconMuted)
        }
        .accessibilityLabel("창: 분할 화면과 떠 있는 창")
    }
}

// MARK: - Picking a document to open

/// Chooses a notebook or PDF for a split pane or floating window: recent documents and
/// every storage's folders.
struct DocumentPickerSheet: View {
    let request: DocumentPickerRequest
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                let recents = recentDocuments
                if !recents.isEmpty {
                    Section("최근 문서") {
                        ForEach(recents) { recent in
                            DocumentPickerRow(item: recent.item, source: recent.ref.source, showSource: true) {
                                pick(recent.item, recent.ref.source)
                            }
                        }
                    }
                }
                Section("저장소") {
                    ForEach(sources, id: \.self) { source in
                        NavigationLink(value: LibraryLocation(source: source, folder: "/")) {
                            Label(app.displayName(source), systemImage: app.symbolName(source))
                        }
                    }
                }
            }
            .navigationDestination(for: LibraryLocation.self) { location in
                DocumentPickerFolder(location: location) { item in pick(item, location.source) }
            }
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } } }
        }
    }

    private var sources: [LibrarySource] { [.local] + app.accounts.map { .account($0.id) } }

    private struct Recent: Identifiable {
        let ref: LibraryRef
        let item: LibraryEntry
        var id: String { ref.id }
    }

    private var recentDocuments: [Recent] {
        app.existingItems(app.recents.map(\.ref))
            .map { Recent(ref: $0.0, item: $0.1) }
            .filter { $0.item.kind == .notebook || $0.item.kind == .pdf }
            .prefix(8)
            .map { $0 }
    }

    private func pick(_ item: LibraryEntry, _ source: LibrarySource) {
        dismiss()
        app.open(item, in: source, placement: request.placement)
    }
}

private struct DocumentPickerFolder: View {
    let location: LibraryLocation
    let pick: (LibraryEntry) -> Void
    @EnvironmentObject private var app: AppModel
    @State private var items: [LibraryEntry]?
    @State private var query = ""

    var body: some View {
        List {
            if let items {
                let shown = items.filter { item in
                    (item.kind == .folder || item.kind == .notebook || item.kind == .pdf)
                        && (query.isEmpty || item.displayName.localizedCaseInsensitiveContains(query))
                }
                if shown.isEmpty {
                    Text(query.isEmpty ? "노트나 PDF가 없습니다." : "찾는 문서가 없습니다.")
                        .foregroundStyle(NoteTheme.textSecondary)
                }
                ForEach(shown) { item in
                    if item.kind == .folder {
                        NavigationLink(value: LibraryLocation(source: location.source, folder: item.path)) {
                            Label(item.displayName, systemImage: "folder")
                        }
                    } else {
                        DocumentPickerRow(item: item, source: location.source, showSource: false) { pick(item) }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .searchable(text: $query, prompt: "이 폴더에서 찾기")
        .navigationTitle(location.folder == "/" ? app.displayName(location.source) : RemotePath.name(location.folder))
        .task(id: app.libraryRevision) { items = await app.items(in: location) }
    }
}

private struct DocumentPickerRow: View {
    let item: LibraryEntry
    let source: LibrarySource
    let showSource: Bool
    let action: () -> Void
    @EnvironmentObject private var app: AppModel

    var body: some View {
        let isOpen = app.isOpen(LibraryRef(source: source, path: item.path).id)
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: item.kind == .notebook ? "book.closed" : "doc.richtext")
                    .font(.system(size: 18))
                    .foregroundStyle(item.kind == .notebook ? NoteTheme.accent : NoteTheme.danger)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName).font(NoteTheme.Fonts.body).foregroundStyle(NoteTheme.textPrimary).lineLimit(1)
                    let detail = [showSource ? app.displayName(source) : nil, item.modified?.libraryLabel]
                        .compactMap { $0 }.joined(separator: " · ")
                    if !detail.isEmpty {
                        Text(detail).font(NoteTheme.Fonts.caption).foregroundStyle(NoteTheme.textSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if isOpen {
                    StatusPill(text: "열려 있음", foreground: NoteTheme.accent, background: NoteTheme.accentSoft)
                } else if item.isPlaceholder {
                    Image(systemName: "icloud.and.arrow.down").foregroundStyle(NoteTheme.accent)
                        .accessibilityLabel("NAS에서 받기")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(isOpen ? "이미 열려 있는 창으로 이동합니다" : "")
    }
}
#endif
