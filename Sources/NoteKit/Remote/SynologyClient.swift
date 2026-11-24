import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Synology DSM File Station Web API client (DSM 6.2 / 7.x).
///
/// Works with nothing but the default DSM web port (5000/5001) — no WebDAV
/// package needed — and supports 2-step verification: the first login with an
/// OTP code returns a device token that skips the code afterwards.
/// Paths are shared-folder paths: "/home/Notes", "/homes/<user>/Notes", "/docs".
public final class SynologyClient: RemoteFileSystem, @unchecked Sendable {
    public let baseURL: URL
    public let username: String
    private let password: String
    /// One-time code for the next login (2-step verification).
    public var otpCode: String?
    /// Device token from a previous OTP login ("did"); persisted by the app in the keychain.
    public private(set) var deviceToken: String?
    public var onDeviceToken: (@Sendable (String) -> Void)?

    private let transport: HTTPTransport
    private let lock = NSLock()
    private var sid: String?
    /// Some DSM builds reject the optional upload `mtime` field; after the first such refusal it is left out.
    private var sendsMtime = true
    private static let deviceName = "Note iPad"
    private static let mtimeSuspectErrors: Set<Int> = [400, 401]

    public init(baseURL: URL, username: String, password: String, deviceToken: String? = nil,
                tls: TLSPolicy = TLSPolicy(), transport: HTTPTransport? = nil) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.deviceToken = deviceToken
        self.transport = transport ?? HTTPTransport(tls: tls, timeout: 60)
    }

    public var httpTransport: HTTPTransport { transport }

    // MARK: API plumbing

    /// Query-string escaping that also escapes "+" and "&" (DSM decodes "+" as space).
    static func encode(_ value: String) -> String {
        var allowed = CharacterSet.asciiAlphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func formBody(_ params: [(String, String)]) -> Data {
        Data(params.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&").utf8)
    }

    /// JSON array parameter: ["/home/a"].
    static func jsonArray(_ values: [String]) -> String {
        let quoted = values.map { value -> String in
            let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"" + escaped + "\""
        }
        return "[" + quoted.joined(separator: ",") + "]"
    }

    private var entryURL: URL { baseURL.appendingPathComponent("webapi").appendingPathComponent("entry.cgi") }

    private struct Envelope: Decodable {
        struct Failure: Decodable { let code: Int }
        let success: Bool
        let error: Failure?
    }

    private func currentSID() -> String? {
        lock.lock(); defer { lock.unlock() }
        return sid
    }

    private func setSID(_ value: String?) {
        lock.lock(); sid = value; lock.unlock()
    }

    private var sendsModificationTime: Bool {
        lock.lock(); defer { lock.unlock() }
        return sendsMtime
    }

    private func setSendsModificationTime(_ value: Bool) {
        lock.lock(); sendsMtime = value; lock.unlock()
    }

    /// POSTs an API call and returns the `data` object. Re-logins once when the session expired.
    @discardableResult
    func call(_ api: String, version: Int, method: String, _ params: [(String, String)] = [],
              retrying: Bool = true) async throws -> [String: Any] {
        if api != "SYNO.API.Auth", currentSID() == nil { try await login() }
        var all: [(String, String)] = [("api", api), ("version", String(version)), ("method", method)]
        all.append(contentsOf: params)
        if api != "SYNO.API.Auth", let sid = currentSID() { all.append(("_sid", sid)) }
        var req = URLRequest(url: entryURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formBody(all)
        let (data, response) = try await transport.data(req)
        guard (200..<300).contains(response.statusCode) else {
            throw RemoteError.server(status: response.statusCode, message: nil)
        }
        let json = try Self.decodeData(data)
        if let code = json.errorCode {
            if retrying, api != "SYNO.API.Auth", [106, 107, 119].contains(code) {
                setSID(nil)
                return try await call(api, version: version, method: method, params, retrying: false)
            }
            throw Self.map(code: code, api: api)
        }
        return json.payload
    }

    struct Decoded {
        var payload: [String: Any]
        var errorCode: Int?
        /// The rest of DSM's `error` object (e.g. `{"errors":[…]}`), shortened.
        var detail: String? = nil
    }

    static func decodeData(_ data: Data) throws -> Decoded {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let success = obj["success"] as? Bool else { throw RemoteError.invalidResponse }
        if success { return Decoded(payload: obj["data"] as? [String: Any] ?? [:], errorCode: nil) }
        let error = obj["error"] as? [String: Any]
        let code = error?["code"] as? Int ?? 100
        var detail: String?
        if var rest = error {
            rest["code"] = nil
            if !rest.isEmpty, let json = try? JSONSerialization.data(withJSONObject: rest, options: [.sortedKeys]) {
                detail = String(decoding: json.prefix(200), as: UTF8.self)
            }
        }
        return Decoded(payload: [:], errorCode: code, detail: detail)
    }

    static func map(code: Int, api: String) -> RemoteError {
        if api == "SYNO.API.Auth" {
            switch code {
            case 400, 401, 402: return .unauthorized
            case 403: return .twoFactorRequired
            case 404: return .twoFactorInvalid
            default: return .synology(code: code)
            }
        }
        switch code {
        case 105, 407: return .forbidden
        case 408: return .notFound("")
        case 414: return .alreadyExists("")
        case 416: return .insufficientStorage
        default: return .synology(code: code)
        }
    }

    public static func message(for code: Int) -> String {
        switch code {
        case 100: return "알 수 없는 DSM 오류입니다."
        case 101, 102, 103, 104: return "DSM이 이 요청을 지원하지 않습니다. DSM을 업데이트해 주세요."
        case 105: return "권한이 없습니다."
        case 400: return "DSM이 파일 작업 요청을 이해하지 못했습니다 (400)."
        case 401: return "DSM이 파일 작업을 거부했습니다 (401)."
        case 402: return "NAS가 바빠 파일 작업을 하지 못했습니다 (402)."
        case 403: return "이 사용자는 이 파일 작업을 할 수 없습니다 (403)."
        case 404: return "이 사용자 그룹은 이 파일 작업을 할 수 없습니다 (404)."
        case 106: return "세션이 만료되었습니다."
        case 107: return "다른 곳에서 로그인하여 세션이 끊어졌습니다."
        case 119: return "세션 ID를 찾을 수 없습니다."
        case 406: return "이 계정은 2단계 인증을 켜야 로그인할 수 있습니다."
        case 407: return "로그인 시도가 너무 많아 IP가 차단되었습니다."
        case 408: return "파일 또는 폴더가 없습니다."
        case 409, 410: return "암호가 만료되었습니다. DSM에서 암호를 변경해 주세요."
        case 414: return "같은 이름의 파일이 이미 있습니다."
        case 415: return "디스크 할당량을 초과했습니다."
        case 416: return "NAS 저장 공간이 부족합니다."
        case 418: return "잘못된 경로입니다."
        case 419: return "잘못된 파일 이름입니다."
        case 1800, 1801, 1802, 1803, 1804, 1805: return "업로드에 실패했습니다 (\(code))."
        default: return "DSM 오류 \(code)"
        }
    }

    // MARK: Session

    public func login() async throws {
        var params: [(String, String)] = [
            ("account", username), ("passwd", password), ("session", "FileStation"), ("format", "sid"),
        ]
        if let otp = otpCode, !otp.isEmpty {
            params.append(("otp_code", otp))
            params.append(("enable_device_token", "yes"))
            params.append(("device_name", Self.deviceName))
        } else if let did = deviceToken, !did.isEmpty {
            params.append(("device_id", did))
            params.append(("device_name", Self.deviceName))
        }
        let data = try await call("SYNO.API.Auth", version: 6, method: "login", params)
        guard let sid = data["sid"] as? String else { throw RemoteError.invalidResponse }
        setSID(sid)
        otpCode = nil
        if let did = (data["did"] as? String) ?? (data["device_id"] as? String), !did.isEmpty {
            deviceToken = did
            onDeviceToken?(did)
        }
    }

    public func logout() async {
        guard currentSID() != nil else { return }
        _ = try? await call("SYNO.API.Auth", version: 6, method: "logout", [("session", "FileStation")])
        setSID(nil)
    }

    // MARK: Listing

    static func item(from file: [String: Any]) -> RemoteItem? {
        guard let path = file["path"] as? String else { return nil }
        let additional = file["additional"] as? [String: Any]
        let size = (additional?["size"] as? NSNumber)?.int64Value ?? 0
        let time = additional?["time"] as? [String: Any]
        let mtime = (time?["mtime"] as? NSNumber)?.doubleValue
        return RemoteItem(path: path, isDirectory: file["isdir"] as? Bool ?? false, size: size,
                          modified: mtime.map { Date(timeIntervalSince1970: $0) })
    }

    public func list(_ path: String) async throws -> [RemoteItem] {
        let folder = RemotePath.normalize(path)
        var out: [RemoteItem] = []
        var offset = 0
        while true {
            let data = try await call("SYNO.FileStation.List", version: 2, method: "list", [
                ("folder_path", folder), ("offset", String(offset)), ("limit", "1000"),
                ("additional", Self.jsonArray(["size", "time"])),
            ])
            let files = data["files"] as? [[String: Any]] ?? []
            out.append(contentsOf: files.compactMap(Self.item(from:)))
            let total = (data["total"] as? NSNumber)?.intValue ?? out.count
            offset += files.count
            if files.isEmpty || offset >= total { break }
        }
        return out.filter { !FileNaming.isIgnored($0.name) }
    }

    /// Shared folders visible to the user ("/home", "/docs" …), for the folder picker root.
    public func listShares() async throws -> [RemoteItem] {
        let data = try await call("SYNO.FileStation.List", version: 2, method: "list_share", [
            ("additional", Self.jsonArray(["time"])),
        ])
        let shares = data["shares"] as? [[String: Any]] ?? []
        return shares.compactMap { share in
            guard let path = share["path"] as? String else { return nil }
            return RemoteItem(path: path, isDirectory: true)
        }
    }

    public func stat(_ path: String) async throws -> RemoteItem? {
        let p = RemotePath.normalize(path)
        if p == "/" { return RemoteItem(path: "/", isDirectory: true) }
        do {
            let data = try await call("SYNO.FileStation.List", version: 2, method: "getinfo", [
                ("path", Self.jsonArray([p])), ("additional", Self.jsonArray(["size", "time"])),
            ])
            guard let file = (data["files"] as? [[String: Any]])?.first else { return nil }
            if file["code"] != nil { return nil }  // per-item error 408: no such file
            return Self.item(from: file)
        } catch RemoteError.notFound {
            return nil
        }
    }

    // MARK: Transfers

    public func download(_ path: String, to localURL: URL) async throws {
        if currentSID() == nil { try await login() }
        func makeRequest() -> URLRequest {
            var comps = URLComponents(url: entryURL, resolvingAgainstBaseURL: false)!
            let query: [(String, String)] = [
                ("api", "SYNO.FileStation.Download"), ("version", "2"), ("method", "download"),
                ("path", RemotePath.normalize(path)), ("mode", "download"), ("_sid", currentSID() ?? ""),
            ]
            comps.percentEncodedQuery = query.map { "\(Self.encode($0.0))=\(Self.encode($0.1))" }.joined(separator: "&")
            return URLRequest(url: comps.url!)
        }
        var response = try await transport.download(makeRequest(), to: localURL)
        if Self.isJSON(response) {
            // DSM answers errors with a small JSON body instead of the file.
            let data = (try? Data(contentsOf: localURL)) ?? Data()
            try? FileManager.default.removeItem(at: localURL)
            let code = (try? Self.decodeData(data))?.errorCode ?? 100
            guard [106, 107, 119].contains(code) else { throw Self.map(code: code, api: "SYNO.FileStation.Download") }
            setSID(nil)
            try await login()
            response = try await transport.download(makeRequest(), to: localURL)
            if Self.isJSON(response) {
                try? FileManager.default.removeItem(at: localURL)
                throw RemoteError.synology(code: code)
            }
        }
        guard (200..<300).contains(response.statusCode) else {
            throw RemoteError.server(status: response.statusCode, message: nil)
        }
    }

    private static func isJSON(_ response: HTTPURLResponse) -> Bool {
        (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().contains("application/json")
    }

    @discardableResult
    public func upload(from localURL: URL, to path: String, modified: Date?) async throws -> RemoteItem? {
        let target = RemotePath.normalize(path)
        let mtime = sendsModificationTime ? modified : nil
        do {
            try await uploadOnce(localURL, target, mtime, retrying: true)
        } catch RemoteError.synology(let code, let detail) where mtime != nil && Self.mtimeSuspectErrors.contains(code) {
            // Some DSM builds reject the optional `mtime` field: retry without it, and stop sending it if that works.
            do {
                try await uploadOnce(localURL, target, nil, retrying: true)
            } catch RemoteError.synology(let code2, _) where code2 == code {
                throw RemoteError.synology(code: code, detail: detail)
            }
            setSendsModificationTime(false)
        }
        return try await stat(target)
    }

    private func uploadOnce(_ localURL: URL, _ target: String, _ modified: Date?, retrying: Bool) async throws {
        if currentSID() == nil { try await login() }
        let boundary = "NoteBoundary-" + UUID().uuidString
        let bodyURL = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        var fields: [(String, String)] = [
            ("path", RemotePath.parent(target)), ("create_parents", "true"), ("overwrite", "true"),
        ]
        if let modified { fields.append(("mtime", String(Int64(modified.timeIntervalSince1970 * 1000)))) }
        try Self.writeMultipart(to: bodyURL, boundary: boundary, fields: fields, fileField: "file",
                                fileName: RemotePath.name(target), fileURL: localURL)

        var comps = URLComponents(url: entryURL, resolvingAgainstBaseURL: false)!
        comps.percentEncodedQuery = [
            ("api", "SYNO.FileStation.Upload"), ("version", "2"), ("method", "upload"), ("_sid", currentSID() ?? ""),
        ].map { "\(Self.encode($0.0))=\(Self.encode($0.1))" }.joined(separator: "&")
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await transport.upload(req, fromFile: bodyURL)
        guard (200..<300).contains(response.statusCode) else {
            throw RemoteError.server(status: response.statusCode, message: nil)
        }
        let decoded = try Self.decodeData(data)
        if let code = decoded.errorCode {
            if retrying, [106, 107, 119].contains(code) {
                setSID(nil)
                try await uploadOnce(localURL, target, modified, retrying: false)
                return
            }
            // Keep what DSM said (e.g. {"code":401,"errors":[…]}) so a failure can be diagnosed.
            let mapped = Self.map(code: code, api: "SYNO.FileStation.Upload")
            if case .synology = mapped { throw RemoteError.synology(code: code, detail: decoded.detail) }
            throw mapped
        }
    }

    /// multipart/form-data with the file part last (File Station requires that order).
    static func writeMultipart(to url: URL, boundary: String, fields: [(String, String)], fileField: String,
                               fileName: String, fileURL: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        func write(_ s: String) { out.write(Data(s.utf8)) }
        for (name, value) in fields {
            write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        let quotedName = fileName.replacingOccurrences(of: "\"", with: "%22")
        write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(quotedName)\"\r\n")
        write("Content-Type: application/octet-stream\r\n\r\n")
        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        while true {
            let chunk = input.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            out.write(chunk)
        }
        write("\r\n--\(boundary)--\r\n")
    }

    // MARK: Changes

    public func createDirectory(_ path: String) async throws {
        let p = RemotePath.normalize(path)
        guard RemotePath.depth(p) > 1 else { return }  // shared folders cannot be created here
        do {
            try await call("SYNO.FileStation.CreateFolder", version: 2, method: "create", [
                ("folder_path", Self.jsonArray([RemotePath.parent(p)])),
                ("name", Self.jsonArray([RemotePath.name(p)])),
                ("force_parent", "true"),
            ])
        } catch RemoteError.alreadyExists {
            return
        }
    }

    public func delete(_ path: String) async throws {
        let p = RemotePath.normalize(path)
        guard RemotePath.depth(p) > 1 else { throw RemoteError.forbidden }
        do {
            try await call("SYNO.FileStation.Delete", version: 2, method: "delete", [
                ("path", Self.jsonArray([p])), ("recursive", "true"),
            ])
        } catch RemoteError.notFound {
            return
        }
    }

    public func move(_ from: String, to: String) async throws {
        let src = RemotePath.normalize(from), dst = RemotePath.normalize(to)
        if RemotePath.parent(src) == RemotePath.parent(dst) {
            try await rename(src, to: RemotePath.name(dst))
            return
        }
        // Move into the destination folder under the source name, then rename if needed.
        try await createDirectory(RemotePath.parent(dst))
        let started = try await call("SYNO.FileStation.CopyMove", version: 3, method: "start", [
            ("path", Self.jsonArray([src])), ("dest_folder_path", RemotePath.parent(dst)),
            ("overwrite", "true"), ("remove_src", "true"),
        ])
        guard let taskID = started["taskid"] as? String else { throw RemoteError.invalidResponse }
        while true {
            try await Task.sleep(nanoseconds: 300_000_000)
            let status = try await call("SYNO.FileStation.CopyMove", version: 3, method: "status", [("taskid", taskID)])
            if status["finished"] as? Bool == true { break }
        }
        if RemotePath.name(src) != RemotePath.name(dst) {
            try await rename(RemotePath.join(RemotePath.parent(dst), RemotePath.name(src)), to: RemotePath.name(dst))
        }
    }

    private func rename(_ path: String, to name: String) async throws {
        try await call("SYNO.FileStation.Rename", version: 2, method: "rename", [
            ("path", Self.jsonArray([path])), ("name", Self.jsonArray([name])),
        ])
    }

    public func testConnection(probeWrite: Bool, in folder: String) async throws -> ServerInfo {
        setSID(nil)
        try await login()
        let info = (try? await call("SYNO.FileStation.Info", version: 2, method: "get")) ?? [:]
        let host = info["hostname"] as? String ?? ""
        if RemotePath.depth(folder) > 0 {
            guard try await stat(folder) != nil else { throw RemoteError.notFound(folder) }
        }
        var writable = true
        if probeWrite && RemotePath.depth(folder) > 1 { writable = await probeWritable(in: folder) }
        return ServerInfo(product: "Synology DSM", detail: host, writable: writable)
    }
}
