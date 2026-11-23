import Foundation

/// What the last successful sync knew about one path (relative to the sync roots).
public struct SyncRecord: Codable, Equatable, Sendable {
    public var isDirectory: Bool
    /// Local signature at the last sync; nil when the file only exists on the NAS
    /// (an on-demand placeholder).
    public var localSig: String?
    /// Remote signature at the last sync.
    public var remoteSig: String?
    public var remoteSize: Int64
    public var remoteModified: Date?

    public init(isDirectory: Bool, localSig: String?, remoteSig: String?, remoteSize: Int64 = 0,
                remoteModified: Date? = nil) {
        self.isDirectory = isDirectory
        self.localSig = localSig
        self.remoteSig = remoteSig
        self.remoteSize = remoteSize
        self.remoteModified = remoteModified
    }

    public var isPlaceholder: Bool { !isDirectory && localSig == nil }
}

/// A file or folder in the local mirror.
public struct LocalEntry: Equatable, Sendable {
    public var path: String
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date?

    public init(path: String, isDirectory: Bool, size: Int64, modified: Date?) {
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }

    public var signature: String {
        if isDirectory { return "dir" }
        let ms = Int64(((modified?.timeIntervalSince1970 ?? 0) * 1000).rounded())
        return "\(size):\(ms)"
    }
}

public enum ConflictResolution: String, Codable, Sendable {
    /// Upload this iPad's version over the NAS one.
    case keepLocal
    /// Replace this iPad's version with the NAS one.
    case keepRemote
    /// Keep this iPad's version as a "(충돌 사본 …)" copy and take the NAS one.
    case keepBoth
}

public struct SyncConflict: Codable, Hashable, Identifiable, Sendable {
    public var id: String { path }
    /// The notebook package or file that changed on both sides.
    public var path: String
    public var localModified: Date?
    public var remoteModified: Date?
    public var detected: Date

    public var isNotebook: Bool { RemotePath.pathExtension(path) == FileNaming.notebookExtension }

    public var displayName: String {
        let name = RemotePath.name(path)
        return isNotebook ? FileNaming.split(name).base : name
    }
}

public enum SyncAction: Equatable, Sendable {
    case makeRemoteDirectory(String)
    case makeLocalDirectory(String)
    case upload(String)
    case download(String)
    /// Deletes a file or a whole folder on the NAS.
    case deleteRemote(String)
    case deleteLocal(String)
    /// Remote-only file kept online (on-demand); state only.
    case placeholder(String)
    /// Both sides already hold the same thing; state only.
    case adopt(String)
    /// Gone on both sides; state only.
    case forget(String)
    /// Copies the local item aside as a conflict copy (before it is replaced).
    case conflictCopy(String)

    public var path: String {
        switch self {
        case .makeRemoteDirectory(let p), .makeLocalDirectory(let p), .upload(let p), .download(let p),
             .deleteRemote(let p), .deleteLocal(let p), .placeholder(let p), .adopt(let p), .forget(let p),
             .conflictCopy(let p):
            return p
        }
    }

    /// Execution order: copies, folders (shallow first), transfers, deletions (deep first).
    var phase: Int {
        switch self {
        case .conflictCopy: return 0
        case .makeRemoteDirectory, .makeLocalDirectory: return 1
        case .upload, .download: return 2
        case .deleteRemote, .deleteLocal: return 3
        case .placeholder, .adopt, .forget: return 4
        }
    }

    public var transfersData: Bool {
        switch self {
        case .upload, .download: return true
        default: return false
        }
    }
}

public struct SyncPlan: Equatable, Sendable {
    public var actions: [SyncAction]
    public var conflicts: [SyncConflict]
}

