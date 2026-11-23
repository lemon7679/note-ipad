import Foundation

/// A file or folder on a NAS. Paths are absolute on the server ("/home/Notes/a.pdf").
public struct RemoteItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String { path }
    public var path: String
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date?
    /// Server change token (WebDAV ETag) when the server has one.
    public var etag: String?

    public init(path: String, isDirectory: Bool, size: Int64 = 0, modified: Date? = nil, etag: String? = nil) {
        self.path = RemotePath.normalize(path)
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.etag = etag
    }

    public var name: String { RemotePath.name(path) }

    /// Signature used by the sync engine to notice remote changes.
    public var signature: String {
        if isDirectory { return "dir" }
        if let etag, !etag.isEmpty { return "e:" + etag }
        let ms = Int64(((modified?.timeIntervalSince1970 ?? 0) * 1000).rounded())
        return "s:\(size):\(ms / 1000)"
    }
}

public struct ServerInfo: Equatable, Sendable {
    public var product: String
    public var detail: String
    public var writable: Bool

    public init(product: String, detail: String, writable: Bool) {
        self.product = product
        self.detail = detail
        self.writable = writable
    }

    public var summary: String {
        var parts = [product]
        if !detail.isEmpty { parts.append(detail) }
        parts.append(writable ? "쓰기 가능" : "읽기 전용")
        return parts.joined(separator: " · ")
    }
}

public enum RemoteError: Error, LocalizedError, Equatable {
    case notFound(String)
    case unauthorized
    case forbidden
    case alreadyExists(String)
    case conflict(String)
    case insufficientStorage
    case server(status: Int, message: String?)
    case network(String)
    case invalidResponse
    /// TLS certificate not trusted; carries the SHA-256 fingerprint so the user can trust it.
    case untrustedCertificate(fingerprint: String?)
    case certificateChanged(fingerprint: String)
    case twoFactorRequired
    case twoFactorInvalid
    case synology(code: Int)
    case cancelled
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let p): return "\(RemotePath.name(p).isEmpty ? p : RemotePath.name(p))을(를) NAS에서 찾을 수 없습니다."
        case .unauthorized: return "사용자 이름 또는 암호가 올바르지 않습니다."
        case .forbidden: return "이 폴더에 접근할 권한이 없습니다."
        case .alreadyExists(let p): return "\(RemotePath.name(p))이(가) 이미 있습니다."
        case .conflict(let p): return "\(p) 상위 폴더가 없습니다."
        case .insufficientStorage: return "NAS 저장 공간이 부족합니다."
        case .server(let status, let message):
            return "서버 오류 (\(status))" + (message.map { ": \($0)" } ?? "")
        case .network(let m): return "네트워크 오류: \(m)"
        case .invalidResponse: return "서버 응답을 해석할 수 없습니다."
        case .untrustedCertificate: return "서버 인증서를 신뢰할 수 없습니다. ‘자체 서명 인증서 신뢰’를 켜 주세요."
        case .certificateChanged: return "서버 인증서가 이전과 다릅니다. 보안을 위해 연결을 중단했습니다."
        case .twoFactorRequired: return "2단계 인증 코드가 필요합니다."
        case .twoFactorInvalid: return "2단계 인증 코드가 올바르지 않습니다."
        case .synology(let code): return SynologyClient.message(for: code)
        case .cancelled: return "취소되었습니다."
        case .unsupported(let what): return "지원하지 않는 기능입니다: \(what)"
        }
    }

    /// Errors that make a sync pointless to continue (every other request would fail too).
    public var stopsSync: Bool {
        switch self {
        case .unauthorized, .untrustedCertificate, .certificateChanged, .twoFactorRequired, .twoFactorInvalid,
             .insufficientStorage, .cancelled:
            return true
        default:
            return false
        }
    }

    /// Errors that mean "retrying later may work" rather than "fix the settings".
    public var isTransient: Bool {
        switch self {
        case .network, .server: return true
        default: return false
        }
    }
}

/// Uniform access to a NAS. Implemented by `WebDAVClient`, `SynologyClient` and
/// `LocalFolderFileSystem` (SMB / any Files-app location).
public protocol RemoteFileSystem: AnyObject, Sendable {
    /// Immediate children of a folder.
    func list(_ path: String) async throws -> [RemoteItem]
    /// Everything below a folder (default: breadth-first `list`).
    func listRecursive(_ path: String) async throws -> [RemoteItem]
    /// nil when nothing exists at `path`.
    func stat(_ path: String) async throws -> RemoteItem?
    func download(_ path: String, to localURL: URL) async throws
    /// Uploads a file, replacing an existing one. Returns the new item when cheaply known.
    @discardableResult
    func upload(from localURL: URL, to path: String, modified: Date?) async throws -> RemoteItem?
    /// Creates a folder and any missing parents; succeeds if it already exists.
    func createDirectory(_ path: String) async throws
    /// Deletes a file or a whole folder; succeeds if it is already gone.
    func delete(_ path: String) async throws
    func move(_ from: String, to: String) async throws
    func testConnection(probeWrite: Bool, in folder: String) async throws -> ServerInfo
}

extension RemoteFileSystem {
    public func listRecursive(_ path: String) async throws -> [RemoteItem] {
        var out: [RemoteItem] = []
        var queue = [RemotePath.normalize(path)]
        while !queue.isEmpty {
            try Task.checkCancellation()
            let dir = queue.removeFirst()
            for item in try await list(dir) where !FileNaming.isIgnored(item.name) {
                out.append(item)
                if item.isDirectory { queue.append(item.path) }
            }
        }
        return out
    }

    /// Writes and deletes a small probe folder to check write permission.
    public func probeWritable(in folder: String) async -> Bool {
        let probe = RemotePath.join(folder, ".note-write-test-\(UUID().uuidString.prefix(8))")
        do {
            try await createDirectory(probe)
            try await delete(probe)
            return true
        } catch {
            return false
        }
    }
}
