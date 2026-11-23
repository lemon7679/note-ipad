#if canImport(UIKit)
import NoteKit
import SwiftUI
import UniformTypeIdentifiers

private enum KindFilter: String, CaseIterable, Identifiable {
    case all = "전체", notes = "노트", pdfs = "PDF", folders = "폴더"
    var id: String { rawValue }

    func includes(_ item: LibraryEntry) -> Bool {
        switch self {
        case .all: return true
        case .notes: return item.kind == .notebook
        case .pdfs: return item.kind == .pdf
        case .folders: return item.kind == .folder
        }
    }
}

/// One folder of a library source (design: Main artboard).
struct LibraryView: View {
    let location: LibraryLocation
    @Binding var path: [String]
    @EnvironmentObject private var app: AppModel
    @State private var items: [LibraryEntry] = []
    @State private var loaded = false
    @State private var filter: KindFilter = .all
    @State private var query = ""
    @State private var searchResults: [LibraryEntry]?
    @State private var showNew = false
    @State private var newSheetMode: NewItemMode = .notebook
    @State private var importing = false
    @State private var importAnnotate = true
    @State private var renaming: LibraryEntry?
    @State private var renameText = ""
    @State private var moving: LibraryEntry?
    @State private var showSyncCenter = false
    @State private var shareItem: ShareItem?
    @State private var deleting: LibraryEntry?