/// Three-way comparison of the local mirror, the NAS folder and the state of
/// the last sync. Pure (no I/O) so every rule is unit-tested.
///
/// Rules
/// - Changed on one side → copy to the other. Deleted on one side and unchanged
///   on the other → delete. Deleted on one side but changed on the other → the
///   change wins (the file is restored).
/// - Changed on both sides → conflict, reported for the user to decide (or
///   resolved as "keep both" when the account says so). A conflict anywhere in a
///   `.inknote` package is a conflict of the whole notebook, so a notebook is
///   never stitched together from two versions.
/// - A folder deleted on one side is deleted on the other only when nothing
///   inside it changed there; otherwise it is recreated.
/// - Items under `busy` (open notebooks) are left for the next sync.
public enum SyncPlanner {
    public static func plan(local: [String: LocalEntry], remote: [String: RemoteItem], base: [String: SyncRecord],
                            busy: Set<String> = [], resolutions: [String: ConflictResolution] = [:],
                            downloadOnDemand: Bool = true, now: Date = Date()) -> SyncPlan {
        var actions: [SyncAction] = []
        var conflicts: [String: SyncConflict] = [:]
        var handledPrefixes: [String] = []

        let allPaths = Set(local.keys).union(remote.keys).union(base.keys)
            .filter { $0 != "/" }
            .sorted { RemotePath.depth($0) == RemotePath.depth($1) ? $0 < $1 : RemotePath.depth($0) < RemotePath.depth($1) }

        func isBusy(_ p: String) -> Bool { busy.contains { RemotePath.isAncestor($0, of: p) } }
        func isHandled(_ p: String) -> Bool { handledPrefixes.contains { RemotePath.isAncestor($0, of: p) } }

        // 1. Explicit resolutions take over whole subtrees.
        for (root, resolution) in resolutions.sorted(by: { $0.key < $1.key }) where !isBusy(root) {
            let paths = allPaths.filter { RemotePath.isAncestor(root, of: $0) }
            if resolution == .keepBoth, local[root] != nil { actions.append(.conflictCopy(root)) }
            for p in paths {
                let l = local[p], r = remote[p]
                switch resolution {
                case .keepLocal:
                    if let l { actions.append(l.isDirectory ? .makeRemoteDirectory(p) : .upload(p)) }
                    else if r != nil { actions.append(.deleteRemote(p)) }
                    else { actions.append(.forget(p)) }
                case .keepRemote, .keepBoth:
                    if let r { actions.append(r.isDirectory ? .makeLocalDirectory(p) : .download(p)) }
                    else if l != nil { actions.append(.deleteLocal(p)) }
                    else { actions.append(.forget(p)) }
                }
            }
            handledPrefixes.append(root)
        }

        // 2. Folders deleted on one side (shallowest first, so a deleted tree is one action).
        for p in allPaths where !isHandled(p) && !isBusy(p) {
            guard let b = base[p], b.isDirectory else { continue }
            let l = local[p], r = remote[p]
            if l == nil, let r, r.isDirectory {
                // Deleted on this iPad: delete on the NAS unless something there changed.
                let changedRemotely = remote.contains { key, item in
                    RemotePath.isAncestor(p, of: key) && key != p && base[key]?.remoteSig != item.signature
                }
                if !changedRemotely {
                    actions.append(.deleteRemote(p))
                    handledPrefixes.append(p)
                }
            } else if r == nil, let l, l.isDirectory {
                // Deleted on the NAS: delete here unless something here changed.
                let changedLocally = local.contains { key, entry in
                    RemotePath.isAncestor(p, of: key) && key != p && base[key]?.localSig != entry.signature
                }
                if !changedLocally {
                    actions.append(.deleteLocal(p))
                    handledPrefixes.append(p)
                }
            } else if l == nil, r == nil {
                actions.append(.forget(p))
                handledPrefixes.append(p)
            }
        }

        // 3. Everything else, path by path.
        var perPath: [(String, SyncAction?)] = []
        for p in allPaths where !isHandled(p) && !isBusy(p) {
            let l = local[p], r = remote[p], b = base[p]
            let inPackage = FileNaming.packageRoot(of: p) != nil
            func conflict() {
                let root = FileNaming.packageRoot(of: p) ?? p
                if conflicts[root] == nil {
                    let localDate = local[root]?.modified ?? l?.modified
                    let remoteDate = remote[root]?.modified ?? r?.modified
                    conflicts[root] = SyncConflict(path: root, localModified: localDate, remoteModified: remoteDate,
                                                   detected: now)
                }
            }

            // Folders.
            if l?.isDirectory == true || r?.isDirectory == true || b?.isDirectory == true {
                switch (l?.isDirectory, r?.isDirectory) {
                case (true?, true?): if b == nil { perPath.append((p, .adopt(p))) }
                case (true?, nil): perPath.append((p, .makeRemoteDirectory(p)))   // new, or restored
                case (nil, true?): perPath.append((p, .makeLocalDirectory(p)))
                case (nil, nil): perPath.append((p, .forget(p)))
                default: conflict()   // a file on one side, a folder on the other
                }
                continue
            }

            let lChanged = b == nil ? l != nil : l?.signature != b?.localSig
            let rChanged = b == nil ? r != nil : r?.signature != b?.remoteSig
            switch (l, r) {
            case (nil, nil):
                if b != nil { perPath.append((p, .forget(p))) }
            case (_?, nil):
                if b == nil || b?.remoteSig == nil {
                    perPath.append((p, .upload(p)))                 // new on this iPad
                } else if lChanged {
                    perPath.append((p, .upload(p)))                 // deleted on NAS, edited here: keep edit
                } else {
                    perPath.append((p, .deleteLocal(p)))
                }
            case (nil, _?):
                if let b, b.isPlaceholder {
                    if rChanged { perPath.append((p, .placeholder(p))) }   // still online-only
                } else if b == nil {
                    let lazy = downloadOnDemand && !inPackage
                    perPath.append((p, lazy ? .placeholder(p) : .download(p)))
                } else if rChanged {
                    perPath.append((p, .download(p)))               // deleted here, edited on NAS: keep edit
                } else {
                    perPath.append((p, .deleteRemote(p)))
                }
            case (let l?, let r?):
                if b == nil || b?.isPlaceholder == true {
                    // Both exist without history (first sync, or a placeholder that appeared locally).
                    if l.size == r.size { perPath.append((p, .adopt(p))) } else { conflict() }
                } else if lChanged && rChanged {
                    conflict()
                } else if lChanged {
                    perPath.append((p, .upload(p)))
                } else if rChanged {
                    perPath.append((p, .download(p)))
                }
            }
        }

        // Auto "keep both" is applied by the caller through `resolutions` on the next pass;
        // here conflicted packages simply drop every action inside them.
        for (path, action) in perPath {
            if let action, !conflicts.keys.contains(where: { RemotePath.isAncestor($0, of: path) }) {
                actions.append(action)
            }
        }

        actions = actions.enumerated().sorted { a, b in
            let (pa, pb) = (a.element.phase, b.element.phase)
            if pa != pb { return pa < pb }
            let (da, db) = (RemotePath.depth(a.element.path), RemotePath.depth(b.element.path))
            if da != db {
                // Deletions deepest first, everything else shallowest first.
                return pa == 3 ? da > db : da < db
            }
            return a.offset < b.offset
        }.map(\.element)

        return SyncPlan(actions: actions, conflicts: conflicts.values.sorted { $0.path < $1.path })
    }
}
