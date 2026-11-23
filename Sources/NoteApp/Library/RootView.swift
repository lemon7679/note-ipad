#if canImport(UIKit)
import NoteKit
import SwiftUI

enum SidebarItem: Hashable {
    case recents
    case favorites
    case trash
    case source(LibrarySource)
}

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: SidebarItem? = .source(.local)
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var connecting: NASAccount?
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(selection: $selection, connecting: $connecting, showSettings: $showSettings)
                .navigationSplitViewColumnWidth(min: 260, ideal: 280, max: 320)
                .toolbar(.hidden, for: .navigationBar)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .tint(NoteTheme.accent)
        .fullScreenCover(item: $app.openDocument) { document in
            switch document.kind {
            case .notebook: NotebookEditorHost(document: document).environmentObject(app)
            case .pdf: PDFReaderView(document: document).environmentObject(app)
            }
        }
        .sheet(item: $connecting) { account in
            NASConnectView(account: account).environmentObject(app)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(app)
        }
        .alert("알림", isPresented: Binding(get: { app.errorMessage != nil }, set: { if !$0 { app.errorMessage = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(app.errorMessage ?? "")
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: app.becameActive()
            case .background: app.enteredBackground()
            default: break
            }
        }
        .onChange(of: app.accounts.map(\.id)) { _, ids in
            if case .source(.account(let id)) = selection, !ids.contains(id) { selection = .source(.local) }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .source(.local) {
        case .source(let source):
            LibraryBrowser(source: source).id(source)
        case .recents:
            CollectionView(kind: .recents)
        case .favorites:
            CollectionView(kind: .favorites)
        case .trash:
            TrashView()
        }
    }
}

/// Folder navigation inside one library source.
struct LibraryBrowser: View {
    let source: LibrarySource
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            LibraryView(location: LibraryLocation(source: source, folder: "/"), path: $path)
                .navigationDestination(for: String.self) { folder in
                    LibraryView(location: LibraryLocation(source: source, folder: folder), path: $path)
                }
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var app: AppModel
    @Binding var selection: SidebarItem?
    @Binding var connecting: NASAccount?
    @Binding var showSettings: Bool
    @State private var browsing: NASAccount?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 9).fill(NoteTheme.textPrimary)
                        .frame(width: 32, height: 32)
                        .overlay(Image(systemName: "pencil.tip").font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(NoteTheme.background))
                    Text("Note").font(.system(size: 20, weight: .bold))
                }
                Spacer()
                IconButton(systemName: "slider.horizontal.3", label: "설정") { showSettings = true }
            }
            .padding(.horizontal, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 2) {
                        SectionLabel(text: "라이브러리").padding(.horizontal, 6).padding(.bottom, 4)
                        row(.recents, symbol: "clock", title: "최근 문서")
                        row(.favorites, symbol: "star", title: "즐겨찾기")
                        row(.trash, symbol: "trash", title: "휴지통")
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        SectionLabel(text: "저장소").padding(.horizontal, 6).padding(.bottom, 4)
                        row(.source(.local), symbol: "ipad", title: "이 iPad", subtitle: nil, trailing: AnyView(EmptyView()))
                        ForEach(app.accounts) { account in
                            accountRow(account)
                        }
                        Button {
                            connecting = NASAccount(name: "", kind: .synology, syncFolder: "/home/Notes")
                        } label: {
                            Label("저장소 연결", systemImage: "plus")
                                .font(.system(size: 15, weight: .medium))
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .padding(.horizontal, 10)
                                .foregroundStyle(NoteTheme.accent)
                                .overlay(RoundedRectangle(cornerRadius: NoteTheme.Radius.control)
                                    .stroke(NoteTheme.controlBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 6)
                    }
                }
            }
            syncCard
        }
        .padding(.horizontal, 14)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(NoteTheme.sidebar)
        .sheet(item: $browsing) { account in
            RemoteBrowserView(account: account).environmentObject(app)
        }
    }

    private func row(_ item: SidebarItem, symbol: String, title: String, subtitle: String? = nil,
                     trailing: AnyView = AnyView(EmptyView())) -> some View {
        let selected = selection == item
        return Button {
            selection = item
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 18))
                    .foregroundStyle(selected ? NoteTheme.accent : NoteTheme.textSecondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 15, weight: selected ? .semibold : .regular))
                        .foregroundStyle(NoteTheme.textPrimary)
                    if let subtitle {
                        Text(subtitle).font(NoteTheme.Fonts.caption).foregroundStyle(NoteTheme.textSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                trailing
            }
            .padding(.horizontal, 10)
            .frame(minHeight: subtitle == nil ? 40 : 52)
            .background(selected ? NoteTheme.surface : Color.clear, in: RoundedRectangle(cornerRadius: NoteTheme.Radius.control))
            .shadow(color: selected ? .black.opacity(0.08) : .clear, radius: 1, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func accountRow(_ account: NASAccount) -> some View {
        let status = app.status(account.id)
        let conflicts = app.conflicts[account.id]?.count ?? 0
        let trailing: AnyView
        if conflicts > 0 {
            trailing = AnyView(StatusPill(text: "충돌 \(conflicts)", foreground: NoteTheme.conflict, background: NoteTheme.conflictSoft))
        } else if status.isSyncing {
            trailing = AnyView(ProgressView().controlSize(.small))
        } else {
            let color: Color
            switch status.phase {
            case .error: color = NoteTheme.danger
            case .offline, .waitingForWiFi: color = NoteTheme.offline
            default: color = status.lastSync == nil ? NoteTheme.offline : NoteTheme.synced
            }
            trailing = AnyView(Circle().fill(color).frame(width: 8, height: 8).accessibilityLabel(status.summary))
        }
        return row(.source(.account(account.id)), symbol: account.kind.symbolName, title: account.name,
                   subtitle: account.displayAddress, trailing: trailing)
            .contextMenu {
                Button { app.sync(account.id, manual: true) } label: { Label("지금 동기화", systemImage: "arrow.triangle.2.circlepath") }
                if account.kind != .filesFolder {
                    Button { browsing = account } label: { Label("NAS 전체 보기", systemImage: "externaldrive") }
                }
                Button { connecting = account } label: { Label("연결 설정", systemImage: "gearshape") }
                Button(role: .destructive) { app.removeAccount(account.id) } label: {
                    Label("연결 해제", systemImage: "xmark.circle")
                }
            }
    }

    /// Bottom card (design: "Home NAS 동기화됨 · 2분 전").
    @ViewBuilder
    private var syncCard: some View {
        if let account = currentAccount ?? app.accounts.first {
            let status = app.status(account.id)
            SyncSummaryCard(account: account, status: status, conflicts: app.conflicts[account.id]?.count ?? 0) {
                app.sync(account.id, manual: true)
            }
        }
    }

    private var currentAccount: NASAccount? {
        if case .source(.account(let id)) = selection { return app.account(id) }
        return nil
    }
}

struct SyncSummaryCard: View {
    let account: NASAccount
    let status: AccountSyncStatus
    let conflicts: Int
    let syncNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(color)
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Button(action: syncNow) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 14, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(NoteTheme.accent)
                .disabled(status.isSyncing)
                .accessibilityLabel("지금 동기화")
            }
            Text(status.summary).font(NoteTheme.Fonts.caption).foregroundStyle(NoteTheme.textSecondary).lineLimit(2)
            if status.isSyncing {
                ProgressView(value: status.progress?.fraction ?? 0).tint(NoteTheme.accent)
            }
            if conflicts > 0 {
                Text("충돌 \(conflicts)건 — 동기화 센터에서 정리하세요")
                    .font(NoteTheme.Fonts.caption).foregroundStyle(NoteTheme.conflict)
            }
        }
        .padding(14)
        .background(NoteTheme.surface, in: RoundedRectangle(cornerRadius: NoteTheme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: NoteTheme.Radius.card).stroke(NoteTheme.separator))
    }

    private var icon: String {
        switch status.phase {
        case .error: return "exclamationmark.circle"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .offline, .waitingForWiFi: return "wifi.slash"
        case .idle: return conflicts > 0 ? "exclamationmark.triangle" : "checkmark.circle"
        }
    }

    private var color: Color {
        switch status.phase {
        case .error: return NoteTheme.danger
        case .syncing: return NoteTheme.accent
        case .offline, .waitingForWiFi: return NoteTheme.offline
        case .idle: return conflicts > 0 ? NoteTheme.conflict : NoteTheme.synced
        }
    }

    private var title: String {
        switch status.phase {
        case .syncing: return "\(account.name) 동기화 중"
        case .error: return "\(account.name) 동기화 오류"
        case .offline: return "\(account.name) 오프라인"
        case .waitingForWiFi: return "\(account.name) Wi-Fi 대기"
        case .idle: return status.lastSync == nil ? account.name : "\(account.name) 동기화됨"
        }
    }
}
#endif
