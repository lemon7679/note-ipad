#if canImport(UIKit)
import InkBridge
import NoteKit
import SwiftUI

/// Loads a notebook and shows the editor (or why it could not be opened).
struct NotebookEditorHost: View {
    let document: OpenDocument
    @EnvironmentObject private var app: AppModel
    @State private var model: EditorModel?
    @State private var failure: String?

    var body: some View {
        Group {
            if let model {
                NotebookEditorView(model: model)
            } else if let failure {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 40)).foregroundStyle(NoteTheme.conflict)
                    Text(failure).font(NoteTheme.Fonts.body).multilineTextAlignment(.center)
                    Button("라이브러리로 돌아가기") { app.documentClosed(document) }
                        .buttonStyle(PrimaryButtonStyle())
                }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(NoteTheme.background)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(NoteTheme.desk)
            }
        }
        .task {
            guard model == nil, failure == nil else { return }
            do {
                model = try EditorModel(ref: document.ref, url: document.url, app: app)
            } catch {
                failure = "노트를 열 수 없습니다.\n\(error.localizedDescription)"
            }
        }
    }
}

struct NotebookEditorView: View {
    @ObservedObject var model: EditorModel
    @EnvironmentObject private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPenSettings = false
    @State private var showPanel = false
    @State private var showPaper = false
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var shareItem: ShareItem?
    @State private var customColor = Color.black

