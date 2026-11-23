import Foundation

/// Slash-separated paths used for remote servers and for locations inside a
/// library root ("/", "/강의", "/강의/선형대수.inknote"). Always absolute,
/// never with a trailing slash (except the root itself).
public enum RemotePath {
    public static let root = "/"

    public static func normalize(_ path: String) -> String {
        var parts: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(part))
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    public static func join(_ base: String, _ child: String) -> String {
        normalize(base + "/" + child)
    }

    public static func components(_ path: String) -> [String] {
        normalize(path).split(separator: "/").map(String.init)
    }

    public static func name(_ path: String) -> String {
        components(path).last ?? ""
    }

    public static func parent(_ path: String) -> String {
        var parts = components(path)
        if !parts.isEmpty { parts.removeLast() }
        return "/" + parts.joined(separator: "/")
    }

    /// Number of components ("/" = 0, "/a/b" = 2).
    public static func depth(_ path: String) -> Int {
        components(path).count
    }

    /// True when `ancestor` is `path` itself or one of its parents.
    public static func isAncestor(_ ancestor: String, of path: String) -> Bool {
        let a = normalize(ancestor), p = normalize(path)
        if a == "/" || a == p { return true }
        return p.hasPrefix(a + "/")
    }

    /// `path` expressed relative to `root` ("/a/b/c" in "/a" → "/b/c"), or nil
    /// when `path` is outside `root`.
    public static func relative(_ path: String, to root: String) -> String? {
        let r = normalize(root), p = normalize(path)
        guard isAncestor(r, of: p) else { return nil }
        if r == "/" { return p }
        if p == r { return "/" }
        return String(p.dropFirst(r.count))
    }

    /// Lower-cased extension of the last component ("" when none).
    public static func pathExtension(_ path: String) -> String {
        let n = name(path)
        guard let dot = n.lastIndex(of: "."), dot != n.startIndex else { return "" }
        return n[n.index(after: dot)...].lowercased()
    }
}

/// File names that are safe on every server and file system we talk to.
public enum FileNaming {
    public static let notebookExtension = "inknote"

    /// Characters SMB / Windows / Synology reject in names.
    private static let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\u{0}")

    public static func sanitize(_ name: String, fallback: String = "제목 없음") -> String {
        var cleaned = String(name.unicodeScalars.map { forbidden.contains($0) ? "-" : Character($0) })
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > 120 { cleaned = String(cleaned.prefix(120)) }
        return cleaned.isEmpty ? fallback : cleaned
    }

    /// `base.ext`, or `base 2.ext`, `base 3.ext`… — the first name `exists` rejects.
    public static func unique(base: String, ext: String, exists: (String) -> Bool) -> String {
        let suffix = ext.isEmpty ? "" : "." + ext
        var candidate = base + suffix
        var n = 2
        while exists(candidate) {
            candidate = "\(base) \(n)\(suffix)"
            n += 1
        }
        return candidate
    }

    /// "물리 보고서 (충돌 사본 iPad 2026-11-23 1402).inknote"
    public static func conflictCopyName(for name: String, device: String, date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmm"
        let (base, ext) = split(name)
        let tag = "(충돌 사본 \(device) \(f.string(from: date)))"
        return ext.isEmpty ? "\(base) \(tag)" : "\(base) \(tag).\(ext)"
    }

    public static func split(_ name: String) -> (base: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }

    /// Names the library and the sync engine never show or transfer.
    public static func isIgnored(_ name: String) -> Bool {
        if name.hasPrefix(".") || name.hasPrefix("@") || name.hasPrefix("~$") { return true }
        switch name {
        case "#recycle", "#snapshot", "Thumbs.db", "desktop.ini", "Icon\r": return true
        default: return false
        }
    }

    /// The enclosing `.inknote` package of a path ("/a/b.inknote/pages/x.ink" → "/a/b.inknote").
    public static func packageRoot(of path: String) -> String? {
        var acc: [String] = []
        for part in RemotePath.components(path) {
            acc.append(part)
            if part.lowercased().hasSuffix("." + notebookExtension) {
                return "/" + acc.joined(separator: "/")
            }
        }
        return nil
    }
}

extension CharacterSet {
    /// ASCII letters and digits only (`.alphanumerics` also admits every Unicode letter).
    public static let asciiAlphanumerics = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
}

extension URL {
    /// Appends a slash path ("/a/b") to a directory URL.
    public func appendingRemotePath(_ path: String) -> URL {
        var url = self
        for part in RemotePath.components(path) {
            url.appendPathComponent(part)
        }
        return url
    }
}
