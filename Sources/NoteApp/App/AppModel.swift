#if canImport(UIKit)
import Foundation
import NoteKit
import SwiftUI
import UIKit

/// App-wide state: library sources, NAS accounts and their sync, favorites,
/// recents and the document on screen.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var accounts: [NASAccount] = []
    @Published private(set) var syncStatus: [UUID: AccountSyncStatus] = [:]
    @Published private(set) var conflicts: [UUID: [SyncConflict]] = [:]
    @Published private(set) var favorites: Set<LibraryRef> = []
    @Published private(set) var recents: [RecentEntry] = []
    @Published var openDocument: OpenDocument?
    @Published var errorMessage: String?
    /// Bumped whenever library contents may have changed (views reload).
    @Published private(set) var libraryRevision = 0
    @Published var settings: AppSettings { didSet { settings.save() } }
    /// Strokes copied with the lasso (engine clipboard format).
    @Published var strokeClipboard: Data?

    let credentials: CredentialStore = KeychainCredentialStore()
    let network = NetworkMonitor()
    private let accountStore = AccountStore(fileURL: AppPaths.accountsFile)
    private var engines: [UUID: SyncEngine] = [:]
    private var syncTasks: [UUID: Task<Void, Never>] = [:]
    private var scheduled: [UUID: Task<Void, Never>] = [:]
    private var periodic: Timer?
    private var openNotebooks: [LibrarySource: Set<String>] = [:]

    init() {
        settings = AppSettings.load()
        accounts = accountStore.load()
        for account in accounts {
            syncStatus[account.id] = AccountSyncStatus(lastSync: account.lastSync)
        }
        favorites = Set(Self.loadList([LibraryRef].self, key: "favorites") ?? [])
        recents = Self.loadList([RecentEntry].self, key: "recents") ?? []
    }

    // MARK: Sources

    func library(_ source: LibrarySource) -> LibraryFileSystem {
        switch source {
        case .local: return LibraryFileSystem(root: AppPaths.localLibrary)
        case .account(let id): return LibraryFileSystem(root: AppPaths.mirror(for: id))
        }
    }

    func trash(_ source: LibrarySource) -> TrashBin { TrashBin(directory: AppPaths.trash(for: source)) }

    func account(_ id: UUID?) -> NASAccount? {
        guard let id else { return nil }
        return accounts.first { $0.id == id }
    }

    func displayName(_ source: LibrarySource) -> String {
        switch source {
        case .local: return "이 iPad"
        case .account(let id): return account(id)?.name ?? "NAS"
        }
    }

    /// SF Symbol of a storage: an iPad for this device, the NAS kind's symbol for an account.
    func symbolName(_ source: LibrarySource) -> String {
        switch source {
        case .local: return "ipad"
        case .account(let id): return account(id)?.kind.symbolName ?? NASKind.synology.symbolName
        }
    }

    func url(for ref: LibraryRef) -> URL { library(ref.source).url(for: ref.path) }

    func refreshLibrary() { libraryRevision += 1 }

    // MARK: Listing

    func items(in location: LibraryLocation) async -> [LibraryEntry] {
        var items = (try? library(location.source).list(location.folder)) ?? []
        if location.source == .local, location.folder == "/" {
            items.removeAll { $0.fileName == "Inbox" }
        }
        if let id = location.source.accountID, let engine = engine(for: id) {
            let known = Set(items.map(\.path))
            items += await engine.placeholders(in: location.folder).filter { !known.contains($0.path) }
        }
        return settings.librarySort.sort(items)
    }

    func search(_ query: String, in source: LibrarySource) async -> [LibraryEntry] {
        var results = library(source).search(query)
        if let id = source.accountID, let engine = engine(for: id) {
            results += await engine.searchPlaceholders(query)
        }
        return settings.librarySort.sort(results)
    }

    func badge(for item: LibraryEntry, in source: LibrarySource) -> SyncBadgeState {
        guard let id = source.accountID else { return .localOnly }
        if item.isPlaceholder { return .cloudOnly }
        if conflicts[id, default: []].contains(where: { RemotePath.isAncestor($0.path, of: item.path) }) {
            return .conflict
        }
        let status = syncStatus[id] ?? AccountSyncStatus()
        if case .error = status.phase { return .error }
        if let last = status.lastSync, let modified = item.modified, modified <= last { return .synced }
        return status.lastSync == nil ? .syncing : (status.isSyncing ? .syncing : .synced)
    }

    // MARK: Favorites & recents

    func isFavorite(_ ref: LibraryRef) -> Bool { favorites.contains(ref) }

    func toggleFavorite(_ ref: LibraryRef) {
        if favorites.contains(ref) { favorites.remove(ref) } else { favorites.insert(ref) }
        Self.saveList(Array(favorites), key: "favorites")
    }

    private func noteRecent(_ ref: LibraryRef) {
        recents.removeAll { $0.ref == ref }
        recents.insert(RecentEntry(ref: ref, opened: Date()), at: 0)
        if recents.count > 30 { recents.removeLast(recents.count - 30) }
        Self.saveList(recents, key: "recents")
    }

    /// Recents / favorites that still exist.
    func existingItems(_ refs: [LibraryRef]) -> [(LibraryRef, LibraryEntry)] {
        refs.compactMap { ref in
            let lib = library(ref.source)
            guard lib.exists(ref.path), let attrs = try? FileManager.default.attributesOfItem(atPath: lib.url(for: ref.path).path) else {
                return nil
            }
            let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
            let kind = LibraryItemKind.classify(name: RemotePath.name(ref.path), isDirectory: isDir)
            var modified = attrs[.modificationDate] as? Date
            if kind == .notebook {
                let doc = lib.url(for: ref.path).appendingPathComponent(NotebookPackage.documentFile)
                modified = (try? FileManager.default.attributesOfItem(atPath: doc.path))?[.modificationDate] as? Date ?? modified
            }
            return (ref, LibraryEntry(path: ref.path, kind: kind, modified: modified, size: 0))
        }
    }

    private static func loadList<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func saveList<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    // MARK: Opening & closing documents

    func open(_ item: LibraryEntry, in source: LibrarySource) {
        Task { await openAsync(item, in: source) }
    }

    private func openAsync(_ item: LibraryEntry, in source: LibrarySource) async {
        let ref = LibraryRef(source: source, path: item.path)
        var url = library(source).url(for: item.path)
        if item.isPlaceholder, let id = source.accountID, let engine = engine(for: id) {
            do {
                url = try await engine.materialize(item.path)
                refreshLibrary()
            } catch {
                errorMessage = "NAS에서 파일을 받지 못했습니다. \(error.localizedDescription)"
                return
            }
        }
        switch item.kind {
        case .notebook:
            openNotebooks[source, default: []].insert(item.path)
            openDocument = OpenDocument(ref: ref, url: url, kind: .notebook)
        case .pdf:
            openDocument = OpenDocument(ref: ref, url: url, kind: .pdf)
        default:
            errorMessage = "이 형식(\(RemotePath.pathExtension(item.path).uppercased()))은 열 수 없습니다. 공유 메뉴로 다른 앱에서 열어 주세요."
            return
        }
        noteRecent(ref)
    }

    func openNotebook(_ ref: LibraryRef) {
        openNotebooks[ref.source, default: []].insert(ref.path)
        openDocument = OpenDocument(ref: ref, url: url(for: ref), kind: .notebook)
        noteRecent(ref)
    }

    func documentClosed(_ doc: OpenDocument, exportPDF: (() -> URL?)? = nil) {
        openNotebooks[doc.ref.source]?.remove(doc.ref.path)
        if doc.kind == .notebook, let id = doc.ref.source.accountID, account(id)?.options.exportPDFCopies == true,
           let exported = exportPDF?() {
            // "<노트>.pdf" next to the notebook, synced like any file.
            let lib = library(doc.ref.source)
            let name = FileNaming.split(RemotePath.name(doc.ref.path)).base + ".pdf"
            let target = lib.url(for: RemotePath.join(RemotePath.parent(doc.ref.path), name))
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.copyItem(at: exported, to: target)
        }
        if openDocument?.id == doc.id { openDocument = nil }
        refreshLibrary()
        localChange(in: doc.ref.source)
    }

    // MARK: Creating & importing

    @discardableResult
    func createNotebook(in location: LibraryLocation, title: String, coverHex: String?, paper: PaperStyle,
                        size: PageSize, open: Bool = true) -> LibraryRef? {
        let lib = library(location.source)
        let doc = NotebookDocument(title: title.isEmpty ? "새 노트" : title, cover: CoverStyle(colorHex: coverHex),
                                   paper: paper, size: size, pageCount: 1)
        do {
            let package = try NotebookPackage.create(in: lib.url(for: location.folder), document: doc)
            let ref = LibraryRef(source: location.source, path: RemotePath.join(location.folder, package.url.lastPathComponent))
            refreshLibrary()
            localChange(in: location.source)
            if open { openNotebook(ref) }
            return ref
        } catch {
            errorMessage = "노트를 만들지 못했습니다. \(error.localizedDescription)"
            return nil
        }
    }

    /// Imports a PDF from outside (Files, AirDrop…). `annotate` makes it a notebook right away.
    func importPDF(from url: URL, into location: LibraryLocation, annotate: Bool) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let lib = library(location.source)
        do {
            if annotate {
                let sizes = PDFSupport.pageSizes(of: url)
                guard !sizes.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                let title = FileNaming.split(url.lastPathComponent).base
                let package = try NotebookPackage.createAnnotating(pdfURL: url, title: title, pageSizes: sizes,
                                                                   in: lib.url(for: location.folder))
                let ref = LibraryRef(source: location.source,
                                     path: RemotePath.join(location.folder, package.url.lastPathComponent))
                openNotebook(ref)
            } else {
                try lib.importFile(from: url, into: location.folder)
            }
            refreshLibrary()
            localChange(in: location.source)
        } catch {
            errorMessage = "PDF를 가져오지 못했습니다. \(error.localizedDescription)"
        }
    }

    /// "필기 시작" on a PDF in the library: reuses the notebook linked to it, or
    /// creates "<PDF> 필기.inknote" beside it (the original PDF stays untouched on the NAS).
    func annotate(pdf ref: LibraryRef) {
        let lib = library(ref.source)
        let folder = RemotePath.parent(ref.path)
        for item in (try? lib.list(folder)) ?? [] where item.kind == .notebook {
            if let doc = try? NotebookPackage(url: lib.url(for: item.path)).readDocument(), doc.pdf?.linkedPath == ref.path {
                openNotebook(LibraryRef(source: ref.source, path: item.path))
                return
            }
        }
        let pdfURL = lib.url(for: ref.path)
        let sizes = PDFSupport.pageSizes(of: pdfURL)
        guard !sizes.isEmpty else {
            errorMessage = "PDF를 읽을 수 없습니다."
            return
        }
        do {
            let title = FileNaming.split(RemotePath.name(ref.path)).base + " 필기"
            let package = try NotebookPackage.createAnnotating(pdfURL: pdfURL, title: title, pageSizes: sizes,
                                                               in: lib.url(for: folder), linkedPath: ref.path)
            openNotebook(LibraryRef(source: ref.source, path: RemotePath.join(folder, package.url.lastPathComponent)))
            refreshLibrary()
            localChange(in: ref.source)
        } catch {
            errorMessage = "필기 노트를 만들지 못했습니다. \(error.localizedDescription)"
        }
    }

    /// Copies a file downloaded from the NAS browser into a library folder.
    func importRemoteCopy(_ url: URL, into location: LibraryLocation) {
        do {
            try library(location.source).importFile(from: url, into: location.folder)
            refreshLibrary()
            localChange(in: location.source)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: File operations

    func perform(_ source: LibrarySource, _ operation: (LibraryFileSystem) throws -> Void) {
        do {
            try operation(library(source))
            refreshLibrary()
            localChange(in: source)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createFolder(named name: String, in location: LibraryLocation) {
        perform(location.source) { try $0.createFolder(named: name, in: location.folder) }
    }

    func rename(_ ref: LibraryRef, to name: String) {
        perform(ref.source) { lib in
            let newPath = try lib.rename(ref.path, to: name)
            self.replaceRef(ref, with: LibraryRef(source: ref.source, path: newPath))
        }
    }

    func move(_ ref: LibraryRef, to folder: String) {
        perform(ref.source) { lib in
            let newPath = try lib.move(ref.path, toFolder: folder)
            self.replaceRef(ref, with: LibraryRef(source: ref.source, path: newPath))
        }
    }

    /// Whether `item` can be moved to another storage (e.g. a PDF on this iPad → a NAS).
    func canMoveAcross(_ item: LibraryEntry, from source: LibrarySource) -> Bool {
        source == .local && !item.isPlaceholder && !accounts.isEmpty
            && (item.kind == .pdf || item.kind == .image || item.kind == .other)
    }

    /// Moves an item to a folder of the same or another storage. A file on this iPad moved to
    /// a NAS lands in the account's local mirror and goes up with the next sync; the original
    /// is removed only after the copy is complete. Recents and favorites follow it.
    func move(_ ref: LibraryRef, to target: LibraryLocation) {
        guard ref.source != target.source else { return move(ref, to: target.folder) }
        let from = library(ref.source), to = library(target.source)
        let name = RemotePath.name(ref.path)
        do {
            let original = from.url(for: ref.path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: original.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw LibraryFileSystem.LibraryError.notFound(ref.path)
            }
            let newPath = try to.importFile(from: original, into: target.folder, preferredName: name)
            let size = { (url: URL) in (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value }
            guard let copied = size(to.url(for: newPath)), copied == size(original) else {
                try? to.delete(newPath)
                throw LibraryFileSystem.LibraryError.incompleteCopy(name)
            }
            try from.delete(ref.path)
            replaceRef(ref, with: LibraryRef(source: target.source, path: newPath))
            refreshLibrary()
            localChange(in: target.source)
        } catch {
            errorMessage = "옮기지 못했습니다. \(error.localizedDescription)"
            refreshLibrary()
        }
    }

    func duplicate(_ ref: LibraryRef) {
        perform(ref.source) { try $0.duplicate(ref.path) }
    }

    func delete(_ item: LibraryEntry, in source: LibrarySource) {
        let ref = LibraryRef(source: source, path: item.path)
        if item.isPlaceholder, let id = source.accountID, let engine = engine(for: id) {
            Task {
                do {
                    try await engine.deletePlaceholder(item.path)
                    refreshLibrary()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            return
        }
        perform(source) { try $0.delete(item.path, trash: self.trash(source)) }
        favorites.remove(ref)
        recents.removeAll { $0.ref == ref }
    }

    func restore(_ entry: TrashBin.Entry, in source: LibrarySource) {
        perform(source) { try self.trash(source).restore(entry, into: $0) }
    }

    /// Frees space by removing the local copy of a downloaded NAS file.
    func evict(_ item: LibraryEntry, in source: LibrarySource) {
        guard let id = source.accountID, let engine = engine(for: id) else { return }
        Task {
            try? await engine.evict(item.path)
            refreshLibrary()
        }
    }

    private func replaceRef(_ old: LibraryRef, with new: LibraryRef) {
        if favorites.remove(old) != nil { favorites.insert(new) }
        for i in recents.indices where recents[i].ref == old { recents[i].ref = new }
        Self.saveList(Array(favorites), key: "favorites")
        Self.saveList(recents, key: "recents")
    }

    // MARK: Accounts

    func saveAccount(_ account: NASAccount, password: String?) {
        if let password { credentials.setSecret(password, for: account.passwordKey) }
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            let old = accounts[index]
            accounts[index] = account
            engines[account.id] = nil
            if old.syncFolder != account.syncFolder || old.kind != account.kind || old.host != account.host
                || old.endpointPath != account.endpointPath || old.bookmark != account.bookmark {
                // A different remote folder: start a fresh mirror.
                syncTasks[account.id]?.cancel()
                try? FileManager.default.removeItem(at: AppPaths.mirror(for: account.id))
                try? FileManager.default.removeItem(at: AppPaths.syncState(for: account.id))
            }
        } else {
            accounts.append(account)
            syncStatus[account.id] = AccountSyncStatus()
        }
        persistAccounts()
        refreshLibrary()
        sync(account.id, manual: true)
    }

    func removeAccount(_ id: UUID) {
        guard let account = account(id) else { return }
        syncTasks[id]?.cancel()
        syncTasks[id] = nil
        engines[id] = nil
        credentials.setSecret(nil, for: account.passwordKey)
        credentials.setSecret(nil, for: account.deviceTokenKey)
        try? FileManager.default.removeItem(at: AppPaths.mirror(for: id))
        try? FileManager.default.removeItem(at: AppPaths.syncState(for: id))
        try? FileManager.default.removeItem(at: AppPaths.trash(for: .account(id)))
        accounts.removeAll { $0.id == id }
        syncStatus[id] = nil
        conflicts[id] = nil
        favorites = favorites.filter { $0.source != .account(id) }
        recents.removeAll { $0.ref.source == .account(id) }
        persistAccounts()
        refreshLibrary()
    }

    func updateOptions(_ id: UUID, _ change: (inout SyncOptions) -> Void) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        change(&accounts[index].options)
        persistAccounts()
    }

    private func persistAccounts() {
        do { try accountStore.save(accounts) } catch { errorMessage = error.localizedDescription }
    }

    /// A client for browsing the whole NAS (separate from the sync engine).
    func fileSystem(for account: NASAccount) -> RemoteFileSystem? {
        try? NASConnection.makeFileSystem(for: account, credentials: credentials,
                                          onPin: pinHandler(account.id), onDeviceToken: deviceTokenHandler(account))
    }

    private func pinHandler(_ id: UUID) -> @Sendable (String) -> Void {
        { [weak self] fingerprint in
            Task { @MainActor [weak self] in
                guard let self, let index = self.accounts.firstIndex(where: { $0.id == id }) else { return }
                self.accounts[index].pinnedCertificateSHA256 = fingerprint
                self.persistAccounts()
            }
        }
    }

    private func deviceTokenHandler(_ account: NASAccount) -> @Sendable (String) -> Void {
        let key = account.deviceTokenKey
        let store = credentials
        return { token in store.setSecret(token, for: key) }
    }

    // MARK: Sync

    func engine(for id: UUID) -> SyncEngine? {
        if let engine = engines[id] { return engine }
        guard let account = account(id),
              let fs = try? NASConnection.makeFileSystem(for: account, credentials: credentials,
                                                         onPin: pinHandler(id),
                                                         onDeviceToken: deviceTokenHandler(account)) else { return nil }
        let root = account.kind == .filesFolder ? "/" : account.syncFolder
        let engine = SyncEngine(remote: fs, localRoot: AppPaths.mirror(for: id), remoteRoot: root,
                                stateURL: AppPaths.syncState(for: id), deviceName: UIDevice.current.model)
        engines[id] = engine
        return engine
    }

    func status(_ id: UUID) -> AccountSyncStatus { syncStatus[id] ?? AccountSyncStatus() }

    var totalConflicts: Int { conflicts.values.reduce(0) { $0 + $1.count } }

    func syncAll(manual: Bool = false) {
        for account in accounts { sync(account.id, manual: manual) }
    }

    /// Something changed locally in `source`; sync a few seconds later (coalesced).
    func localChange(in source: LibrarySource) {
        guard let id = source.accountID, account(id)?.options.autoSync == true else { return }
        scheduled[id]?.cancel()
        scheduled[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.sync(id)
        }
    }

    func sync(_ id: UUID, manual: Bool = false) {
        guard syncTasks[id] == nil, let account = account(id) else { return }
        var status = syncStatus[id] ?? AccountSyncStatus()
        if !manual {
            guard account.options.autoSync else { return }
            if account.options.wifiOnly && !network.isOnWiFi {
                status.phase = .waitingForWiFi
                syncStatus[id] = status
                return
            }
        }
        guard network.isConnected || account.kind == .filesFolder else {
            status.phase = .offline
            syncStatus[id] = status
            return
        }
        guard let engine = engine(for: id) else {
            status.phase = .error("연결 정보를 확인해 주세요.")
            syncStatus[id] = status
            return
        }
        status.phase = .syncing
        status.progress = nil
        syncStatus[id] = status
        let busy = openNotebooks[.account(id)] ?? []
        let options = account.options
        let background = UIApplication.shared.beginBackgroundTask(withName: "NoteSync")
        let onProgress: @Sendable (SyncProgress) -> Void = { [weak self] progress in
            Task { @MainActor [weak self] in self?.syncStatus[id]?.progress = progress }
        }
        syncTasks[id] = Task { [weak self] in
            defer {
                if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            }
            do {
                let report = try await engine.run(options: options, busy: busy, progress: onProgress)
                guard let self else { return }
                self.syncStatus[id] = AccountSyncStatus(phase: .idle, progress: nil, lastSync: Date(), lastReport: report)
                self.conflicts[id] = report.conflicts
                if let index = self.accounts.firstIndex(where: { $0.id == id }) {
                    self.accounts[index].lastSync = Date()
                    self.persistAccounts()
                }
                if !report.errors.isEmpty {
                    self.syncStatus[id]?.phase = .error("일부 파일을 동기화하지 못했습니다 (\(report.errors.count)개).")
                }
                self.refreshLibrary()
            } catch is CancellationError {
                self?.syncStatus[id]?.phase = .idle
            } catch {
                guard let self else { return }
                self.syncStatus[id]?.phase = .error(error.localizedDescription)
                if let remote = error as? RemoteError, remote == .unauthorized || remote == .twoFactorRequired {
                    self.engines[id] = nil   // rebuild with fresh credentials next time
                }
            }
            self?.syncTasks[id] = nil
        }
    }

    func resolve(_ conflict: SyncConflict, account id: UUID, with resolution: ConflictResolution) {
        guard let engine = engine(for: id) else { return }
        conflicts[id]?.removeAll { $0.path == conflict.path }
        Task {
            await engine.resolve(conflict.path, with: resolution)
            sync(id, manual: true)
        }
    }

    func loadConflicts() {
        for account in accounts {
            guard let engine = engine(for: account.id) else { continue }
            Task {
                let list = await engine.conflicts
                conflicts[account.id] = list
            }
        }
    }

    // MARK: Lifecycle

    func becameActive() {
        loadConflicts()
        syncAll()
        periodic?.invalidate()
        periodic = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.syncAll() }
        }
    }

    func enteredBackground() {
        periodic?.invalidate()
        periodic = nil
        syncAll()
    }
}
#endif