    var body: some View {
        VStack(spacing: 0) {
            topBar
            toolRow
            HStack(spacing: 0) {
                if model.showsSidebar {
                    PageSidebar(model: model)
                        .frame(width: 132)
                        .transition(.move(edge: .leading))
                }
                ZStack(alignment: .bottom) {
                    CanvasView(model: model, settings: app.settings)
                        .ignoresSafeArea(edges: .bottom)
                    bottomOverlay
                }
            }
        }
        .background(NoteTheme.desk)
        .animation(.easeInOut(duration: 0.2), value: model.showsSidebar)
        .sheet(isPresented: $showPanel) { EditorPanel(model: model) }
        .sheet(isPresented: $showPaper) { PaperSheet(model: model) }
        .sheet(item: $shareItem) { item in ShareSheet(items: [item.url]) }
        .alert("노트 이름", isPresented: $renaming) {
            TextField("제목", text: $newTitle)
            Button("취소", role: .cancel) {}
            Button("변경") { model.rename(newTitle) }
        }
        .alert("오류", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(model.lastError ?? "")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.save() }
        }
        .statusBarHidden(false)
    }

    // MARK: Top bar (design: 52 pt, white)

    private var syncPill: some View {
        let style = syncPillStyle()
        return StatusPill(text: style.text, foreground: style.foreground, background: style.background,
                          symbol: style.symbol)
    }

    private func syncPillStyle() -> (text: String, foreground: Color, background: Color, symbol: String) {
        guard let id = model.ref.source.accountID, let account = app.account(id) else {
            return ("이 iPad", NoteTheme.textSecondary, NoteTheme.fieldFill, "ipad")
        }
        let status = app.status(id)
        if case .error = status.phase {
            return (account.name, NoteTheme.danger, NoteTheme.dangerSoft, "exclamationmark")
        }
        if status.isSyncing {
            return (account.name, NoteTheme.accent, NoteTheme.accentSoft, "arrow.triangle.2.circlepath")
        }
        return (account.name, NoteTheme.synced, NoteTheme.syncedSoft, "checkmark")
    }

    private var topBar: some View {
        HStack(spacing: 4) {
            Button {
                model.close()
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold))
                    Text("라이브러리").font(.system(size: 15, weight: .medium))
                }
                .foregroundStyle(NoteTheme.accent)
                .frame(height: NoteTheme.minTouch)
                .padding(.trailing, 6)
            }
            .buttonStyle(.plain)
            IconButton(systemName: "sidebar.left", label: "페이지 목록", isOn: model.showsSidebar) {
                model.showsSidebar.toggle()
            }
            IconButton(systemName: model.currentPage.bookmarked ? "bookmark.fill" : "bookmark", label: "책갈피",
                       isOn: model.currentPage.bookmarked) {
                model.toggleBookmark(at: model.currentPageIndex)
            }
            IconButton(systemName: "magnifyingglass", label: "검색과 목차") { showPanel = true }

            Spacer(minLength: 8)
            Button {
                newTitle = model.title
                renaming = true
            } label: {
                Text(model.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(NoteTheme.textPrimary)
            }
            .buttonStyle(.plain)
            syncPill
            Spacer(minLength: 8)

            IconButton(systemName: "arrow.uturn.backward", label: "실행 취소", isEnabled: model.canUndo) { model.undo() }
            IconButton(systemName: "arrow.uturn.forward", label: "다시 실행", isEnabled: model.canRedo) { model.redo() }
            Menu {
                Button { model.addPage(after: model.currentPageIndex) } label: { Label("뒤에 페이지 추가", systemImage: "plus") }
                Button { model.insertPage(before: model.currentPageIndex) } label: {
                    Label("앞에 페이지 추가", systemImage: "arrow.up.doc")
                }
                Button { model.duplicatePage(at: model.currentPageIndex) } label: {
                    Label("현재 페이지 복제", systemImage: "plus.square.on.square")
                }
                Button { showPaper = true } label: { Label("종이 바꾸기", systemImage: "doc.text") }
            } label: {
                Image(systemName: "doc.badge.plus").font(.system(size: 20))
                    .frame(width: NoteTheme.minTouch, height: NoteTheme.minTouch)
                    .foregroundStyle(NoteTheme.iconMuted)
            }
            .accessibilityLabel("페이지 추가")
            Menu {
                Button {
                    do { shareItem = ShareItem(url: try model.exportPDF()) } catch { model.lastError = error.localizedDescription }
                } label: { Label("PDF로 내보내기", systemImage: "doc.richtext") }
                Button {
                    if let url = model.exportPageImage(model.currentPageIndex) { shareItem = ShareItem(url: url) }
                } label: { Label("현재 페이지를 이미지로", systemImage: "photo") }
                Button {
                    exportPDFToLibrary()
                } label: { Label(model.ref.source.accountID != nil ? "NAS 폴더에 PDF 저장" : "노트 옆에 PDF 저장",
                                 systemImage: "externaldrive") }
            } label: {
                Image(systemName: "square.and.arrow.up").font(.system(size: 20))
                    .frame(width: NoteTheme.minTouch, height: NoteTheme.minTouch)
                    .foregroundStyle(NoteTheme.iconMuted)
            }
            .accessibilityLabel("내보내기")
            Menu {
                Button { newTitle = model.title; renaming = true } label: { Label("이름 변경", systemImage: "pencil") }
                Menu("표지") {
                    Button("표지 없음") { model.setCover(nil) }
                    ForEach(CoverStyle.palette, id: \.self) { hex in
                        Button(hex) { model.setCover(hex) }
                    }
                }
                if app.strokeClipboard != nil {
                    Button {
                        model.tools.select(.lasso)
                        NotificationCenter.default.post(name: .canvasPaste, object: nil)
                    } label: { Label("붙여넣기", systemImage: "doc.on.clipboard") }
                }
                Toggle(isOn: Binding(get: { !app.settings.pencilOnly }, set: { app.settings.pencilOnly = !$0 })) {
                    Label("손가락으로 그리기", systemImage: "hand.draw")
                }
                Toggle(isOn: $app.settings.tapGesturesUndo) {
                    Label("두 손가락 탭으로 실행 취소", systemImage: "hand.tap")
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 20))
                    .frame(width: NoteTheme.minTouch, height: NoteTheme.minTouch)
                    .foregroundStyle(NoteTheme.iconMuted)
            }
            .accessibilityLabel("더 보기")
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
        .background(NoteTheme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(NoteTheme.separator).frame(height: 1) }
    }

    private func exportPDFToLibrary() {
        do {
            let url = try model.exportPDF()
            let folder = RemotePath.parent(model.ref.path)
            let lib = app.library(model.ref.source)
            let name = FileNaming.split(RemotePath.name(model.ref.path)).base + ".pdf"
            let target = lib.url(for: RemotePath.join(folder, name))
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: url, to: target)
            app.refreshLibrary()
            app.localChange(in: model.ref.source)
        } catch {
            model.lastError = error.localizedDescription
        }
    }

    // MARK: Tool row (design: 56 pt)

    private var toolRow: some View {
        HStack(spacing: 4) {
            ForEach(EditorTool.allCases) { tool in
                IconButton(systemName: tool.symbol, label: tool.label, isOn: model.tools.tool == tool, size: 21) {
                    if model.tools.tool == tool, tool.inks || tool == .eraser {
                        showPenSettings = true
                    } else {
                        model.tools.select(tool)
                    }
                }
            }
            divider
            toolOptions
            Spacer(minLength: 8)
            if model.tools.tool.inks || model.tools.tool == .eraser {
                Button {
                    showPenSettings = true
                } label: {
                    HStack(spacing: 6) {
                        Text(penSummary).font(.system(size: 13)).foregroundStyle(NoteTheme.iconMuted)
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(NoteTheme.iconMuted)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(NoteTheme.surface, in: RoundedRectangle(cornerRadius: NoteTheme.Radius.control))
                    .overlay(RoundedRectangle(cornerRadius: NoteTheme.Radius.control).stroke(NoteTheme.controlBorder))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showPenSettings) {
                    PenSettingsView(model: model).frame(width: 340)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
        .background(NoteTheme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(NoteTheme.separator).frame(height: 1) }
        .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
    }

    private var divider: some View {
        Rectangle().fill(NoteTheme.separator).frame(width: 1, height: 28).padding(.horizontal, 8)
    }

    private var penSummary: String {
        switch model.tools.tool {
        case .highlighter: return "형광펜 · \(String(format: "%.0f", model.tools.highlighterWidth))pt"
        case .eraser:
            return model.tools.eraserMode == .precise ? "정밀 지우개" : "획 지우개"
        default:
            return "\(model.tools.penKind.label) · \(String(format: "%.1f", model.tools.penWidth / 72 * 25.4))mm"
        }
    }

    @ViewBuilder
    private var toolOptions: some View {
        switch model.tools.tool {
        case .pen, .highlighter, .text:
            colorSwatches
            if model.tools.tool != .text {
                divider
                widthPresets
            }
        case .eraser:
            Picker("지우개", selection: $model.tools.eraserMode) {
                Text("정밀").tag(EraserMode.precise)
                Text("획 전체").tag(EraserMode.stroke)
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            Toggle("형광펜만", isOn: $model.tools.eraseHighlighterOnly)
                .toggleStyle(.button)
                .font(.system(size: 13))
        case .lasso:
            hint("둘러서 선택 · 끌어서 이동 · 모서리로 크기 조절")
        case .image:
            hint("이미지를 넣을 곳을 탭하세요")
        case .laser:
            hint("발표할 때 가리키기 · 저장되지 않습니다")
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(NoteTheme.textSecondary).lineLimit(1)
    }

    private var colorSwatches: some View {
        let palette = model.tools.tool == .highlighter ? NoteTheme.highlighterColors : NoteTheme.penColors
        let colors = Array((palette + model.tools.customColors.prefix(2)).prefix(6))
        return HStack(spacing: 6) {
            ForEach(colors, id: \.self) { hex in
                let selected = model.tools.activeColor.uppercased() == hex.uppercased()
                Button {
                    model.tools.setColor(hex)
                } label: {
                    Circle().fill(Color(hex: hex))
                        .padding(3)
                        .frame(width: 36, height: 36)
                        .overlay(Circle().stroke(selected ? NoteTheme.accent : Color.clear, lineWidth: 2))
                        .overlay(Circle().stroke(NoteTheme.controlBorder.opacity(hex == "#FFFFFF" ? 1 : 0)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("색 \(hex)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            ColorPicker("색 더 보기", selection: Binding(get: { Color(hex: model.tools.activeColor) }, set: { color in
                let hex = UIColor(color).hexString
                model.tools.setColor(hex)
                model.tools.rememberCustomColor(hex)
            }), supportsOpacity: false)
            .labelsHidden()
            .frame(width: 36, height: 36)
        }
    }

    private var widthPresets: some View {
        let widths = model.tools.tool == .highlighter ? model.tools.highlighterWidths : model.tools.currentPenWidths
        let selected = model.tools.tool == .highlighter ? model.tools.highlighterWidthIndex : model.tools.penWidthIndex
        let maxWidth = widths.max() ?? 1
        return HStack(spacing: 4) {
            ForEach(Array(widths.enumerated()), id: \.offset) { index, width in
                Button {
                    if model.tools.tool == .highlighter {
                        model.tools.highlighterWidthIndex = index
                    } else {
                        model.tools.penWidthIndex = index
                    }
                } label: {
                    Capsule()
                        .fill(Color(hex: model.tools.activeColor))
                        .frame(width: 18, height: max(2, CGFloat(width / maxWidth) * 8))
                        .frame(width: 40, height: 40)
                        .background(selected == index ? NoteTheme.fieldFill : Color.clear,
                                    in: RoundedRectangle(cornerRadius: NoteTheme.Radius.control))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(["얇게", "보통", "굵게"][min(index, 2)])
                .accessibilityAddTraits(selected == index ? .isSelected : [])
            }
        }
    }

    // MARK: Overlays

    private var bottomOverlay: some View {
        HStack {
            if model.tools.tool == .pen && model.tools.snapShapes {
                HStack(spacing: 8) {
                    Image(systemName: "square.on.circle").foregroundStyle(NoteTheme.accent)
                    Text("그리고 멈추면 도형으로 · 다른 손가락을 대면 완벽한 도형")
                        .foregroundStyle(NoteTheme.iconMuted)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(NoteTheme.surface, in: Capsule())
                .overlay(Capsule().stroke(NoteTheme.separator))
            }
            Spacer()
            Text("\(model.currentPageIndex + 1) / \(model.pageCount)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Color.black.opacity(0.75), in: Capsule())
        }
        .padding(20)
        .allowsHitTesting(false)
    }
}

extension Notification.Name {
    static let canvasPaste = Notification.Name("NoteCanvasPaste")
}

struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Pen settings popover

struct PenSettingsView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch model.tools.tool {
                case .eraser:
                    eraserSettings
                case .highlighter:
                    highlighterSettings
                default:
                    penSettings
                }
            }
            .padding(20)
        }
        .frame(minHeight: 320)
    }

    private var penSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionLabel(text: "펜 종류")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                ForEach(BrushKind.pens, id: \.self) { kind in
                    Button {
                        model.tools.penKind = kind
                    } label: {
                        Text(kind.label)
                            .font(.system(size: 14, weight: model.tools.penKind == kind ? .semibold : .regular))
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .foregroundStyle(model.tools.penKind == kind ? NoteTheme.accent : NoteTheme.textPrimary)
                            .background(model.tools.penKind == kind ? NoteTheme.accentSoft : NoteTheme.fieldFill,
                                        in: RoundedRectangle(cornerRadius: NoteTheme.Radius.control))
                    }
                    .buttonStyle(.plain)
                }
            }
            widthSlider(value: model.tools.penWidth, range: 0.3...10) { model.tools.setWidth($0, at: model.tools.penWidthIndex) }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("글씨 보정").font(NoteTheme.Fonts.body)
                    Spacer()
                    Text(model.tools.correction == 0 ? "끔" : "\(Int(model.tools.correction * 100))%")
                        .font(NoteTheme.Fonts.caption).foregroundStyle(NoteTheme.textSecondary)
                }
                Slider(value: $model.tools.correction, in: 0...1)
                Text("흔들린 선을 펴고 ㄱ·ㄴ·ㅁ의 모서리를 맞춥니다. 필체는 그대로 둡니다.")
                    .font(NoteTheme.Fonts.caption).foregroundStyle(NoteTheme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("손떨림 보정").font(NoteTheme.Fonts.body)
                    Spacer()
                    Text(model.tools.stabilizer == 0 ? "끔" : "\(Int(model.tools.stabilizer))ms")
                        .font(NoteTheme.Fonts.caption).foregroundStyle(NoteTheme.textSecondary)
                }
                Slider(value: $model.tools.stabilizer, in: 0...60, step: 5)
            }
            Toggle("그리고 멈추면 도형으로", isOn: $model.tools.snapShapes).font(NoteTheme.Fonts.body)
        }
    }

    private var highlighterSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            widthSlider(value: model.tools.highlighterWidth, range: 4...30) {
                model.tools.setWidth($0, at: model.tools.highlighterWidthIndex)
            }
            Toggle("멈추면 직선으로", isOn: $model.tools.highlighterStraight).font(NoteTheme.Fonts.body)
            Text("형광펜은 글씨 아래에 칠해져 글자가 흐려지지 않습니다.")
                .font(NoteTheme.Fonts.caption).foregroundStyle(NoteTheme.textSecondary)
        }
    }

    private var eraserSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("방식", selection: $model.tools.eraserMode) {
                Text("정밀 지우개").tag(EraserMode.precise)
                Text("획 지우개").tag(EraserMode.stroke)
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("크기").font(NoteTheme.Fonts.body)
                    Spacer()
                    Text("\(Int(model.tools.eraserSize))pt").font(NoteTheme.Fonts.caption)
                        .foregroundStyle(NoteTheme.textSecondary)
                }
                Slider(value: $model.tools.eraserSize, in: 4...60, step: 1)
            }
            Toggle("형광펜만 지우기", isOn: $model.tools.eraseHighlighterOnly).font(NoteTheme.Fonts.body)
        }
    }

    private func widthSlider(value: Double, range: ClosedRange<Double>, set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("굵기").font(NoteTheme.Fonts.body)
                Spacer()
                Text(String(format: "%.1fpt · %.2fmm", value, value / 72 * 25.4))
                    .font(NoteTheme.Fonts.caption).foregroundStyle(NoteTheme.textSecondary)
            }
            Slider(value: Binding(get: { value }, set: set), in: range)
        }
    }
}

