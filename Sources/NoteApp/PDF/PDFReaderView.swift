#if canImport(UIKit)
import NoteKit
import PDFKit
import SwiftUI

@MainActor
final class PDFReaderModel: ObservableObject {
    struct OutlineItem: Identifiable {
        let id = UUID()
        let title: String
        let pageIndex: Int
        let depth: Int
    }

    @Published private(set) var document: PDFDocument?
    @Published var pageIndex = 0
    @Published private(set) var results: [PDFSelection] = []
    @Published private(set) var resultIndex = 0
    @Published private(set) var outline: [OutlineItem] = []
    weak var pdfView: PDFView?

    var pageCount: Int { document?.pageCount ?? 0 }

    func load(_ url: URL) {
        guard document == nil, let doc = PDFDocument(url: url) else { return }
        document = doc
        var items: [OutlineItem] = []
        func walk(_ node: PDFOutline, depth: Int) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                if let page = child.destination?.page {
                    items.append(OutlineItem(title: child.label ?? "", pageIndex: doc.index(for: page), depth: depth))
                }
                walk(child, depth: depth + 1)
            }
        }
        if let root = doc.outlineRoot { walk(root, depth: 0) }
        outline = items
    }

    func go(to index: Int) {
        guard let doc = document, let page = doc.page(at: min(max(index, 0), max(doc.pageCount - 1, 0))) else { return }
        pdfView?.go(to: page)
    }

    func search(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard let doc = document, !query.isEmpty else {
            results = []
            pdfView?.highlightedSelections = nil
            return
        }
        results = doc.findString(query, withOptions: [.caseInsensitive])
        for selection in results { selection.color = UIColor.systemYellow.withAlphaComponent(0.5) }
        pdfView?.highlightedSelections = results
        resultIndex = 0
        showResult()
    }

    func step(_ delta: Int) {
        guard !results.isEmpty else { return }
        resultIndex = (resultIndex + delta + results.count) % results.count
        showResult()
    }

    private func showResult() {
        guard results.indices.contains(resultIndex) else { return }
        let selection = results[resultIndex]
        pdfView?.setCurrentSelection(selection, animate: true)
        pdfView?.go(to: selection)
    }
}

struct PDFKitView: UIViewRepresentable {
    @ObservedObject var model: PDFReaderModel

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.pageShadowsEnabled = true
        view.backgroundColor = NoteTheme.deskUI
        view.document = model.document
        model.pdfView = view
        context.coordinator.observe(view)
        // Let the thumbnail sidebar pick up the new PDFView.
        DispatchQueue.main.async { [model] in model.objectWillChange.send() }
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== model.document { view.document = model.document }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject {
        let model: PDFReaderModel
        private var token: NSObjectProtocol?

        init(model: PDFReaderModel) { self.model = model }

        func observe(_ view: PDFView) {
            token = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) {
                [weak self, weak view] _ in
                guard let view, let page = view.currentPage, let doc = view.document else { return }
                let index = doc.index(for: page)
                MainActor.assumeIsolated { self?.model.pageIndex = index }
            }
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }
}

struct PDFThumbnails: UIViewRepresentable {
    let pdfView: PDFView?

    func makeUIView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView()
        view.layoutMode = .vertical
        view.thumbnailSize = CGSize(width: 96, height: 128)
        view.backgroundColor = .clear
        view.pdfView = pdfView
        return view
    }

    func updateUIView(_ view: PDFThumbnailView, context: Context) {
        if view.pdfView !== pdfView { view.pdfView = pdfView }
    }
}

/// Read-only PDF viewer; "필기" turns it into a notebook next to the PDF.
struct PDFReaderView: View {
    let document: OpenDocument
    @EnvironmentObject private var app: AppModel
    @StateObject private var reader = PDFReaderModel()
    @State private var showSidebar = true
    @State private var sidebarTab = 0
    @State private var searching = false
    @State private var query = ""
    @State private var shareItem: ShareItem?
    @State private var scrub: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            topBar
            HStack(spacing: 0) {
                if showSidebar { sidebar.frame(width: 272).transition(.move(edge: .leading)) }
                ZStack(alignment: .top) {
                    if reader.document != nil {
                        PDFKitView(model: reader)
                    } else {
                        Text("PDF를 열 수 없습니다.").foregroundStyle(NoteTheme.textSecondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if searching { searchBar.padding(.top, 14) }
                    VStack {
                        Spacer()
                        scrubber.padding(.bottom, 16)
                    }
                }
            }
        }
        .background(NoteTheme.desk)
        .animation(.easeInOut(duration: 0.2), value: showSidebar)
        .onAppear { reader.load(document.url) }
        .onChange(of: reader.pageIndex) { _, index in scrub = Double(index) }
        .sheet(item: $shareItem) { item in ShareSheet(items: [item.url]) }
    }

    private var title: String { RemotePath.name(document.ref.path) }

