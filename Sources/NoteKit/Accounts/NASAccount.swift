import Foundation
#if canImport(Security)
import Security
#endif

public enum NASKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case synology
    case webdav
    case filesFolder

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .synology: return "Synology DSM"
        case .webdav: return "WebDAV"
        case .filesFolder: return "SMB · 파일 앱"
        }
    }

    public var symbolName: String {
        switch self {
        case .synology: return "server.rack"
        case .webdav: return "globe"
        case .filesFolder: return "externaldrive.connected.to.line.below"
        }
    }
}

public struct SyncOptions: Codable, Hashable, Sendable {
    /// Sync on launch, on return to foreground, after edits and every few minutes.
    public var autoSync: Bool = true
    /// Skip automatic syncs on cellular.
    public var wifiOnly: Bool = false
    /// PDFs and other files (not notebooks) are listed but downloaded only when opened.
    public var downloadOnDemand: Bool = true
    /// Resolve conflicts without asking by keeping both versions.
    public var keepBothOnConflict: Bool = false
    /// Also write "<notebook>.pdf" (ink flattened) next to each notebook.
    public var exportPDFCopies: Bool = false

    public init() {}
}

/// A connected NAS. Secrets (password, Synology device token) live in the keychain.
public struct NASAccount: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: NASKind
    public var host: String
    /// nil = protocol default.
    public var port: Int?
    public var useHTTPS: Bool
    /// WebDAV endpoint path on the server ("/" or "/remote.php/dav/files/me").
    public var endpointPath: String
    public var username: String
    /// Remote folder mirrored into the app ("/home/Notes").
    public var syncFolder: String
    public var allowSelfSigned: Bool
    public var pinnedCertificateSHA256: String?
    /// Files-app folder (SMB share…), security-scoped bookmark.
    public var bookmark: Data?
    public var folderDisplayName: String?
    public var options: SyncOptions
    public var created: Date
    public var lastSync: Date?

    public init(id: UUID = UUID(), name: String = "", kind: NASKind = .synology, host: String = "", port: Int? = nil,
                useHTTPS: Bool = true, endpointPath: String = "/", username: String = "", syncFolder: String = "/",
                allowSelfSigned: Bool = true) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port
        self.useHTTPS = useHTTPS
        self.endpointPath = endpointPath
        self.username = username
        self.syncFolder = syncFolder
        self.allowSelfSigned = allowSelfSigned
        self.pinnedCertificateSHA256 = nil
        self.bookmark = nil
        self.folderDisplayName = nil
        self.options = SyncOptions()
        self.created = Date()
        self.lastSync = nil
    }

    public var defaultPort: Int {
        switch kind {
        case .synology: return useHTTPS ? 5001 : 5000
        case .webdav: return useHTTPS ? 5006 : 5005
        case .filesFolder: return 0
        }
    }

    public var effectivePort: Int { port ?? defaultPort }

    /// Server URL (DSM web root, or the WebDAV endpoint).
    public var baseURL: URL? {
        var trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] where trimmedHost.lowercased().hasPrefix(prefix) {
            trimmedHost = String(trimmedHost.dropFirst(prefix.count))
        }
        while trimmedHost.hasSuffix("/") { trimmedHost.removeLast() }
        guard !trimmedHost.isEmpty else { return nil }
        var comps = URLComponents()
        comps.scheme = useHTTPS ? "https" : "http"
        if trimmedHost.contains(":"), !trimmedHost.hasPrefix("["), trimmedHost.filter({ $0 == ":" }).count > 1 {
            comps.host = "[\(trimmedHost)]"  // IPv6 literal
        } else {
            comps.host = trimmedHost
        }
        comps.port = effectivePort
        if kind == .webdav {
            let path = RemotePath.normalize(endpointPath)
            comps.path = path == "/" ? "" : path
        }
        return comps.url
    }

    public var displayAddress: String {
        switch kind {
        case .filesFolder: return folderDisplayName ?? "파일 앱 폴더"
        default:
            let scheme = useHTTPS ? "HTTPS" : "HTTP"
            return "\(host):\(effectivePort) · \(scheme)"
        }
    }

    public var passwordKey: String { "password.\(id.uuidString)" }
    public var deviceTokenKey: String { "synology-device.\(id.uuidString)" }
}

// MARK: - Secrets

public protocol CredentialStore: AnyObject, Sendable {
    func secret(for key: String) -> String?
    func setSecret(_ value: String?, for key: String)
}

public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var values: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func secret(for key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    public func setSecret(_ value: String?, for key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }
}

#if canImport(Security)
/// Passwords in the iOS keychain (this device only, available after first unlock
/// so background syncs work).
public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    private let service: String

    public init(service: String = "com.lemon7679.note.nas") {
        self.service = service
    }

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    public func secret(for key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ value: String?, for key: String) {
        SecItemDelete(query(key) as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var q = query(key)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}
#endif

// MARK: - Persistence

/// accounts.json (no secrets) in Application Support.
public final class AccountStore: @unchecked Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    // Dates as raw numbers: lossless round trips (ISO 8601 drops sub-seconds).
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    public func load() -> [NASAccount] {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([NASAccount].self, from: data) else { return [] }
        return list
    }

    public func save(_ accounts: [NASAccount]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(accounts).write(to: fileURL, options: .atomic)
    }
}

// MARK: - Clients

public enum NASConnection {
    public enum ConnectionError: Error, LocalizedError {
        case invalidAddress
        case missingFolder

        public var errorDescription: String? {
            switch self {
            case .invalidAddress: return "서버 주소를 확인해 주세요."
            case .missingFolder: return "파일 앱 폴더를 다시 선택해 주세요."
            }
        }
    }

    /// Builds the client for an account. `onPin` receives a newly trusted certificate
    /// fingerprint, `onDeviceToken` a Synology 2-step device token — both to be saved.
    public static func makeFileSystem(for account: NASAccount, credentials: CredentialStore,
                                      otpCode: String? = nil,
                                      onPin: (@Sendable (String) -> Void)? = nil,
                                      onDeviceToken: (@Sendable (String) -> Void)? = nil) throws -> RemoteFileSystem {
        let tls = TLSPolicy(allowSelfSigned: account.allowSelfSigned, pinnedSHA256: account.pinnedCertificateSHA256)
        let password = credentials.secret(for: account.passwordKey) ?? ""
        switch account.kind {
        case .synology:
            guard let url = account.baseURL else { throw ConnectionError.invalidAddress }
            let client = SynologyClient(baseURL: url, username: account.username, password: password,
                                        deviceToken: credentials.secret(for: account.deviceTokenKey), tls: tls)
            client.otpCode = otpCode
            client.httpTransport.onCertificatePinned = onPin
            client.onDeviceToken = onDeviceToken
            return client
        case .webdav:
            guard let url = account.baseURL else { throw ConnectionError.invalidAddress }
            let client = WebDAVClient(baseURL: url, username: account.username, password: password, tls: tls)
            client.httpTransport.onCertificatePinned = onPin
            return client
        case .filesFolder:
            guard let bookmark = account.bookmark else { throw ConnectionError.missingFolder }
            return try LocalFolderFileSystem(bookmark: bookmark)
        }
    }
}