// MARK: - Page sidebar

struct PageSidebar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(Array(model.document.pages.enumerated()), id: \.element.id) { index, page in
                        thumbnail(page, index: index)
                            .id(page.id)
                    }
                    Button {
                        model.addPage(after: model.pageCount - 1)
                    } label: {
                        Image(systemName: "plus").font(.system(size: 18, weight: .semibold))
                            .frame(width: 84, height: 44)
                            .foregroundStyle(NoteTheme.textSecondary)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(NoteTheme.controlBorder,
                                                                             style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("페이지 추가")
                }
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: model.currentPageIndex) { _, index in
                if let id = model.document.pages[safe: index]?.id {
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .background(NoteTheme.background)
        .overlay(alignment: .trailing) { Rectangle().fill(NoteTheme.separator).frame(width: 1) }
    }

    private func thumbnail(_ page: NotebookPage, index: Int) -> some View {
        let selected = index == model.currentPageIndex
        let aspect = CGFloat(page.size.height / max(page.size.width, 1))
        _ = model.thumbnailRevision
        return VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = model.thumbnail(for: page) {
                        Image(uiImage: image).resizable()
                    } else {
                        Rectangle().fill(Color.white)
                    }
                }
                .frame(width: 84, height: 84 * aspect)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: selected ? 4 : 3)
                    .stroke(selected ? NoteTheme.accent : NoteTheme.separator, lineWidth: selected ? 2 : 1))
                .shadow(color: selected ? NoteTheme.accentSoft : .clear, radius: 0, x: 0, y: 0)
                if page.bookmarked {
                    Image(systemName: "bookmark.fill").font(.system(size: 12)).foregroundStyle(NoteTheme.danger)
                        .padding(4)
                }
            }
            Text("\(index + 1)").font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? NoteTheme.accent : NoteTheme.textSecondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.go(to: index) }
        .contextMenu {
            Button { model.insertPage(before: index) } label: { Label("앞에 페이지 추가", systemImage: "arrow.up.doc") }
            Button { model.addPage(after: index) } label: { Label("뒤에 페이지 추가", systemImage: "arrow.down.doc") }
            Button { model.duplicatePage(at: index) } label: { Label("복제", systemImage: "plus.square.on.square") }
            Button { model.toggleBookmark(at: index) } label: {
                Label(page.bookmarked ? "책갈피 해제" : "책갈피", systemImage: "bookmark")
            }
            if model.pageCount > 1 {
                Button(role: .destructive) { model.deletePage(at: index) } label: { Label("페이지 삭제", systemImage: "trash") }
            }
        }
        .draggable(page.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let idString = items.first, let from = model.document.pages.firstIndex(where: { $0.id.uuidString == idString }),
                  from != index else { return false }
            model.movePage(from: IndexSet(integer: from), to: from < index ? index + 1 : index)
            return true
        }
        .accessibilityLabel("\(index + 1)쪽")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Search, outline, bookmarks

