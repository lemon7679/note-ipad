#if canImport(UIKit)
import NoteKit
import SwiftUI
import UniformTypeIdentifiers

enum NewItemMode: String, CaseIterable, Identifiable {
    case notebook = "빈 노트"
    case pdf = "PDF 가져오기"
    case folder = "폴더"
    var id: String { rawValue }
}

/// "새로 만들기" sheet (design: NewNotebook artboard).
struct NewItemSheet: View {
    let location: LibraryLocation
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode: NewItemMode
    @State private var title = ""
    @State private var cover: String? = CoverStyle.palette[0]
    @State private var template: PaperTemplate = .ruled
    @State private var paperColor: PaperColor = .white
    @State private var size: PageSizePreset = .a4
    @State private var landscape = false
    @State private var importing = false

    init(location: LibraryLocation, initialMode: NewItemMode) {
        self.location = location
        _mode = State(initialValue: initialMode)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .notebook: notebookForm
                case .pdf: pdfForm
                case .folder: folderForm
                }
            }
            .background(NoteTheme.background)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .principal) {
                    Picker("만들기 종류", selection: $mode) {
                        ForEach(NewItemMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 320)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("만들기") { create() }
                        .fontWeight(.semibold)
                        .disabled(mode == .pdf)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            template = app.settings.defaultTemplate
            paperColor = app.settings.defaultPaperColor
            size = app.settings.defaultSize
            landscape = app.settings.defaultLandscape
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                dismiss()
                app.importPDF(from: url, into: location, annotate: true)
            }
        }
    }

    private func create() {
        switch mode {
        case .notebook:
            let pageSize = landscape ? size.size.landscape : size.size.portrait
            dismiss()
            app.createNotebook(in: location, title: title.trimmingCharacters(in: .whitespaces), coverHex: cover,
                               paper: PaperStyle(template: template, color: paperColor), size: pageSize)
        case .folder:
            app.createFolder(named: title.isEmpty ? "새 폴더" : title, in: location)
            dismiss()
        case .pdf:
            importing = true
        }
    }

    private var notebookForm: some View {
        HStack(spacing: 0) {
            VStack(spacing: 18) {
                Group {
                    if let cover {
                        NotebookCover(title: title.isEmpty ? "새 노트" : title, colorHex: cover)
                    } else {
                        PaperPreview(paper: PaperStyle(template: template, color: paperColor),
                                     size: landscape ? size.size.landscape : size.size.portrait)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .shadow(color: .black.opacity(0.12), radius: 8, y: 6)
                    }
                }
                .frame(width: 150, height: 206)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 8), count: 4), spacing: 8) {
                    ForEach(CoverStyle.palette + ["none"], id: \.self) { hex in
                        let value: String? = hex == "none" ? nil : hex
                        let selected = cover == value
                        Button {
                            cover = value
                        } label: {
                            Circle()
                                .fill(value.map { Color(hex: $0) } ?? Color.white)
                                .overlay(Circle().stroke(NoteTheme.controlBorder, lineWidth: value == nil ? 1 : 0))
                                .padding(2)
                                .frame(width: 32, height: 32)
                                .overlay(Circle().stroke(selected ? NoteTheme.textPrimary : Color.clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(value == nil ? "표지 없음" : "표지 색 \(hex)")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            .padding(20)
            .frame(width: 230)
            .frame(maxHeight: .infinity)
            .background(NoteTheme.background)
            .overlay(alignment: .trailing) { Rectangle().fill(NoteTheme.separator).frame(width: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "제목")
                        TextField("새 노트", text: $title)
                            .font(.system(size: 16))
                            .padding(.horizontal, 14)
                            .frame(height: 44)
                            .background(NoteTheme.surface, in: RoundedRectangle(cornerRadius: NoteTheme.Radius.control))
                            .overlay(RoundedRectangle(cornerRadius: NoteTheme.Radius.control).stroke(NoteTheme.controlBorder))
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: "종이")
                        PaperTemplateGrid(selection: $template, color: paperColor)
                    }
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel(text: "크기")
                            Picker("크기", selection: $size) {
                                ForEach([PageSizePreset.a4, .b5, .letter, .a5]) { Text($0.displayName).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel(text: "방향")
                            Picker("방향", selection: $landscape) {
                                Text("세로").tag(false)
                                Text("가로").tag(true)
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "종이 색")
                        Picker("종이 색", selection: $paperColor) {
                            ForEach(PaperColor.allCases) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    locationRow
                }
                .padding(24)
            }
        }
    }

    private var locationRow: some View {
        HStack(spacing: 12) {
            Image(systemName: location.source.accountID != nil ? "server.rack" : "ipad")
                .font(.system(size: 20)).foregroundStyle(NoteTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("저장 위치").font(NoteTheme.Fonts.caption).foregroundStyle(NoteTheme.textSecondary)
                Text(([app.displayName(location.source)] + RemotePath.components(location.folder)).joined(separator: " › "))
                    .font(.system(size: 15, weight: .medium)).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 60)
        .background(NoteTheme.background, in: RoundedRectangle(cornerRadius: NoteTheme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: NoteTheme.Radius.card).stroke(NoteTheme.separator))
    }

    private var pdfForm: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.richtext").font(.system(size: 44)).foregroundStyle(NoteTheme.accent)
            Text("PDF를 가져와 바로 필기합니다").font(NoteTheme.Fonts.sheetTitle)
            Text("원본은 노트 안에 그대로 보관되고, 필기는 페이지마다 따로 저장되어 NAS로 빠르게 동기화됩니다.")
                .font(NoteTheme.Fonts.body).foregroundStyle(NoteTheme.textSecondary).multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("PDF 선택") { importing = true }.buttonStyle(PrimaryButtonStyle())
            locationRow.frame(maxWidth: 420)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var folderForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel(text: "폴더 이름")
            TextField("새 폴더", text: $title)
                .font(.system(size: 16))
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(NoteTheme.surface, in: RoundedRectangle(cornerRadius: NoteTheme.Radius.control))
                .overlay(RoundedRectangle(cornerRadius: NoteTheme.Radius.control).stroke(NoteTheme.controlBorder))
            locationRow
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: 520)
    }
}

/// Grid of paper templates with live previews.
struct PaperTemplateGrid: View {
    @Binding var selection: PaperTemplate
    var color: PaperColor = .white

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
            ForEach([PaperTemplate.blank, .ruled, .grid, .dotted, .cornell, .music, .narrowRuled]) { template in
                let selected = selection == template
                Button {
                    selection = template
                } label: {
                    VStack(spacing: 6) {
                        PaperPreview(paper: PaperStyle(template: template, color: color),
                                     size: PageSize(width: 300, height: 220))
                            .frame(height: 92)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(selected ? NoteTheme.accent : NoteTheme.controlBorder, lineWidth: selected ? 2 : 1))
                            .background(RoundedRectangle(cornerRadius: 10).stroke(selected ? NoteTheme.accentSoft : .clear,
                                                                                  lineWidth: 6))
                        Text(template.displayName)
                            .font(.system(size: 13, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? NoteTheme.accent : NoteTheme.iconMuted)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// Paper drawn with the same renderer the canvas uses.
struct PaperPreview: View {
    let paper: PaperStyle
    let size: PageSize

    var body: some View {
        Canvas { context, canvasSize in
            context.withCGContext { cg in
                cg.setFillColor(PaperRenderer.color(paper).cgColor)
                cg.fill(CGRect(origin: .zero, size: canvasSize))
                let scale = canvasSize.width / CGFloat(size.width)
                cg.scaleBy(x: scale, y: scale)
                let visible = PageSize(width: size.width, height: Double(canvasSize.height / scale))
                PaperRenderer.draw(paper, size: visible, in: cg)
            }
        }
    }
}

/// Folder picker for "이동".
struct MoveSheet: View {
    let source: LibrarySource
    let item: LibraryItem
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                let folders = ["/"] + app.library(source).allFolders()
                ForEach(folders, id: \.self) { folder in
                    let blocked = RemotePath.isAncestor(item.path, of: folder) || RemotePath.parent(item.path) == folder
                    Button {
                        app.move(LibraryRef(source: source, path: item.path), to: folder)
                        dismiss()
                    } label: {
                        Label(folder == "/" ? app.displayName(source) : RemotePath.name(folder), systemImage: "folder")
                            .padding(.leading, CGFloat(max(RemotePath.depth(folder) - 1, 0)) * 18)
                    }
                    .disabled(blocked)
                }
            }
            .navigationTitle("‘\(item.displayName)’ 이동")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } } }
        }
    }
}

