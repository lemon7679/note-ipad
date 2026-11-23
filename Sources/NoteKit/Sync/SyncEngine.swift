import Foundation

/// Persistent sync state of one account (Application Support/Sync/<id>.json).
public struct SyncState: Codable, Equatable, Sendable {
    public var version = 1
    public var records: [String: SyncRecord] = [:]
    public var conflicts: [String: SyncConflict] = [:]
    public var resolutions: [String: ConflictResolution] = [:]
    public var lastSync: Date?

    public init() {}
}

public struct SyncProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case scanning
        case transferring
        case finished
    }

    public var phase: Phase
    public var completed: Int
    public var total: Int
    public var currentItem: String?

    public var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }
}

public struct SyncReport: Sendable, Equatable {
    public var uploaded = 0
    public var downloaded = 0
    public var deletedLocal = 0
    public var deletedRemote = 0
    public var conflicts: [SyncConflict] = []
    public var errors: [String] = []
    /// Local paths that changed (for refreshing open views).
    public var changedLocalPaths: [String] = []
    public var finished = Date()

    public var transferred: Int { uploaded + downloaded + deletedLocal + deletedRemote }
}

public enum SyncError: Error, LocalizedError {
    case remoteFolderMissing(String)
    case suspiciousEmptyRemote

    public var errorDescription: String? {
        switch self {
        case .remoteFolderMissing(let p): return "NAS에서 노트 폴더(\(p))를 찾을 수 없습니다."
        case .suspiciousEmptyRemote:
            return "NAS 폴더가 비어 있는 것으로 보여 안전을 위해 동기화를 멈췄습니다. NAS 상태를 확인해 주세요."
        }
    }
}