    private var subtitle: String {
        let location = ([app.displayName(document.ref.source)] + RemotePath.components(RemotePath.parent(document.ref.path)))
            .joined(separator: " › ")
        let size = (try? FileManager.default.attributesOfItem(atPath: document.url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return "\(location) · \(reader.pageCount)쪽 · \(size.byteLabel)"
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            Button {
                app.openDocument = nil
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold))
                    Text("닫기").font(.system(size: 15, weight: .medium))
                }
                .foregroundStyle(NoteTheme.accent)
                .frame(height: NoteTheme.minTouch)
            }
            .buttonStyle(.plain)
            VStack(spacing: 1) {
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(NoteTheme.Fonts.caption).foregroundStyle(NoteTheme.textSecondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            HStack(spacing: 2) {
                Text("읽기")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(NoteTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
                Button { startAnnotating() } label: {
                    Text("필기").font(.system(size: 14)).foregroundStyle(NoteTheme.iconMuted)
                        .padding(.horizontal, 14).frame(height: 34)
                }
                .buttonStyle(.plain)
            }
            .padding(3)
            .background(NoteTheme.fieldFill, in: RoundedRectangle(cornerRadius: NoteTheme.Radius.control))
            IconButton(systemName: "list.bullet", label: "목차", isOn: showSidebar) { showSidebar.toggle() }
            IconButton(systemName: "magnifyingglass", label: "검색", isOn: searching) {
                searching.toggle()
                if !searching { reader.search("") }
            }
            IconButton(systemName: "square.and.arrow.up", label: "공유") { shareItem = ShareItem(url: document.url) }
        }
        .padding(.horizontal, 10)
        .frame(height: 56)
        .background(NoteTheme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(NoteTheme.separator).frame(height: 1) }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker("", selection: $sidebarTab) {
                Text("목차").tag(0)
                Text("페이지").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(12)
            if sidebarTab == 0 {
                List {
                    if reader.outline.isEmpty {
                        Text("이 PDF에는 목차가 없습니다.").foregroundStyle(NoteTheme.textSecondary)
                    }
                    ForEach(reader.outline) { item in
                        Button {
                            reader.go(to: item.pageIndex)
                        } label: {
                            HStack {
                                Text(item.title)
                                    .font(.system(size: item.depth == 0 ? 14 : 13, weight: item.depth == 0 ? .medium : .regular))
                                    .padding(.leading, CGFloat(item.depth) * 16)
                                Spacer()
                                Text("\(item.pageIndex + 1)").font(NoteTheme.Fonts.caption).foregroundStyle(NoteTheme.textSecondary)
                            }
                            .foregroundStyle(NoteTheme.textPrimary)
                        }
                        .listRowBackground(item.pageIndex == reader.pageIndex ? NoteTheme.accentSoft : Color.clear)
                    }
                }
                .listStyle(.plain)
            } else {
                PDFThumbnails(pdfView: reader.pdfView)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("필기 노트로 열기").font(.system(size: 13, weight: .semibold))
                Text(document.isRemoteCopy
                     ? "노트 폴더로 가져온 뒤 필기를 시작합니다. 원본은 NAS에 그대로 남습니다."
                     : "원본 PDF는 그대로 두고, 필기는 별도 노트로 저장합니다.")
                    .font(NoteTheme.Fonts.caption).foregroundStyle(NoteTheme.textSecondary)
                Button("필기 시작") { startAnnotating() }
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(maxWidth: .infinity)
            }
            .padding(14)
            .overlay(alignment: .top) { Rectangle().fill(NoteTheme.separator).frame(height: 1) }
        }
        .background(NoteTheme.surface)
        .overlay(alignment: .trailing) { Rectangle().fill(NoteTheme.separator).frame(width: 1) }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(NoteTheme.textSecondary)
            TextField("PDF에서 찾기", text: $query)
                .submitLabel(.search)
                .onSubmit { reader.search(query) }
            if !reader.results.isEmpty {
                Text("\(reader.resultIndex + 1) / \(reader.results.count)").font(.system(size: 13))
                    .foregroundStyle(NoteTheme.textSecondary)
            }
            Button { reader.step(-1) } label: { Image(systemName: "chevron.up").frame(width: 36, height: 36) }
                .accessibilityLabel("이전 결과")
            Button { reader.step(1) } label: { Image(systemName: "chevron.down").frame(width: 36, height: 36) }
                .accessibilityLabel("다음 결과")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(width: 440, height: 44)
        .background(NoteTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 6)
    }

    private var scrubber: some View {
        HStack(spacing: 12) {
            Text("\(reader.pageIndex + 1)").monospacedDigit()
            Slider(value: $scrub, in: 0...Double(max(reader.pageCount - 1, 1)), step: 1) { editing in
                if !editing { reader.go(to: Int(scrub)) }
            }
            .frame(width: 260)
            .tint(.white)
            Text("\(reader.pageCount)").monospacedDigit()
        }
        .font(.system(size: 13))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color.black.opacity(0.82), in: Capsule())
        .opacity(reader.pageCount > 1 ? 1 : 0)
    }

    private func startAnnotating() {
        if document.isRemoteCopy {
            // Bring the PDF into the synced notes folder first, then annotate it there.
            let location = LibraryLocation(source: document.ref.source, folder: "/")
            let lib = app.library(location.source)
            do {
                let path = try lib.importFile(from: document.url, into: "/")
                app.refreshLibrary()
                app.localChange(in: location.source)
                app.annotate(pdf: LibraryRef(source: location.source, path: path))
            } catch {
                app.errorMessage = error.localizedDescription
            }
        } else {
            app.annotate(pdf: document.ref)
        }
    }
}
#endif
