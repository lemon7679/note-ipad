import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

/// TLS rules for one NAS. Home NAS boxes very often use self-signed
/// certificates on a LAN IP; with `allowSelfSigned` the first certificate seen
/// is pinned (trust on first use) and any later change is refused.
public struct TLSPolicy: Equatable, Sendable {
    public var allowSelfSigned: Bool
    public var pinnedSHA256: String?

    public init(allowSelfSigned: Bool = false, pinnedSHA256: String? = nil) {
        self.allowSelfSigned = allowSelfSigned
        self.pinnedSHA256 = pinnedSHA256
    }
}

/// URLSession wrapper with async calls that work the same on iOS and Linux,
/// cancellation, and the TLS policy above.
public final class HTTPTransport: NSObject, @unchecked Sendable {
    public private(set) var tls: TLSPolicy
    /// Called with the fingerprint of an accepted self-signed certificate (to pin it).
    public var onCertificatePinned: (@Sendable (String) -> Void)?
    /// Fingerprint of the last certificate that was rejected (for "trust this certificate?" UI).
    public private(set) var lastRejectedFingerprint: String?

    private var session: URLSession!
    private var basicCredential: URLCredential?

    public init(tls: TLSPolicy = TLSPolicy(), timeout: TimeInterval = 30, credential: URLCredential? = nil) {
        self.tls = tls
        self.basicCredential = credential
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = 60 * 60
        config.httpMaximumConnectionsPerHost = 4
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    deinit { session?.finishTasksAndInvalidate() }

    public func invalidate() { session.invalidateAndCancel() }

    // MARK: Calls

    public func data(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
                let task = session.dataTask(with: request) { [weak self] data, response, error in
                    if let error {
                        cont.resume(throwing: self?.map(error) ?? RemoteError.network(error.localizedDescription))
                        return
                    }
                    guard let http = response as? HTTPURLResponse else {
                        cont.resume(throwing: RemoteError.invalidResponse)
                        return
                    }
                    cont.resume(returning: (data ?? Data(), http))
                }
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// Downloads into `destination` (replacing it). Non-2xx responses throw with the body discarded.
    public func download(_ request: URLRequest, to destination: URL) async throws -> HTTPURLResponse {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<HTTPURLResponse, Error>) in
                let task = session.downloadTask(with: request) { [weak self] location, response, error in
                    if let error {
                        cont.resume(throwing: self?.map(error) ?? RemoteError.network(error.localizedDescription))
                        return
                    }
                    guard let http = response as? HTTPURLResponse, let location else {
                        cont.resume(throwing: RemoteError.invalidResponse)
                        return
                    }
                    if (200..<300).contains(http.statusCode) {
                        do {
                            let fm = FileManager.default
                            try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                                   withIntermediateDirectories: true)
                            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                            try fm.moveItem(at: location, to: destination)
                        } catch {
                            cont.resume(throwing: error)
                            return
                        }
                    }
                    cont.resume(returning: http)
                }
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    public func upload(_ request: URLRequest, fromFile file: URL) async throws -> (Data, HTTPURLResponse) {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
                let task = session.uploadTask(with: request, fromFile: file) { [weak self] data, response, error in
                    if let error {
                        cont.resume(throwing: self?.map(error) ?? RemoteError.network(error.localizedDescription))
                        return
                    }
                    guard let http = response as? HTTPURLResponse else {
                        cont.resume(throwing: RemoteError.invalidResponse)
                        return
                    }
                    cont.resume(returning: (data ?? Data(), http))
                }
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    private func map(_ error: Error) -> Error {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCancelled:
                if let fp = lastRejectedFingerprint { return RemoteError.untrustedCertificate(fingerprint: fp) }
                return RemoteError.cancelled
            case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid,
                 NSURLErrorSecureConnectionFailed:
                return RemoteError.untrustedCertificate(fingerprint: lastRejectedFingerprint)
            default:
                return RemoteError.network(ns.localizedDescription)
            }
        }
        return error
    }

    /// "Basic dXNlcjpwYXNz"
    public static func basicAuthorization(user: String, password: String) -> String {
        "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
    }
}

private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func set(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let t = task
        lock.unlock()
        t?.cancel()
    }
}

extension HTTPTransport: URLSessionDelegate, URLSessionTaskDelegate {
    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        #if canImport(Security)
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let fingerprint = Self.leafFingerprint(trust)
        if let pinned = tls.pinnedSHA256 {
            // A pinned certificate is accepted only while it stays the same.
            if fingerprint == pinned {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                lastRejectedFingerprint = fingerprint
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
            return
        }
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if tls.allowSelfSigned, let fingerprint {
            tls.pinnedSHA256 = fingerprint
            onCertificatePinned?(fingerprint)
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            lastRejectedFingerprint = fingerprint
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
        #else
        completionHandler(.performDefaultHandling, nil)
        #endif
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodHTTPDigest || method == NSURLAuthenticationMethodHTTPBasic,
           let credential = basicCredential, challenge.previousFailureCount == 0 {
            completionHandler(.useCredential, credential)
            return
        }
        #if canImport(Security)
        if method == NSURLAuthenticationMethodServerTrust {
            self.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
            return
        }
        #endif
        completionHandler(.performDefaultHandling, nil)
    }

    #if canImport(Security)
    static func leafFingerprint(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return nil
        }
        let der = SecCertificateCopyData(leaf) as Data
        #if canImport(CryptoKit)
        return SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
        #else
        return nil
        #endif
    }
    #endif
}