/// Two-way mirror between a local folder and a NAS folder.
///
/// The app always works on the local mirror (fast, offline-capable); the
/// engine reconciles it with the NAS using `SyncPlanner`. State is saved after
/// every transfer, so an interrupted sync resumes where it stopped.
public actor SyncEngine {
    public let localRoot: URL
    public let remoteRoot: String
    private let remote: RemoteFileSystem
    private let stateURL: URL
    private let deviceName: String
    private var state: SyncState
    private let fm = FileManager.default

    public init(remote: RemoteFileSystem, localRoot: URL, remoteRoot: String, stateURL: URL,
                deviceName: String = "iPad") {
        self.remote = remote
        self.localRoot = localRoot
        self.remoteRoot = RemotePath.normalize(remoteRoot)
        self.stateURL = stateURL
        self.deviceName = deviceName
        if let data = try? Data(contentsOf: stateURL),
           let decoded = try? NotebookDocument.decoder.decode(SyncState.self, from: data) {
            state = decoded
        } else {
            state = SyncState()
        }
        try? FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
    }

    public var currentState: SyncState { state }
    public var conflicts: [SyncConflict] { state.conflicts.values.sorted { $0.path < $1.path } }
    public var lastSync: Date? { state.lastSync }

    private func saveState() {
        try? fm.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? NotebookDocument.encoder.encode(state) { try? data.write(to: stateURL, options: .atomic) }
    }

    private func remotePath(_ rel: String) -> String { RemotePath.join(remoteRoot, rel) }
    private func localURL(_ rel: String) -> URL { localRoot.appendingRemotePath(rel) }

    // MARK: Scanning

    func scanLocal() -> [String: LocalEntry] {
        var out: [String: LocalEntry] = [:]
        var queue = ["/"]
        while !queue.isEmpty {
            let dir = queue.removeFirst()
            let names = (try? fm.contentsOfDirectory(atPath: localURL(dir).path)) ?? []
            for name in names where !FileNaming.isIgnored(name) {
                let rel = RemotePath.join(dir, name)
                guard let attrs = try? fm.attributesOfItem(atPath: localURL(rel).path) else { continue }
                let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
                out[rel] = LocalEntry(path: rel, isDirectory: isDir, size: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
                                      modified: attrs[.modificationDate] as? Date)
                if isDir { queue.append(rel) }
            }
        }
        return out
    }

    func scanRemote() async throws -> [String: RemoteItem] {
        if try await remote.stat(remoteRoot) == nil {
            if state.records.isEmpty {
                try await remote.createDirectory(remoteRoot)
            } else {
                throw SyncError.remoteFolderMissing(remoteRoot)
            }
        }
        var out: [String: RemoteItem] = [:]
        for item in try await remote.listRecursive(remoteRoot) {
            guard let rel = RemotePath.relative(item.path, to: remoteRoot), rel != "/" else { continue }
            if RemotePath.components(rel).contains(where: FileNaming.isIgnored) { continue }
            var copy = item
            copy.path = rel
            out[rel] = copy
        }
        return out
    }

    // MARK: Running

    /// One full sync pass. `busy` holds library paths of notebooks open for editing.
    public func run(options: SyncOptions, busy: Set<String> = [],
                    progress: (@Sendable (SyncProgress) -> Void)? = nil) async throws -> SyncReport {
        try await run(options: options, busy: busy, progress: progress, followUp: false)
    }

    private func run(options: SyncOptions, busy: Set<String>, progress: (@Sendable (SyncProgress) -> Void)?,
                     followUp: Bool) async throws -> SyncReport {
        progress?(SyncProgress(phase: .scanning, completed: 0, total: 0, currentItem: nil))
        let remoteItems = try await scanRemote()
        let localItems = scanLocal()

        // Safety: never turn "the NAS answered with nothing" into "delete everything here".
        let knownRemote = state.records.values.filter { $0.remoteSig != nil }.count
        if remoteItems.isEmpty && knownRemote >= 5 { throw SyncError.suspiciousEmptyRemote }
        // A wiped mirror re-downloads instead of deleting the NAS copy.
        let knownLocal = state.records.values.filter { $0.localSig != nil }.count
        if localItems.isEmpty && knownLocal >= 5 {
            state.records = [:]
        }

        var resolutions = state.resolutions
        if options.keepBothOnConflict {
            for path in state.conflicts.keys where resolutions[path] == nil { resolutions[path] = .keepBoth }
        }

        let plan = SyncPlanner.plan(local: localItems, remote: remoteItems, base: state.records, busy: busy,
                                    resolutions: resolutions, downloadOnDemand: options.downloadOnDemand)
        var report = SyncReport()
        let transfers = plan.actions.filter { $0.phase != 4 }.count
        var done = 0
        var madeCopies = false

        for action in plan.actions {
            try Task.checkCancellation()
            if action.phase != 4 {
                progress?(SyncProgress(phase: .transferring, completed: done, total: transfers,
                                       currentItem: RemotePath.name(action.path)))
            }
            do {
                try await execute(action, remote: remoteItems, report: &report)
                if case .conflictCopy = action { madeCopies = true }
            } catch let error as RemoteError where error.stopsSync {
                saveState()
                throw error   // credentials / certificate / full-disk problems stop the whole sync
            } catch is CancellationError {
                saveState()
                throw CancellationError()
            } catch {
                report.errors.append("\(RemotePath.name(action.path)): \(error.localizedDescription)")
            }
            if action.phase != 4 {
                done += 1
                if done % 10 == 0 { saveState() }
            }
        }

        // Resolutions that were applied are consumed; new conflicts are remembered.
        for root in resolutions.keys where !busy.contains(where: { RemotePath.isAncestor($0, of: root) }) {
            state.resolutions[root] = nil
            state.conflicts[root] = nil
        }
        var conflicts: [String: SyncConflict] = [:]
        for c in plan.conflicts { conflicts[c.path] = state.conflicts[c.path] ?? c }
        state.conflicts = conflicts
        state.lastSync = Date()
        saveState()

        report.conflicts = conflicts.values.sorted { $0.path < $1.path }
        report.finished = Date()
        progress?(SyncProgress(phase: .finished, completed: transfers, total: transfers, currentItem: nil))

        let autoResolve = options.keepBothOnConflict && !plan.conflicts.isEmpty
        if !followUp && (madeCopies || autoResolve) {
            // Upload conflict copies right away / settle new conflicts as "keep both".
            let next = try await run(options: options, busy: busy, progress: nil, followUp: true)
            report.uploaded += next.uploaded
            report.downloaded += next.downloaded
            report.changedLocalPaths += next.changedLocalPaths
            report.conflicts = next.conflicts
            report.errors += next.errors
        }
        return report
    }

    private func execute(_ action: SyncAction, remote remoteItems: [String: RemoteItem],
                         report: inout SyncReport) async throws {
        let p = action.path
        switch action {
        case .makeRemoteDirectory:
            try await remote.createDirectory(remotePath(p))
            state.records[p] = SyncRecord(isDirectory: true, localSig: "dir", remoteSig: "dir")

        case .makeLocalDirectory:
            try fm.createDirectory(at: localURL(p), withIntermediateDirectories: true)
            state.records[p] = SyncRecord(isDirectory: true, localSig: "dir", remoteSig: "dir")
            report.changedLocalPaths.append(p)

        case .upload:
            let url = localURL(p)
            guard let entry = localEntry(p) else { return }   // vanished meanwhile
            var item = try await remote.upload(from: url, to: remotePath(p), modified: entry.modified)
            if item == nil { item = try await remote.stat(remotePath(p)) }
            state.records[p] = SyncRecord(isDirectory: false, localSig: entry.signature, remoteSig: item?.signature,
                                          remoteSize: item?.size ?? entry.size, remoteModified: item?.modified)
            report.uploaded += 1

        case .download:
            guard let item = remoteItems[p] else { return }
            try await downloadFile(p, item: item)
            report.downloaded += 1
            report.changedLocalPaths.append(p)

        case .deleteRemote:
            try await remote.delete(remotePath(p))
            removeRecords(under: p)
            report.deletedRemote += 1

        case .deleteLocal:
            let url = localURL(p)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            removeRecords(under: p)
            report.deletedLocal += 1
            report.changedLocalPaths.append(p)

        case .placeholder:
            guard let item = remoteItems[p] else { return }
            state.records[p] = SyncRecord(isDirectory: false, localSig: nil, remoteSig: item.signature,
                                          remoteSize: item.size, remoteModified: item.modified)

        case .adopt:
            guard let item = remoteItems[p], let entry = localEntry(p) else { return }
            state.records[p] = SyncRecord(isDirectory: item.isDirectory, localSig: entry.signature,
                                          remoteSig: item.signature, remoteSize: item.size,
                                          remoteModified: item.modified)

        case .forget:
            state.records[p] = nil

        case .conflictCopy:
            try makeConflictCopy(p)
            report.changedLocalPaths.append(RemotePath.parent(p))
        }
    }

    private func localEntry(_ rel: String) -> LocalEntry? {
        guard let attrs = try? fm.attributesOfItem(atPath: localURL(rel).path) else { return nil }
        let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
        return LocalEntry(path: rel, isDirectory: isDir, size: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
                          modified: attrs[.modificationDate] as? Date)
    }

    private func removeRecords(under prefix: String) {
        for key in state.records.keys where RemotePath.isAncestor(prefix, of: key) {
            state.records[key] = nil
        }
    }

    private func downloadFile(_ rel: String, item: RemoteItem) async throws {
        let tmpDir = localRoot.appendingPathComponent(".sync-tmp", isDirectory: true)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let tmp = tmpDir.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        try await remote.download(remotePath(rel), to: tmp)
        let dest = localURL(rel)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: tmp, to: dest)
        if let modified = item.modified {
            try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: dest.path)
        }
        let entry = localEntry(rel)
        state.records[rel] = SyncRecord(isDirectory: false, localSig: entry?.signature, remoteSig: item.signature,
                                        remoteSize: item.size, remoteModified: item.modified)
    }

    private func makeConflictCopy(_ rel: String) throws {
        let source = localURL(rel)
        guard fm.fileExists(atPath: source.path) else { return }
        let parent = RemotePath.parent(rel)
        let copyName = FileNaming.conflictCopyName(for: RemotePath.name(rel), device: deviceName)
        let library = LibraryFileSystem(root: localRoot)
        if NotebookPackage.isPackage(source) {
            let title = FileNaming.split(copyName).base
            try NotebookPackage(url: source).duplicate(into: localURL(parent), title: title)
        } else {
            let (base, ext) = FileNaming.split(copyName)
            let name = FileNaming.unique(base: base, ext: ext) { library.exists(RemotePath.join(parent, $0)) }
            try fm.copyItem(at: source, to: localURL(RemotePath.join(parent, name)))
        }
    }

    // MARK: On-demand files and conflicts

    /// Online-only files directly inside `folder`.
    public func placeholders(in folder: String) -> [LibraryEntry] {
        let dir = RemotePath.normalize(folder)
        return state.records.compactMap { path, record in
            guard record.isPlaceholder, RemotePath.parent(path) == dir,
                  !fm.fileExists(atPath: localURL(path).path) else { return nil }
            return LibraryEntry(path: path, kind: LibraryItemKind.classify(name: RemotePath.name(path), isDirectory: false),
                               modified: record.remoteModified, size: record.remoteSize, isPlaceholder: true)
        }
    }

    /// Online-only files whose name contains `query`.
    public func searchPlaceholders(_ query: String) -> [LibraryEntry] {
        state.records.compactMap { path, record in
            guard record.isPlaceholder, RemotePath.name(path).localizedCaseInsensitiveContains(query) else { return nil }
            return LibraryEntry(path: path, kind: LibraryItemKind.classify(name: RemotePath.name(path), isDirectory: false),
                               modified: record.remoteModified, size: record.remoteSize, isPlaceholder: true)
        }
    }

    /// Downloads an online-only file so it can be opened.
    @discardableResult
    public func materialize(_ path: String) async throws -> URL {
        let rel = RemotePath.normalize(path)
        if let record = state.records[rel], !record.isPlaceholder, fm.fileExists(atPath: localURL(rel).path) {
            return localURL(rel)
        }
        guard let item = try await remote.stat(remotePath(rel)) else { throw RemoteError.notFound(rel) }
        var relItem = item
        relItem.path = rel
        try await downloadFile(rel, item: relItem)
        saveState()
        return localURL(rel)
    }

    /// Deletes an online-only file on the NAS.
    public func deletePlaceholder(_ path: String) async throws {
        let rel = RemotePath.normalize(path)
        try await remote.delete(remotePath(rel))
        state.records[rel] = nil
        saveState()
    }

    /// Frees space: removes the local copy of a downloaded file but keeps it on the NAS.
    public func evict(_ path: String) throws {
        let rel = RemotePath.normalize(path)
        guard var record = state.records[rel], !record.isDirectory, FileNaming.packageRoot(of: rel) == nil else { return }
        if let entry = localEntry(rel), entry.signature != record.localSig { return }  // unsynced edits
        try? fm.removeItem(at: localURL(rel))
        record.localSig = nil
        state.records[rel] = record
        saveState()
    }

    /// Chooses how a conflict is settled; applied by the next `run`.
    public func resolve(_ path: String, with resolution: ConflictResolution) {
        state.resolutions[RemotePath.normalize(path)] = resolution
        saveState()
    }

    /// Forgets everything (e.g. when the sync folder changes).
    public func reset() {
        state = SyncState()
        saveState()
    }
}