/// Recents and favorites across all sources.
struct CollectionView: View {
    enum Kind { case recents, favorites }
    let kind: Kind
    @EnvironmentObject private var app: AppModel

    var body: some View {
        let refs: [LibraryRef] = kind == .recents ? app.recents.map(\.ref)
            : app.favorites.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let entries = app.existingItems(refs).map { RefItem(ref: $0.0, item: $0.1) }
        VStack(spacing: 0) {
            HStack {
                Text(kind == .recents ? "최근 문서" : "즐겨찾기").font(.system(size: 22, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, NoteTheme.Space.page)
            .frame(height: 64)
            .overlay(alignment: .bottom) { Rectangle().fill(NoteTheme.separator).frame(height: 1) }
            ScrollView {
                if entries.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: kind == .recents ? "clock" : "star").font(.system(size: 40))
                            .foregroundStyle(NoteTheme.offline)
                        Text(kind == .recents ? "최근에 연 문서가 없습니다" : "즐겨찾기한 문서가 없습니다")
                            .font(NoteTheme.Fonts.sheetTitle)
                    }
                    .padding(.top, 100)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 22, alignment: .top)], spacing: 24) {
                    ForEach(entries) { entry in
                        let ref = entry.ref
                        let item = entry.item
                        VStack(alignment: .leading, spacing: 4) {
                            DocumentCard(item: item, source: ref.source)
                                .onTapGesture { app.open(item, in: ref.source) }
                            Text(app.displayName(ref.source)).font(NoteTheme.Fonts.caption)
                                .foregroundStyle(NoteTheme.textTertiary)
                        }
                        .contextMenu {
                            Button { app.toggleFavorite(ref) } label: {
                                Label(app.isFavorite(ref) ? "즐겨찾기 해제" : "즐겨찾기", systemImage: "star")
                            }
                        }
                    }
                }
                .padding(NoteTheme.Space.page)
            }
        }
        .background(NoteTheme.background)
        .id(app.libraryRevision)
    }
}

