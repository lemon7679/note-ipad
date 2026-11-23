import Foundation

/// A folder reached through the iOS Files app — an SMB share added with
/// "서버에 연결" (Connect to Server), an external drive, or any file provider.
/// The app keeps a security-scoped bookmark to the folder and treats it like a NAS.
/// Also used by the tests as an in-process "server".
public final class LocalFolderFileSystem: RemoteFileSystem, @unchecked Sendable {
    public let rootURL: URL
    private let securityScoped: Bool
    private let fm = FileManager.default

    public init(rootURL: URL, securityScoped: Bool = false) {
        self.rootURL = rootURL
        self.securityScoped = securityScoped
    }

    /// Resolves a bookmark created with `LocalFolderFileSystem.bookmark(for:)`.
    public convenience init(bookmark: Data) throws {
        #if canImport(Darwin)
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        self.init(rootURL: url, securityScoped: true)
        #else
        throw RemoteError.unsupported("bookmark")
        #endif
    }

    public static func bookmark(for url: URL) throws -> Data {
        #if canImport(Darwin)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        throw RemoteError.unsupported("bookmark")
        #endif
    }

    private func url(_ path: String) -> URL { rootURL.appendingRemotePath(path) }

    /// Runs `body` with the security scope open (needed for bookmarked folders).
    private func access<T>(_ body: () throws -> T) throws -> T {
        #if canImport(Darwin)
        let scoped = securityScoped && rootURL.startAccessingSecurityScopedResource()
        defer { if scoped { rootURL.stopAccessingSecurityScopedResource() } }
        #endif
        return try coordinate(body)
    }

    private func coordinate<T>(_ body: () throws -> T) throws -> T {
        #if canImport(Darwin)
        guard securityScoped else { return try body() }
        // File providers (SMB, iCloud Drive…) expect coordinated access.
        var result: Result<T, Error> = .failure(RemoteError.invalidResponse)
        var coordError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: rootURL, options: [], error: &coordError) { _ in
            result = Result { try body() }
        }
        if let coordError { throw RemoteError.network(coordError.localizedDescription) }
        return try result.get()
        #else
        return try body()
        #endif
    }

    private func item(at path: String) -> RemoteItem? {
        guard let attrs = try? fm.attributesOfItem(atPath: url(path).path) else { return nil }
        let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
        return RemoteItem(path: path, isDirectory: isDir, size: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
                          modified: attrs[.modificationDate] as? Date)
    }

    public func list(_ path: String) async throws -> [RemoteItem] {
        try access {
            let dir = url(path)
            guard fm.fileExists(atPath: dir.path) else { throw RemoteError.notFound(path) }
            return try fm.contentsOfDirectory(atPath: dir.path)
                .filter { !FileNaming.isIgnored($0) }
                .compactMap { item(at: RemotePath.join(path, $0)) }
        }
    }

    public func listRecursive(_ path: String) async throws -> [RemoteItem] {
        try access {
            var out: [RemoteItem] = []
            var queue = [RemotePath.normalize(path)]
            guard fm.fileExists(atPath: url(path).path) else { throw RemoteError.notFound(path) }
            while !queue.isEmpty {
                let dir = queue.removeFirst()
                for name in (try? fm.contentsOfDirectory(atPath: url(dir).path)) ?? [] where !FileNaming.isIgnored(name) {
                    guard let it = item(at: RemotePath.join(dir, name)) else { continue }
                    out.append(it)
                    if it.isDirectory { queue.append(it.path) }
                }
            }
            return out
        }
    }

    public func stat(_ path: String) async throws -> RemoteItem? {
        try access { item(at: RemotePath.normalize(path)) }
    }

    public func download(_ path: String, to localURL: URL) async throws {
        try access {
            let src = url(path)
            guard fm.fileExists(atPath: src.path) else { throw RemoteError.notFound(path) }
            try fm.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: localURL.path) { try fm.removeItem(at: localURL) }
            try fm.copyItem(at: src, to: localURL)
        }
    }

    @discardableResult
    public func upload(from localURL: URL, to path: String, modified: Date?) async throws -> RemoteItem? {
        try access {
            let dst = url(path)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            let tmp = dst.deletingLastPathComponent().appendingPathComponent(".upload-\(UUID().uuidString)")
            try fm.copyItem(at: localURL, to: tmp)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.moveItem(at: tmp, to: dst)
            if let modified { try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: dst.path) }
            return item(at: RemotePath.normalize(path))
        }
    }

    public func createDirectory(_ path: String) async throws {
        try access { try fm.createDirectory(at: url(path), withIntermediateDirectories: true) }
    }

    public func delete(_ path: String) async throws {
        guard RemotePath.normalize(path) != "/" else { throw RemoteError.forbidden }
        try access {
            let target = url(path)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        }
    }

    public func move(_ from: String, to: String) async throws {
        try access {
            let dst = url(to)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.moveItem(at: url(from), to: dst)
        }
    }

    public func testConnection(probeWrite: Bool, in folder: String) async throws -> ServerInfo {
        guard try await stat(folder) != nil else { throw RemoteError.notFound(folder) }
        var writable = true
        if probeWrite { writable = await probeWritable(in: folder) }
        return ServerInfo(product: "파일 앱 폴더", detail: rootURL.lastPathComponent, writable: writable)
    }
}
