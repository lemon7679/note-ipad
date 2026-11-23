import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

/// WebDAV (RFC 4918) client: Synology "WebDAV Server" package, QNAP, TrueNAS,
/// OpenMediaVault, Nextcloud/ownCloud, Apache/nginx dav.
///
/// Paths are relative to the endpoint (`baseURL`), e.g. baseURL
/// `https://nas.local:5006` and path `/home/Notes`, or baseURL
/// `https://cloud.example/remote.php/dav/files/me` and path `/Notes`.
public final class WebDAVClient: RemoteFileSystem, @unchecked Sendable {
    public let baseURL: URL
    private let authorization: String?
    private let transport: HTTPTransport
    private var depthInfinitySupported = true

    public init(baseURL: URL, username: String, password: String, tls: TLSPolicy = TLSPolicy(),
                transport: HTTPTransport? = nil) {
        self.baseURL = baseURL
        self.authorization = username.isEmpty ? nil
            : HTTPTransport.basicAuthorization(user: username, password: password)
        let credential = username.isEmpty ? nil
            : URLCredential(user: username, password: password, persistence: .forSession)
        self.transport = transport ?? HTTPTransport(tls: tls, credential: credential)
    }

    public var httpTransport: HTTPTransport { transport }

    // MARK: URLs

    /// RFC 3986 `pchar` minus "/" — what may appear unescaped inside one path segment.
    static let segmentAllowed: CharacterSet = {
        var set = CharacterSet.asciiAlphanumerics
        set.insert(charactersIn: "-._~!$&'()*+,;=:@")
        return set
    }()

