#if canImport(UIKit)
import NoteKit
import SwiftUI

/// Lists one folder of a NAS (online). Shared by the folder picker and the NAS browser.
@MainActor
final class RemoteFolderModel: ObservableObject {
    @Published var items: [RemoteItem] = []
    @Published var loading = false
    @Published var error: String?
    let fileSystem: RemoteFileSystem?

    init(fileSystem: RemoteFileSystem?) {
        self.fileSystem = fileSystem
    }

    func load(_ path: String, foldersOnly: Bool) async {
        guard let fs = fileSystem else {
            error = "연결 정보를 확인해 주세요."
            return
        }
        loading = true
        defer { loading = false }
        do {
            var list: [RemoteItem]
            if path == "/", let synology = fs as? SynologyClient {
                list = try await synology.listShares()
            } else {
                list = try await fs.list(path)
            }
            if foldersOnly { list = list.filter(\.isDirectory) }
            items = list.sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Picks the NAS folder that becomes the account's synced notes folder.
struct RemoteFolderPicker: View {
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: RemoteFolderModel
    @State private var path: [String] = []
    @State private var newFolderName = ""
    @State private var creating = false
    private let startFolder: String

    init(account: NASAccount, password: String, otp: String?, onPick: @escaping (String) -> Void) {
        self.onPick = onPick
        let store = InMemoryCredentialStore()
        let keychain = KeychainCredentialStore()
        store.setSecret(password.isEmpty ? keychain.secret(for: account.passwordKey) : password, for: account.passwordKey)
        store.setSecret(keychain.secret(for: account.deviceTokenKey), for: account.deviceTokenKey)
        let fs = try? NASConnection.makeFileSystem(for: account, credentials: store, otpCode: otp)
        _model = StateObject(wrappedValue: RemoteFolderModel(fileSystem: fs))
        // Synology starts at the list of shared folders; WebDAV at the endpoint root.
        startFolder = "/"
    }

    private var current: String { path.last ?? startFolder }

    var body: some View {
        NavigationStack {
            List {
                if let error = model.error {
                    Text(error).foregroundStyle(NoteTheme.danger)
                }
                if path.count > 0 {
                    Button {
                        path.removeLast()
                    } label: {
                        Label("상위 폴더", systemImage: "arrow.turn.left.up")
                    }
                }
                ForEach(model.items) { item in
                    Button {
                        path.append(item.path)
                    } label: {
                        Label(item.name, systemImage: "folder").foregroundStyle(NoteTheme.textPrimary)
                    }
                }
                if model.items.isEmpty && !model.loading && model.error == nil {
                    Text("하위 폴더가 없습니다.").foregroundStyle(NoteTheme.textSecondary)
                }
            }
            .overlay { if model.loading { ProgressView() } }
            .navigationTitle(current == "/" ? "NAS" : RemotePath.name(current))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Image(systemName: "folder.badge.plus") }
                        .disabled(current == "/" && model.fileSystem is SynologyClient)
                        .accessibilityLabel("새 폴더")
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("이 폴더 사용: \(current)") {
                        onPick(current)
                        dismiss()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(current == "/" && model.fileSystem is SynologyClient)
                }
            }
            .task(id: current) { await model.load(current, foldersOnly: true) }
            .alert("새 폴더", isPresented: $creating) {
                TextField("Notes", text: $newFolderName)
                Button("취소", role: .cancel) {}
                Button("만들기") {
                    let name = FileNaming.sanitize(newFolderName, fallback: "Notes")
                    let target = RemotePath.join(current, name)
                    Task {
                        do {
                            try await model.fileSystem?.createDirectory(target)
                            path.append(target)
                        } catch {
                            model.error = error.localizedDescription
                        }
                    }
                }
            }
        }
    }
}

/// Browses the whole NAS (beyond the synced folder): open PDFs, copy them into the library.
struct RemoteBrowserView: View {
    let account: NASAccount
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: RemoteFolderModel
    @State private var path: [String] = []
    @State private var downloading: String?

    init(account: NASAccount) {
        self.account = account
        let fs = try? NASConnection.makeFileSystem(for: account, credentials: KeychainCredentialStore())
        _model = StateObject(wrappedValue: RemoteFolderModel(fileSystem: fs))
    }

    private var current: String { path.last ?? "/" }

    var body: some View {
        NavigationStack {
            List {
                if let error = model.error {
                    Text(error).foregroundStyle(NoteTheme.danger)
                }
                if !path.isEmpty {
                    Button { path.removeLast() } label: { Label("상위 폴더", systemImage: "arrow.turn.left.up") }
                }
                ForEach(model.items) { item in
                    row(item)
                }
            }
            .overlay { if model.loading { ProgressView() } }
            .navigationTitle(current == "/" ? account.name : RemotePath.name(current))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } }
            }
            .task(id: current) { await model.load(current, foldersOnly: false) }
        }
    }

    @ViewBuilder
    private func row(_ item: RemoteItem) -> some View {
        let inSync = RemotePath.isAncestor(account.syncFolder, of: item.path)
        Button {
            if item.isDirectory {
                path.append(item.path)
            } else {
                Task { await open(item) }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.isDirectory ? "folder" : icon(for: item))
                    .foregroundStyle(item.isDirectory ? NoteTheme.accent : NoteTheme.textSecondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).foregroundStyle(NoteTheme.textPrimary)
                    HStack(spacing: 6) {
                        if let modified = item.modified { Text(modified.libraryLabel) }
                        if !item.isDirectory { Text(item.size.byteLabel) }
                        if inSync { Text("· 동기화 폴더") }
                    }
                    .font(NoteTheme.Fonts.caption)
                    .foregroundStyle(NoteTheme.textSecondary)
                }
                Spacer()
                if downloading == item.path { ProgressView().controlSize(.small) }
            }
        }
        .disabled(downloading != nil)
        .contextMenu {
            if !item.isDirectory && RemotePath.pathExtension(item.path) == "pdf" {
                Button {
                    Task { await importToLibrary(item) }
                } label: { Label("노트 폴더로 가져오기", systemImage: "square.and.arrow.down") }
            }
        }
    }

    private func icon(for item: RemoteItem) -> String {
        switch RemotePath.pathExtension(item.path) {
        case "pdf": return "doc.richtext"
        case FileNaming.notebookExtension: return "book.closed"
        case "png", "jpg", "jpeg", "heic": return "photo"
        default: return "doc"
        }
    }

    private func download(_ item: RemoteItem) async -> URL? {
        guard let fs = model.fileSystem else { return nil }
        downloading = item.path
        defer { downloading = nil }
        let dest = AppPaths.remoteDownloads.appendingPathComponent(account.id.uuidString)
            .appendingRemotePath(item.path)
        do {
            try await fs.download(item.path, to: dest)
            return dest
        } catch {
            model.error = error.localizedDescription
            return nil
        }
    }

    private func open(_ item: RemoteItem) async {
        guard RemotePath.pathExtension(item.path) == "pdf" else {
            model.error = "PDF만 바로 열 수 있습니다. 다른 파일은 노트 폴더로 옮겨 사용하세요."
            return
        }
        guard let url = await download(item) else { return }
        dismiss()
        app.openDocument = OpenDocument(ref: LibraryRef(source: .account(account.id), path: item.path), url: url,
                                        kind: .pdf, isRemoteCopy: true)
    }

    private func importToLibrary(_ item: RemoteItem) async {
        guard let url = await download(item) else { return }
        app.importRemoteCopy(url, into: LibraryLocation(source: .account(account.id), folder: "/"))
    }
}
#endif