    private var source: LibrarySource { location.source }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    chips
                    if let results = searchResults {
                        documentsGrid(results)
                        if results.isEmpty { emptyState(title: "검색 결과가 없습니다", message: "다른 단어로 찾아보세요.") }
                    } else {
                        let folders = items.filter { $0.kind == .folder && filter.includes($0) }
                        let documents = items.filter { $0.kind != .folder && filter.includes($0) }
                        if !folders.isEmpty { foldersGrid(folders) }
                        if !documents.isEmpty { documentsGrid(documents) }
                        if loaded && folders.isEmpty && documents.isEmpty { emptyFolder }
                    }
                }
                .padding(.horizontal, NoteTheme.Space.page)
                .padding(.top, 20)
                .padding(.bottom, 40)
            }
            .refreshable {
                if let id = source.accountID { app.sync(id, manual: true) }
                await reload()
            }
        }
        .background(NoteTheme.background)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: "\(location.folder)|\(app.libraryRevision)|\(app.settings.librarySort.rawValue)") { await reload() }
        .onChange(of: query) { _, text in
            Task { await runSearch(text) }
        }
        .sheet(isPresented: $showNew) {
            NewItemSheet(location: location, initialMode: newSheetMode).environmentObject(app)
        }
        .sheet(item: $moving) { item in
            MoveSheet(source: source, item: item).environmentObject(app)
        }
        .sheet(item: $shareItem) { item in ShareSheet(items: [item.url]) }
        .fileImporter(isPresented: $importing, allowedContentTypes: importAnnotate ? [.pdf] : [.item],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                if url.pathExtension.lowercased() == "pdf" {
                    app.importPDF(from: url, into: location, annotate: importAnnotate)
                } else {
                    importFile(url)
                }
            }
        }
        .alert("이름 변경", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("이름", text: $renameText)
            Button("취소", role: .cancel) {}
            Button("변경") {
                if let item = renaming { app.rename(LibraryRef(source: source, path: item.path), to: renameText) }
            }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("삭제", role: .destructive) {
                if let item = deleting { app.delete(item, in: source) }
            }
        } message: {
            Text(deleteMessage)
        }
    }

    private var deleteTitle: String {
        guard let item = deleting else { return "" }
        return "‘\(item.displayName)’을(를) 삭제할까요?"
    }

    private var deleteMessage: String {
        guard let item = deleting else { return "" }
        if item.isPlaceholder { return "NAS에서 바로 삭제됩니다." }
        return source.accountID != nil ? "휴지통으로 옮기고, 다음 동기화 때 NAS에서도 삭제됩니다." : "휴지통으로 옮깁니다."
    }

    private func reload() async {
        items = await app.items(in: location)
        loaded = true
        if !query.isEmpty { await runSearch(query) }
    }

    private func runSearch(_ text: String) async {
        let q = text.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            searchResults = nil
        } else {
            let found = await app.search(q, in: source)
            searchResults = found.filter { $0.kind != .folder }
        }
    }

    private func importFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        app.perform(source) { try $0.importFile(from: url, into: location.folder) }
    }

    // MARK: Header (design: breadcrumb · search · sort · sync · 새로 만들기)

    private var header: some View {
        HStack(spacing: 12) {
            breadcrumb
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(NoteTheme.textSecondary)
                TextField("노트와 PDF 검색", text: $query)
                    .textFieldStyle(.plain)
                    .font(NoteTheme.Fonts.body)
                    .submitLabel(.search)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(NoteTheme.textSecondary)
                        .accessibilityLabel("검색어 지우기")
                }
            }
            .padding(.horizontal, 12)
            .frame(width: 220, height: 40)
            .background(NoteTheme.fieldFill, in: RoundedRectangle(cornerRadius: NoteTheme.Radius.control))

            Menu {
                Picker("정렬", selection: $app.settings.librarySort) {
                    ForEach(LibrarySort.allCases) { Text($0.displayName).tag($0) }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 18))
                    .frame(width: NoteTheme.minTouch, height: NoteTheme.minTouch)
                    .foregroundStyle(NoteTheme.iconMuted)
            }
            .accessibilityLabel("정렬")

            if let id = source.accountID {
                let status = app.status(id)
                Button {
                    showSyncCenter = true
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 18))
                            .rotationEffect(.degrees(status.isSyncing ? 360 : 0))
                            .animation(status.isSyncing ? .linear(duration: 1.2).repeatForever(autoreverses: false) : .default,
                                       value: status.isSyncing)
                            .frame(width: NoteTheme.minTouch, height: NoteTheme.minTouch)
                            .foregroundStyle(status.isSyncing ? NoteTheme.accent : NoteTheme.iconMuted)
                        if app.totalConflicts > 0 {
                            Circle().fill(NoteTheme.conflict).frame(width: 9, height: 9).offset(x: -8, y: 8)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("동기화 센터")
                .popover(isPresented: $showSyncCenter) {
                    SyncCenterView(focus: id).environmentObject(app).frame(width: 440, height: 620)
                }
            }

            Menu {
                Button { newSheetMode = .notebook; showNew = true } label: { Label("새 노트", systemImage: "book.closed") }
                Button { importAnnotate = true; importing = true } label: {
                    Label("PDF 가져와서 필기", systemImage: "doc.richtext")
                }
                Button { importAnnotate = false; importing = true } label: {
                    Label("파일 가져오기", systemImage: "square.and.arrow.down")
                }
                Button { newSheetMode = .folder; showNew = true } label: { Label("새 폴더", systemImage: "folder.badge.plus") }
            } label: {
                Label("새로 만들기", systemImage: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .background(NoteTheme.accent, in: RoundedRectangle(cornerRadius: NoteTheme.Radius.control))
            }
        }
        .padding(.horizontal, NoteTheme.Space.page)
        .frame(height: 64)
        .background(NoteTheme.background)
        .overlay(alignment: .bottom) { Rectangle().fill(NoteTheme.separator).frame(height: 1) }
    }

    private var breadcrumb: some View {
        let components = RemotePath.components(location.folder)
        return HStack(spacing: 6) {
            if components.isEmpty {
                Text(app.displayName(source)).font(.system(size: 22, weight: .semibold)).lineLimit(1)
            } else {
                Button(app.displayName(source)) { path = [] }
                    .buttonStyle(.plain).foregroundStyle(NoteTheme.textSecondary).font(NoteTheme.Fonts.body)
                ForEach(Array(components.enumerated()), id: \.offset) { index, name in
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(NoteTheme.offline)
                    if index == components.count - 1 {
                        Text(name).font(.system(size: 22, weight: .semibold)).lineLimit(1)
                    } else {
                        Button(name) { path = Array(path.prefix(index + 1)) }
                            .buttonStyle(.plain).foregroundStyle(NoteTheme.textSecondary).font(NoteTheme.Fonts.body)
                    }
                }
            }
        }
        .foregroundStyle(NoteTheme.textPrimary)
    }

    private var chips: some View {
        HStack(spacing: 8) {
            ForEach(KindFilter.allCases) { f in
                Chip(title: f.rawValue, selected: filter == f) { filter = f }
            }
            Spacer()
            if let id = source.accountID {
                Text(app.status(id).summary).font(NoteTheme.Fonts.caption).foregroundStyle(NoteTheme.textSecondary)
            }
        }
    }

    // MARK: Grids

    private func foldersGrid(_ folders: [LibraryEntry]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
            ForEach(folders) { folder in
                FolderCard(item: folder, source: source)
                    .onTapGesture { path.append(folder.path) }
                    .dropDestination(for: String.self) { paths, _ in
                        for p in paths where p != folder.path {
                            app.move(LibraryRef(source: source, path: p), to: folder.path)
                        }
                        return true
                    }
                    .contextMenu { contextMenu(for: folder) }
            }
        }
    }

    private func documentsGrid(_ documents: [LibraryEntry]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 22, alignment: .top)], spacing: 24) {
            ForEach(documents) { item in
                DocumentCard(item: item, source: source)
                    .onTapGesture { app.open(item, in: source) }
                    .draggable(item.path)
                    .contextMenu { contextMenu(for: item) }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for item: LibraryEntry) -> some View {
        let ref = LibraryRef(source: source, path: item.path)
        if item.kind != .folder {
            Button { app.open(item, in: source) } label: { Label("열기", systemImage: "arrow.up.forward.app") }
        }
        if item.kind == .pdf && !item.isPlaceholder {
            Button { app.annotate(pdf: ref) } label: { Label("필기 시작", systemImage: "pencil.tip") }
        }
        if !item.isPlaceholder {
            Button {
                renameText = item.displayName
                renaming = item
            } label: { Label("이름 변경", systemImage: "pencil") }
            Button { moving = item } label: { Label("이동", systemImage: "folder") }
            Button { app.duplicate(ref) } label: { Label("복제", systemImage: "plus.square.on.square") }
            if item.kind != .folder {
                Button { app.toggleFavorite(ref) } label: {
                    Label(app.isFavorite(ref) ? "즐겨찾기 해제" : "즐겨찾기", systemImage: app.isFavorite(ref) ? "star.slash" : "star")
                }
            }
            if item.kind == .pdf || item.kind == .image || item.kind == .other {
                Button { shareItem = ShareItem(url: app.url(for: ref)) } label: { Label("공유", systemImage: "square.and.arrow.up") }
            }
            if source.accountID != nil, item.kind != .folder, item.kind != .notebook {
                Button { app.evict(item, in: source) } label: { Label("다운로드 항목 제거", systemImage: "icloud.and.arrow.up") }
            }
        }
        Button(role: .destructive) { deleting = item } label: { Label("삭제", systemImage: "trash") }
    }

    // MARK: Empty states

    private var emptyFolder: some View {
        VStack(spacing: 14) {
            Image(systemName: source.accountID != nil ? "externaldrive" : "book.closed")
                .font(.system(size: 40)).foregroundStyle(NoteTheme.offline)
            Text(source.accountID != nil ? "이 NAS 폴더는 비어 있습니다" : "아직 노트가 없습니다")
                .font(NoteTheme.Fonts.sheetTitle)
            Text("새 노트를 만들거나 PDF를 가져와 필기를 시작하세요.")
                .font(NoteTheme.Fonts.body).foregroundStyle(NoteTheme.textSecondary)
            HStack(spacing: 12) {
                Button("새 노트") { newSheetMode = .notebook; showNew = true }.buttonStyle(PrimaryButtonStyle())
                Button("PDF 가져오기") { importAnnotate = true; importing = true }.buttonStyle(SecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func emptyState(title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(NoteTheme.Fonts.sheetTitle)
            Text(message).font(NoteTheme.Fonts.body).foregroundStyle(NoteTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

// MARK: - Cards

struct FolderCard: View {
    let item: LibraryEntry
    let source: LibrarySource
    @EnvironmentObject private var app: AppModel
    @State private var count: Int?

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: NoteTheme.Radius.control)
                .fill(NoteTheme.accentSoft)
                .frame(width: 44, height: 44)
                .overlay(Image(systemName: "folder").font(.system(size: 20)).foregroundStyle(NoteTheme.accent))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName).font(NoteTheme.Fonts.bodyEmphasized).lineLimit(1)
                Text(count.map { "항목 \($0)개" } ?? " ").font(NoteTheme.Fonts.caption).foregroundStyle(NoteTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(NoteTheme.surface, in: RoundedRectangle(cornerRadius: NoteTheme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: NoteTheme.Radius.card).stroke(NoteTheme.separator))
        .contentShape(Rectangle())
        .task(id: app.libraryRevision) {
            count = (try? app.library(source).list(item.path))?.count
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

struct DocumentCard: View {
    let item: LibraryEntry
    let source: LibrarySource
    @EnvironmentObject private var app: AppModel
    @State private var summary: NotebookSummary?
    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            cover
                .frame(height: 212)
                .frame(maxWidth: .infinity)
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName).font(NoteTheme.Fonts.cardTitle).lineLimit(2)
                    Text(meta).font(NoteTheme.Fonts.caption).foregroundStyle(NoteTheme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                SyncBadge(state: app.badge(for: item, in: source), size: 15)
                if app.isFavorite(LibraryRef(source: source, path: item.path)) {
                    Image(systemName: "star.fill").font(.system(size: 12)).foregroundStyle(NoteTheme.conflict)
                        .accessibilityLabel("즐겨찾기")
                }
            }
        }
        .contentShape(Rectangle())
        .task(id: "\(item.path)|\(app.libraryRevision)") { await load() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var meta: String {
        var parts: [String] = []
        if let date = summary?.modified ?? item.modified { parts.append(date.libraryLabel) }
        if let pages = summary?.pageCount { parts.append("\(pages)쪽") }
        if item.isPlaceholder { parts.append(item.size.byteLabel) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var cover: some View {
        switch item.kind {
        case .notebook:
            if let hex = summary?.coverHex {
                NotebookCover(title: summary?.title ?? item.displayName, colorHex: hex)
            } else {
                pageThumbnail
            }
        case .pdf:
            pageThumbnail
                .overlay(alignment: .bottomTrailing) {
                    Text("PDF").font(.system(size: 11, weight: .bold)).foregroundStyle(NoteTheme.danger)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(NoteTheme.dangerSoft, in: RoundedRectangle(cornerRadius: 4))
                        .padding(8)
                }
        default:
            RoundedRectangle(cornerRadius: 6).fill(NoteTheme.surface)
                .overlay(Image(systemName: item.kind == .image ? "photo" : "doc").font(.system(size: 36))
                    .foregroundStyle(NoteTheme.offline))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(NoteTheme.separator))
        }
    }

    private var pageThumbnail: some View {
        ZStack {
            Rectangle().fill(Color.white)
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFit()
            } else if item.isPlaceholder {
                Image(systemName: "icloud.and.arrow.down").font(.system(size: 30)).foregroundStyle(NoteTheme.accent)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(NoteTheme.separator))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 6)
    }

    private func load() async {
        let url = app.url(for: LibraryRef(source: source, path: item.path))
        switch item.kind {
        case .notebook:
            summary = app.library(source).summary(ofNotebook: item.path)
            if summary?.coverHex == nil {
                thumbnail = ThumbnailCache.shared.notebookThumbnail(url)
            }
        case .pdf where !item.isPlaceholder:
            thumbnail = await ThumbnailCache.shared.pdfThumbnail(url)
        default:
            break
        }
    }
}

/// Colored notebook cover with a label (design: radius 6/12, spine line, white label).
struct NotebookCover: View {
    let title: String
    let colorHex: String

    var body: some View {
        UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6, bottomTrailingRadius: 12, topTrailingRadius: 12)
            .fill(Color(hex: colorHex))
            .overlay(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.22)).frame(width: 2).padding(.leading, 10)
            }
            .overlay(alignment: .top) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: "#15171C"))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                    .padding(.leading, 24)
                    .padding(.trailing, 16)
                    .padding(.top, 28)
            }
            .coverShadow()
    }
}

/// Library thumbnails (notebook first pages and PDF first pages).
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, UIImage>()

    func notebookThumbnail(_ packageURL: URL) -> UIImage? {
        let url = packageURL.appendingPathComponent(NotebookPackage.thumbnailFile)
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }

    func pdfThumbnail(_ url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        let image = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let doc = PDFSupport.document(at: url), let page = doc.page(at: 1) else { return nil }
            let size = PDFSupport.pageSize(page)
            let width = 360
            let scale = CGFloat(width) / CGFloat(size.width)
            let height = Int(CGFloat(size.height) * scale)
            guard let ctx = Bitmaps.context(width: width, height: height) else { return nil }
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            Bitmaps.enterPageSpace(ctx, pixelHeight: height, origin: .zero, scale: scale)
            PDFSupport.draw(page, size: size, in: ctx)
            return ctx.makeImage().map { UIImage(cgImage: $0) }
        }.value
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }

    func invalidate(_ packageURL: URL) {
        cache.removeObject(forKey: packageURL.appendingPathComponent(NotebookPackage.thumbnailFile) as NSURL)
    }
}
#endif