    func url(for path: String, directory: Bool = false) -> URL {
        var encoded = ""
        for part in RemotePath.components(path) {
            encoded += "/" + (part.addingPercentEncoding(withAllowedCharacters: Self.segmentAllowed) ?? part)
        }
        if directory || encoded.isEmpty { encoded += "/" }
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + encoded)!
    }

    /// Server path of the endpoint root, decoded ("/remote.php/dav/files/me").
    var basePath: String {
        RemotePath.normalize(baseURL.path)
    }

    private func request(_ method: String, _ path: String, directory: Bool = false) -> URLRequest {
        var req = URLRequest(url: url(for: path, directory: directory))
        req.httpMethod = method
        if let authorization { req.setValue(authorization, forHTTPHeaderField: "Authorization") }
        return req
    }

    private func check(_ response: HTTPURLResponse, path: String, allow: Set<Int> = []) throws {
        let status = response.statusCode
        if (200..<300).contains(status) || allow.contains(status) { return }
        throw Self.error(status: status, path: path)
    }

    static func error(status: Int, path: String) -> RemoteError {
        switch status {
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404, 410: return .notFound(path)
        case 405: return .alreadyExists(path)
        case 409: return .conflict(RemotePath.parent(path))
        case 412: return .alreadyExists(path)
        case 507: return .insufficientStorage
        default: return .server(status: status, message: HTTPURLResponse.localizedString(forStatusCode: status))
        }
    }

    // MARK: PROPFIND

    static let propfindBody = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:getetag/></d:prop></d:propfind>
    """

    private func propfind(_ path: String, depth: String, directory: Bool) async throws -> [RemoteItem] {
        var req = request("PROPFIND", path, directory: directory)
        req.setValue(depth, forHTTPHeaderField: "Depth")
        req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(Self.propfindBody.utf8)
        let (data, response) = try await transport.data(req)
        try check(response, path: path)
        return try WebDAVMultistatusParser.parse(data, basePath: basePath)
    }

    public func list(_ path: String) async throws -> [RemoteItem] {
        let dir = RemotePath.normalize(path)
        let items = try await propfind(dir, depth: "1", directory: true)
        return items.filter { $0.path != dir && !FileNaming.isIgnored($0.name) }
    }

    public func listRecursive(_ path: String) async throws -> [RemoteItem] {
        let dir = RemotePath.normalize(path)
        if depthInfinitySupported {
            do {
                let items = try await propfind(dir, depth: "infinity", directory: true)
                return items.filter { item in
                    item.path != dir && !RemotePath.components(item.path).contains(where: FileNaming.isIgnored)
                }
            } catch RemoteError.forbidden {
                depthInfinitySupported = false   // most servers disable infinite depth
            } catch RemoteError.server(let status, _) where status == 400 || status == 501 {
                depthInfinitySupported = false
            }
        }
        var out: [RemoteItem] = []
        var queue = [dir]
        while !queue.isEmpty {
            try Task.checkCancellation()
            let next = queue.removeFirst()
            for item in try await list(next) {
                out.append(item)
                if item.isDirectory { queue.append(item.path) }
            }
        }
        return out
    }

    public func stat(_ path: String) async throws -> RemoteItem? {
        let p = RemotePath.normalize(path)
        do {
            let items = try await propfind(p, depth: "0", directory: false)
            return items.first { $0.path == p } ?? items.first
        } catch RemoteError.notFound {
            return nil
        }
    }

    // MARK: Transfers

    public func download(_ path: String, to localURL: URL) async throws {
        let response = try await transport.download(request("GET", path), to: localURL)
        try check(response, path: path)
    }

    @discardableResult
    public func upload(from localURL: URL, to path: String, modified: Date?) async throws -> RemoteItem? {
        var req = request("PUT", path)
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let modified {
            // Nextcloud/ownCloud keep the original modification time.
            req.setValue(String(Int(modified.timeIntervalSince1970)), forHTTPHeaderField: "X-OC-Mtime")
        }
        var (_, response) = try await transport.upload(req, fromFile: localURL)
        if response.statusCode == 409 {
            try await createDirectory(RemotePath.parent(path))
            (_, response) = try await transport.upload(req, fromFile: localURL)
        }
        try check(response, path: path)
        return try await stat(path)
    }

    // MARK: Changes

    public func createDirectory(_ path: String) async throws {
        let p = RemotePath.normalize(path)
        guard p != "/" else { return }
        let (_, response) = try await transport.data(request("MKCOL", p, directory: true))
        switch response.statusCode {
        case 200..<300, 405:
            return  // created, or already exists
        case 409:
            try await createDirectory(RemotePath.parent(p))
            let (_, retry) = try await transport.data(request("MKCOL", p, directory: true))
            try check(retry, path: p, allow: [405])
        default:
            try check(response, path: p)
        }
    }

    public func delete(_ path: String) async throws {
        let p = RemotePath.normalize(path)
        guard p != "/" else { throw RemoteError.forbidden }
        let (_, response) = try await transport.data(request("DELETE", p))
        try check(response, path: p, allow: [404])
    }

    public func move(_ from: String, to: String) async throws {
        var req = request("MOVE", from)
        req.setValue(url(for: to).absoluteString, forHTTPHeaderField: "Destination")
        req.setValue("T", forHTTPHeaderField: "Overwrite")
        var (_, response) = try await transport.data(req)
        if response.statusCode == 409 {
            try await createDirectory(RemotePath.parent(to))
            (_, response) = try await transport.data(req)
        }
        try check(response, path: from)
    }

    public func testConnection(probeWrite: Bool, in folder: String) async throws -> ServerInfo {
        var req = request("OPTIONS", folder, directory: true)
        req.setValue("0", forHTTPHeaderField: "Depth")
        let (_, options) = try await transport.data(req)
        if options.statusCode == 401 { throw RemoteError.unauthorized }
        let server = options.value(forHTTPHeaderField: "Server") ?? ""
        guard try await stat(folder) != nil else { throw RemoteError.notFound(folder) }
        var writable = true
        if probeWrite { writable = await probeWritable(in: folder) }
        return ServerInfo(product: "WebDAV", detail: server, writable: writable)
    }
}

/// Parses a 207 Multi-Status PROPFIND response.
public enum WebDAVMultistatusParser {
    public static func parse(_ data: Data, basePath: String) throws -> [RemoteItem] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse() else { throw RemoteError.invalidResponse }
        return delegate.responses.compactMap { r -> RemoteItem? in
            guard let href = r.href, r.ok else { return nil }
            guard let serverPath = decodeHref(href) else { return nil }
            guard let rel = RemotePath.relative(serverPath, to: basePath) else { return nil }
            return RemoteItem(path: rel, isDirectory: r.isCollection, size: r.length ?? 0,
                              modified: r.modified.flatMap(HTTPDate.parse), etag: r.etag.map(cleanETag))
        }
    }

    /// href may be an absolute URL or an absolute path, percent-encoded.
    static func decodeHref(_ href: String) -> String? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        var rawPath = trimmed
        if let url = URL(string: trimmed), url.scheme != nil {
            rawPath = url.path.isEmpty ? "/" : (URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path)
        }
        let decoded = rawPath.removingPercentEncoding ?? rawPath
        return RemotePath.normalize(decoded)
    }

    static func cleanETag(_ etag: String) -> String {
        var e = etag.trimmingCharacters(in: .whitespacesAndNewlines)
        if e.hasPrefix("W/") { e.removeFirst(2) }
        return e.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private struct Response {
        var href: String?
        var isCollection = false
        var length: Int64?
        var modified: String?
        var etag: String?
        var ok = true
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var responses: [Response] = []
        private var current: Response?
        private var text = ""
        // Properties are only trusted inside a propstat whose status is 2xx.
        private var propstat = Response()
        private var inPropstat = false

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            text = ""
            switch elementName {
            case "response": current = Response()
            case "propstat": inPropstat = true; propstat = Response()
            case "collection": if inPropstat { propstat.isCollection = true }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "href":
                if current != nil, !inPropstat, current?.href == nil { current?.href = value }
            case "getcontentlength": if inPropstat { propstat.length = Int64(value) }
            case "getlastmodified": if inPropstat { propstat.modified = value }
            case "getetag": if inPropstat { propstat.etag = value }
            case "status":
                if inPropstat {
                    propstat.ok = value.contains(" 2")
                } else if current != nil {
                    current?.ok = value.contains(" 2")
                }
            case "propstat":
                inPropstat = false
                if propstat.ok {
                    if propstat.isCollection { current?.isCollection = true }
                    if let l = propstat.length { current?.length = l }
                    if let m = propstat.modified { current?.modified = m }
                    if let e = propstat.etag { current?.etag = e }
                }
            case "response":
                if let c = current { responses.append(c) }
                current = nil
            default: break
            }
            text = ""
        }
    }
}

/// RFC 1123 dates used by HTTP / WebDAV ("Mon, 23 Nov 2026 07:20:00 GMT").
public enum HTTPDate {
    private static let formatters: [DateFormatter] = {
        ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"].map { format in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "GMT")
            f.dateFormat = format
            return f
        }
    }()

    public static func parse(_ string: String) -> Date? {
        for f in formatters {
            if let d = f.date(from: string) { return d }
        }
        return ISO8601DateFormatter().date(from: string)
    }

    public static func format(_ date: Date) -> String {
        formatters[0].string(from: date)
    }
}