struct EditorPanel: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var tab = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("", selection: $tab) {
                    Text("목차").tag(0)
                    Text("책갈피").tag(1)
                    if model.pdfKitDocument != nil { Text("PDF 검색").tag(2) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                List {
                    switch tab {
                    case 0:
                        let outline = model.outline()
                        if outline.isEmpty {
                            Text(model.pdf == nil ? "PDF로 만든 노트에서 목차를 볼 수 있습니다." : "이 PDF에는 목차가 없습니다.")
                                .foregroundStyle(NoteTheme.textSecondary)
                        }
                        ForEach(outline) { entry in
                            Button {
                                model.go(to: entry.pageIndex)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(entry.title).padding(.leading, CGFloat(entry.depth) * 16)
                                    Spacer()
                                    Text("\(entry.pageIndex + 1)").foregroundStyle(NoteTheme.textSecondary)
                                }
                            }
                        }
                    case 1:
                        if model.bookmarkedIndices.isEmpty {
                            Text("책갈피한 페이지가 없습니다.").foregroundStyle(NoteTheme.textSecondary)
                        }
                        ForEach(model.bookmarkedIndices, id: \.self) { index in
                            Button("\(index + 1)쪽") {
                                model.go(to: index)
                                dismiss()
                            }
                        }
                    default:
                        ForEach(model.searchResults) { hit in
                            Button {
                                model.show(hit)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hit.context).lineLimit(2)
                                    Text("\(hit.pageIndex + 1)쪽").font(NoteTheme.Fonts.caption)
                                        .foregroundStyle(NoteTheme.textSecondary)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
            .searchable(text: $query, prompt: "PDF에서 찾기")
            .onSubmit(of: .search) {
                tab = 2
                model.search(query)
            }
            .navigationTitle("탐색")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } }
            }
        }
    }
}

/// Change the paper of this page or the whole notebook.
struct PaperSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var template: PaperTemplate = .ruled
    @State private var color: PaperColor = .white
    @State private var allPages = false

    var body: some View {
        NavigationStack {
            Form {
                Section("종이") {
                    PaperTemplateGrid(selection: $template, color: color)
                        .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                }
                Section("색") {
                    Picker("종이 색", selection: $color) {
                        ForEach(PaperColor.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Toggle("모든 페이지에 적용", isOn: $allPages)
                }
            }
            .navigationTitle("종이 바꾸기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("적용") {
                        model.setPaper(PaperStyle(template: template, color: color), forAll: allPages)
                        dismiss()
                    }
                }
            }
            .onAppear {
                template = model.currentPage.paper.template
                color = model.currentPage.paper.color
            }
        }
    }
}
#endif