private struct RefItem: Identifiable {
    let ref: LibraryRef
    let item: LibraryItem
    var id: String { ref.id }
}

/// Deleted items of every source, restorable.
struct TrashView: View {
    @EnvironmentObject private var app: AppModel
    @State private var confirmEmpty = false

    private var sources: [LibrarySource] { [.local] + app.accounts.map { .account($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("휴지통").font(.system(size: 22, weight: .semibold))
                Spacer()
                Button("비우기", role: .destructive) { confirmEmpty = true }
            }
            .padding(.horizontal, NoteTheme.Space.page)
            .frame(height: 64)
            .overlay(alignment: .bottom) { Rectangle().fill(NoteTheme.separator).frame(height: 1) }
            List {
                ForEach(sources, id: \.self) { source in
                    let entries = app.trash(source).entries()
                    if !entries.isEmpty {
                        Section(app.displayName(source)) {
                            ForEach(entries) { entry in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.displayName).font(NoteTheme.Fonts.body)
                                        Text("\(RemotePath.parent(entry.originalPath)) · \(entry.deletedAt.libraryLabel)")
                                            .font(NoteTheme.Fonts.caption).foregroundStyle(NoteTheme.textSecondary)
                                    }
                                    Spacer()
                                    Button("복원") { app.restore(entry, in: source) }.buttonStyle(SecondaryButtonStyle())
                                }
                                .swipeActions {
                                    Button("영구 삭제", role: .destructive) {
                                        try? app.trash(source).remove(entry)
                                        app.refreshLibrary()
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .id(app.libraryRevision)
        }
        .background(NoteTheme.background)
        .confirmationDialog("휴지통을 비울까요?", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("모두 영구 삭제", role: .destructive) {
                for source in sources { try? app.trash(source).empty() }
                app.refreshLibrary()
            }
        } message: {
            Text("되돌릴 수 없습니다.")
        }
    }
}
#endif
