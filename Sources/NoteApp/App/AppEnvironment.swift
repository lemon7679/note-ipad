#if canImport(UIKit)
import Foundation
import Network
import NoteKit

/// Where everything lives on the iPad.
enum AppPaths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Note", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var caches: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Note", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// "이 iPad" library: the app's Documents folder (also visible in the Files app).
    static var localLibrary: URL { documents }

    /// Local mirror of a NAS account's notes folder (not visible in Files, never purged).
    static func mirror(for id: UUID) -> URL {
        var url = support.appendingPathComponent("Mirrors/\(id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true   // the NAS is the backup
        try? url.setResourceValues(values)
        return url
    }

    static func syncState(for id: UUID) -> URL { support.appendingPathComponent("Sync/\(id.uuidString).json") }
    static func trash(for source: LibrarySource) -> URL { support.appendingPathComponent("Trash/\(source.id)", isDirectory: true) }
    static var accountsFile: URL { support.appendingPathComponent("accounts.json") }
    static var remoteDownloads: URL { caches.appendingPathComponent("RemoteFiles", isDirectory: true) }
    static var exports: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// A library root: this iPad, or the mirror of a NAS account.
enum LibrarySource: Hashable, Codable, Identifiable {
    case local
    case account(UUID)

    var id: String {
        switch self {
        case .local: return "local"
        case .account(let id): return id.uuidString
        }
    }

    var accountID: UUID? {
        if case .account(let id) = self { return id }
        return nil
    }
}

/// An item somewhere in the library.
struct LibraryRef: Hashable, Codable, Identifiable {
    var source: LibrarySource
    var path: String

    var id: String { source.id + ":" + path }
}

struct LibraryLocation: Hashable {
    var source: LibrarySource
    var folder: String = "/"
}

struct RecentEntry: Codable, Hashable, Identifiable {
    var ref: LibraryRef
    var opened: Date
    var id: String { ref.id }
}

/// What the full-screen cover shows.
struct OpenDocument: Identifiable, Hashable {
    enum Kind: Hashable { case notebook, pdf }

    var ref: LibraryRef
    var url: URL
    var kind: Kind
    /// PDFs opened straight from the NAS browser (not part of a library).
    var isRemoteCopy = false

    var id: String { ref.id + (isRemoteCopy ? "#remote" : "") }
}

/// What the Apple Pencil's button does (double tap on Pencil 2, squeeze on Pencil Pro).
enum PencilButtonAction: String, Codable, CaseIterable, Identifiable {
    /// Opens the tool wheel (tools, colors, width, pen settings) at the pencil tip.
    case wheel
    /// Switches between the eraser and the last pen.
    case eraser
    case none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .wheel: return "휠 메뉴"
        case .eraser: return "지우개 전환"
        case .none: return "사용 안 함"
        }
    }
}

/// How a notebook's pages are laid out in the editor.
enum PageLayout: String, Codable, CaseIterable, Identifiable {
    /// One continuous vertical scroll.
    case vertical
    /// One page per screen; swipe sideways to turn pages.
    case horizontal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .vertical: return "세로 스크롤"
        case .horizontal: return "옆으로 넘기기"
        }
    }
}

/// App-wide preferences (UserDefaults).
struct AppSettings: Codable, Equatable {
    /// Only Apple Pencil draws; fingers scroll and zoom.
    var pencilOnly = true
    /// Two-finger tap = undo, three-finger tap = redo.
    var tapGesturesUndo = true
    /// 낙서로 지우기: scribbling back and forth over ink with the pen erases it.
    var scribbleToErase = true
    /// Pencil double tap / squeeze.
    var pencilButtonAction: PencilButtonAction = .wheel
    /// Continuous vertical scroll or sideways page turning.
    var pageLayout: PageLayout = .vertical
    var defaultTemplate: PaperTemplate = .ruled
    var defaultPaperColor: PaperColor = .white
    var defaultSize: PageSizePreset = .a4
    var defaultLandscape = false
    /// Handwriting correction applied while writing (0 = off).
    var correction: Double = 0.3
    /// Draw-and-hold turns strokes into clean shapes.
    var snapShapes = true
    var librarySort: LibrarySort = .modified

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: "settings"),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "settings") }
    }

    var defaultPageSize: PageSize { defaultLandscape ? defaultSize.size.landscape : defaultSize.size.portrait }
    var defaultPaper: PaperStyle { PaperStyle(template: defaultTemplate, color: defaultPaperColor) }
}

extension AppSettings {
    /// Settings saved by an older version lack newer keys: those take their defaults
    /// instead of failing the whole decode (which would reset every setting).
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pencilOnly = try c.decodeIfPresent(Bool.self, forKey: .pencilOnly) ?? pencilOnly
        tapGesturesUndo = try c.decodeIfPresent(Bool.self, forKey: .tapGesturesUndo) ?? tapGesturesUndo
        scribbleToErase = try c.decodeIfPresent(Bool.self, forKey: .scribbleToErase) ?? scribbleToErase
        pencilButtonAction = (try? c.decodeIfPresent(PencilButtonAction.self, forKey: .pencilButtonAction))
            ?? pencilButtonAction
        pageLayout = (try? c.decodeIfPresent(PageLayout.self, forKey: .pageLayout)) ?? pageLayout
        defaultTemplate = (try? c.decodeIfPresent(PaperTemplate.self, forKey: .defaultTemplate)) ?? defaultTemplate
        defaultPaperColor = (try? c.decodeIfPresent(PaperColor.self, forKey: .defaultPaperColor)) ?? defaultPaperColor
        defaultSize = (try? c.decodeIfPresent(PageSizePreset.self, forKey: .defaultSize)) ?? defaultSize
        defaultLandscape = try c.decodeIfPresent(Bool.self, forKey: .defaultLandscape) ?? defaultLandscape
        correction = try c.decodeIfPresent(Double.self, forKey: .correction) ?? correction
        snapShapes = try c.decodeIfPresent(Bool.self, forKey: .snapShapes) ?? snapShapes
        librarySort = (try? c.decodeIfPresent(LibrarySort.self, forKey: .librarySort)) ?? librarySort
    }
}

/// Reachability for Wi-Fi-only sync and offline badges.
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isConnected = true
    @Published private(set) var isOnWiFi = true
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            let wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            DispatchQueue.main.async {
                self?.isConnected = connected
                self?.isOnWiFi = wifi
            }
        }
        monitor.start(queue: DispatchQueue(label: "note.network"))
    }

    deinit { monitor.cancel() }
}

struct AccountSyncStatus: Equatable {
    enum Phase: Equatable {
        case idle
        case syncing
        case error(String)
        case offline
        case waitingForWiFi
    }

    var phase: Phase = .idle
    var progress: SyncProgress?
    var lastSync: Date?
    var lastReport: SyncReport?

    var isSyncing: Bool { phase == .syncing }

    var summary: String {
        switch phase {
        case .idle:
            guard let lastSync else { return "아직 동기화하지 않음" }
            return "동기화됨 · \(lastSync.relativeLabel)"
        case .syncing:
            if let p = progress, p.total > 0 { return "동기화 중 · \(p.completed) / \(p.total)" }
            return "변경 사항 확인 중…"
        case .error(let message): return message
        case .offline: return "오프라인 · 연결되면 동기화"
        case .waitingForWiFi: return "Wi-Fi 연결 대기 중"
        }
    }
}
#endif
