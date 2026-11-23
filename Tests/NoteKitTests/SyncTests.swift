import Foundation
import XCTest
@testable import NoteKit

final class SyncPlannerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func l(_ p: String, _ size: Int64 = 10, dir: Bool = false, at t: TimeInterval = 0) -> (String, LocalEntry) {
        (p, LocalEntry(path: p, isDirectory: dir, size: size, modified: t0.addingTimeInterval(t)))
    }

    private func r(_ p: String, _ size: Int64 = 10, dir: Bool = false, etag: String? = nil) -> (String, RemoteItem) {
        (p, RemoteItem(path: p, isDirectory: dir, size: size, modified: t0, etag: etag))
    }

    private func synced(_ p: String, _ size: Int64 = 10, dir: Bool = false, etag: String? = nil) -> (String, SyncRecord) {
        let le = LocalEntry(path: p, isDirectory: dir, size: size, modified: t0)
        let re = RemoteItem(path: p, isDirectory: dir, size: size, modified: t0, etag: etag)
        return (p, SyncRecord(isDirectory: dir, localSig: le.signature, remoteSig: re.signature, remoteSize: size))
    }

    private func plan(local: [(String, LocalEntry)] = [], remote: [(String, RemoteItem)] = [],
                      base: [(String, SyncRecord)] = [], busy: Set<String> = [],
                      resolutions: [String: ConflictResolution] = [:], onDemand: Bool = true) -> SyncPlan {
        SyncPlanner.plan(local: Dictionary(uniqueKeysWithValues: local), remote: Dictionary(uniqueKeysWithValues: remote),
                         base: Dictionary(uniqueKeysWithValues: base), busy: busy, resolutions: resolutions,
                         downloadOnDemand: onDemand, now: t0)
    }

    func testFirstSyncUploadsLocalAndCreatesFoldersFirst() {
        let p = plan(local: [l("/강의", dir: true), l("/강의/a.pdf")])
        XCTAssertEqual(p.actions, [.makeRemoteDirectory("/강의"), .upload("/강의/a.pdf")])
        XCTAssertTrue(p.conflicts.isEmpty)
    }

    func testNewRemoteFilesArePlaceholdersButNotebooksDownload() {
        let p = plan(remote: [r("/a.pdf"), r("/n.inknote", dir: true), r("/n.inknote/document.json")])
        XCTAssertEqual(p.actions, [.makeLocalDirectory("/n.inknote"), .download("/n.inknote/document.json"),
                                   .placeholder("/a.pdf")])
        let eager = plan(remote: [r("/a.pdf")], onDemand: false)
        XCTAssertEqual(eager.actions, [.download("/a.pdf")])
    }

    func testOneSidedChanges() {
        // Edited here.
        XCTAssertEqual(plan(local: [l("/a", 11, at: 5)], remote: [r("/a")], base: [synced("/a")]).actions, [.upload("/a")])
        // Edited on the NAS.
        XCTAssertEqual(plan(local: [l("/a")], remote: [r("/a", 12)], base: [synced("/a")]).actions, [.download("/a")])
        // Nothing changed.
        XCTAssertEqual(plan(local: [l("/a")], remote: [r("/a")], base: [synced("/a")]).actions, [])
        // Deleted here → delete on NAS.
        XCTAssertEqual(plan(remote: [r("/a")], base: [synced("/a")]).actions, [.deleteRemote("/a")])
        // Deleted on NAS → delete here.
        XCTAssertEqual(plan(local: [l("/a")], base: [synced("/a")]).actions, [.deleteLocal("/a")])
        // Gone everywhere.
        XCTAssertEqual(plan(base: [synced("/a")]).actions, [.forget("/a")])
    }

    func testDeleteVersusEditKeepsTheEdit() {
        XCTAssertEqual(plan(local: [l("/a", 20, at: 9)], base: [synced("/a")]).actions, [.upload("/a")])
        XCTAssertEqual(plan(remote: [r("/a", 20)], base: [synced("/a")]).actions, [.download("/a")])
    }

    func testETagDrivesRemoteChange() {
        let base = [synced("/a", etag: "v1")]
        XCTAssertEqual(plan(local: [l("/a")], remote: [r("/a", etag: "v1")], base: base).actions, [])
        XCTAssertEqual(plan(local: [l("/a")], remote: [r("/a", etag: "v2")], base: base).actions, [.download("/a")])
    }

    func testConflictInPackageBlocksWholeNotebook() {
        let pkg = "/보고서.inknote"
        let p = plan(
            local: [l(pkg, dir: true), l(pkg + "/document.json", 30, at: 3), l(pkg + "/pages/1.ink", 50, at: 3),
                    l(pkg + "/pages", dir: true)],
            remote: [r(pkg, dir: true), r(pkg + "/document.json", 31), r(pkg + "/pages/1.ink"), r(pkg + "/pages", dir: true)],
            base: [synced(pkg, dir: true), synced(pkg + "/document.json"), synced(pkg + "/pages/1.ink"),
                   synced(pkg + "/pages", dir: true)])
        XCTAssertEqual(p.conflicts.map(\.path), [pkg])
        XCTAssertTrue(p.actions.isEmpty, "\(p.actions)")
    }

    func testPlainFileConflict() {
        let p = plan(local: [l("/a.pdf", 11, at: 2)], remote: [r("/a.pdf", 12)], base: [synced("/a.pdf")])
        XCTAssertEqual(p.conflicts.map(\.path), ["/a.pdf"])
        XCTAssertEqual(p.actions, [])
    }

    func testFirstSyncWithBothSidesAdoptsEqualSizes() {
        XCTAssertEqual(plan(local: [l("/a", 10)], remote: [r("/a", 10)]).actions, [.adopt("/a")])
        XCTAssertEqual(plan(local: [l("/a", 10)], remote: [r("/a", 11)]).conflicts.map(\.path), ["/a"])
    }

    func testDeletedFolderIsOneActionUnlessOtherSideChanged() {
        let base = [synced("/d", dir: true), synced("/d/x"), synced("/d/y")]
        // Deleted here, untouched on NAS.
        XCTAssertEqual(plan(remote: [r("/d", dir: true), r("/d/x"), r("/d/y")], base: base).actions, [.deleteRemote("/d")])
        // Deleted here, but /d/y changed on the NAS: keep the folder and the change.
        let kept = plan(remote: [r("/d", dir: true), r("/d/x"), r("/d/y", 99)], base: base)
        XCTAssertEqual(kept.actions, [.makeLocalDirectory("/d"), .download("/d/y"), .deleteRemote("/d/x")])
        // Deleted on NAS, untouched here.
        XCTAssertEqual(plan(local: [l("/d", dir: true), l("/d/x"), l("/d/y")], base: base).actions, [.deleteLocal("/d")])
    }

    func testBusyNotebooksWait() {
        let p = plan(local: [l("/n.inknote", dir: true), l("/n.inknote/document.json")], busy: ["/n.inknote"])
        XCTAssertEqual(p.actions, [])
    }

    func testPlaceholdersStayOnlineAndFollowRemoteChanges() {
        var rec = synced("/a.pdf")
        rec.1.localSig = nil
        XCTAssertEqual(plan(remote: [r("/a.pdf")], base: [rec]).actions, [])
        XCTAssertEqual(plan(remote: [r("/a.pdf", 50)], base: [rec]).actions, [.placeholder("/a.pdf")])
        XCTAssertEqual(plan(base: [rec]).actions, [.forget("/a.pdf")])
    }

    func testResolutions() {
        let local = [l("/a.pdf", 11, at: 2)], remote = [r("/a.pdf", 12)], base = [synced("/a.pdf")]
        XCTAssertEqual(plan(local: local, remote: remote, base: base, resolutions: ["/a.pdf": .keepLocal]).actions,
                       [.upload("/a.pdf")])
        XCTAssertEqual(plan(local: local, remote: remote, base: base, resolutions: ["/a.pdf": .keepRemote]).actions,
                       [.download("/a.pdf")])
        XCTAssertEqual(plan(local: local, remote: remote, base: base, resolutions: ["/a.pdf": .keepBoth]).actions,
                       [.conflictCopy("/a.pdf"), .download("/a.pdf")])
    }
}

/// End-to-end: two iPads syncing through a "NAS" that is a temp folder.
final class SyncEngineTests: XCTestCase {
    private var dir: TempDir!
    private var nas: LocalFolderFileSystem!
    private let options: SyncOptions = {
        var o = SyncOptions()
        o.downloadOnDemand = true
        return o
    }()

    override func setUpWithError() throws {
        dir = try TempDir()
        nas = LocalFolderFileSystem(rootURL: dir.sub("nas"))
    }

    private func device(_ name: String) -> (SyncEngine, LibraryFileSystem) {
        let root = dir.sub("device-\(name)")
        let engine = SyncEngine(remote: nas, localRoot: root, remoteRoot: "/home/Notes",
                                stateURL: dir.url.appendingPathComponent("state-\(name).json"), deviceName: name)
        return (engine, LibraryFileSystem(root: root))
    }

    private func bump(_ url: URL, _ text: String) throws {
        try Data(text.utf8).write(to: url)
        // Make sure the signature changes even on coarse file-system clocks.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(Double.random(in: 10...1000))],
                                              ofItemAtPath: url.path)
    }

    func testNotebookTravelsBetweenDevices() async throws {
        let (engineA, libA) = device("A")
        let (engineB, libB) = device("B")
        let folder = try libA.createFolder(named: "강의", in: "/")
        let doc = NotebookDocument(title: "선형대수", pageCount: 2)
        let package = try NotebookPackage.create(in: libA.url(for: folder), document: doc)
        try package.writeInk(Data(repeating: 1, count: 100), pageID: doc.pages[0].id)

        let first = try await engineA.run(options: options)
        XCTAssertEqual(first.uploaded, 2)   // document.json + one page
        XCTAssertTrue(first.errors.isEmpty, "\(first.errors)")
        let onNAS = try await nas.stat("/home/Notes/강의/선형대수.inknote/document.json")
        XCTAssertNotNil(onNAS)

        let second = try await engineB.run(options: options)
        XCTAssertEqual(second.downloaded, 2)
        let pkgB = NotebookPackage(url: libB.url(for: "/강의/선형대수.inknote"))
        XCTAssertEqual(try pkgB.readDocument().id, doc.id)

        // Edit on B → arrives on A.
        try bump(pkgB.inkURL(pageID: doc.pages[0].id), String(repeating: "x", count: 200))
        let up = try await engineB.run(options: options)
        XCTAssertEqual(up.uploaded, 1)
        let down = try await engineA.run(options: options)
        XCTAssertEqual(down.downloaded, 1)
        XCTAssertEqual(package.readInk(pageID: doc.pages[0].id)?.count, 200)

        // Nothing left to do.
        let idle = try await engineA.run(options: options)
        XCTAssertEqual(idle.transferred, 0)

        // Delete on A → gone on B.
        try libA.delete("/강의/선형대수.inknote")
        _ = try await engineA.run(options: options)
        let deleted = try await engineB.run(options: options)
        XCTAssertEqual(deleted.deletedLocal, 1)
        XCTAssertFalse(libB.exists("/강의/선형대수.inknote"))
    }

    func testConflictIsReportedThenKeptBoth() async throws {
        let (engineA, libA) = device("A")
        let (engineB, libB) = device("B")
        let doc = NotebookDocument(title: "보고서")
        let pkgA = try NotebookPackage.create(in: libA.root, document: doc)
        _ = try await engineA.run(options: options)
        _ = try await engineB.run(options: options)
        let pkgB = NotebookPackage(url: libB.url(for: "/보고서.inknote"))

        try bump(pkgA.inkURL(pageID: doc.pages[0].id), "from A")
        try bump(pkgB.inkURL(pageID: doc.pages[0].id), "from B, longer")
        _ = try await engineA.run(options: options)
        let report = try await engineB.run(options: options)
        XCTAssertEqual(report.conflicts.map(\.path), ["/보고서.inknote"])
        let pending = await engineB.conflicts
        XCTAssertEqual(pending.count, 1)

        await engineB.resolve("/보고서.inknote", with: .keepBoth)
        let resolved = try await engineB.run(options: options)
        XCTAssertTrue(resolved.conflicts.isEmpty)
        XCTAssertEqual(String(decoding: pkgB.readInk(pageID: doc.pages[0].id) ?? Data(), as: UTF8.self), "from A")
        let names = try libB.list("/").map(\.fileName).sorted()
        XCTAssertEqual(names.count, 2, "\(names)")
        let copy = try XCTUnwrap(names.first { $0.contains("충돌 사본") })
        let copyDoc = try NotebookPackage(url: libB.url(for: "/" + copy)).readDocument()
        XCTAssertNotEqual(copyDoc.id, doc.id)
        // The copy was uploaded in the same sync.
        let copyOnNAS = try await nas.stat(RemotePath.join("/home/Notes", copy + "/document.json"))
        XCTAssertNotNil(copyOnNAS)
        let afterConflicts = await engineB.conflicts
        XCTAssertTrue(afterConflicts.isEmpty)
    }

    func testPDFsAreOnDemand() async throws {
        let (engineA, libA) = device("A")
        let (engineB, libB) = device("B")
        try Data(repeating: 7, count: 1000).write(to: libA.url(for: "/강의자료.pdf"))
        _ = try await engineA.run(options: options)
        _ = try await engineB.run(options: options)
        XCTAssertFalse(libB.exists("/강의자료.pdf"))
        let placeholders = await engineB.placeholders(in: "/")
        XCTAssertEqual(placeholders.map(\.fileName), ["강의자료.pdf"])
        XCTAssertTrue(placeholders[0].isPlaceholder)
        XCTAssertEqual(placeholders[0].size, 1000)

        let url = try await engineB.materialize("/강의자료.pdf")
        XCTAssertEqual(try Data(contentsOf: url).count, 1000)
        let afterOpen = await engineB.placeholders(in: "/")
        XCTAssertTrue(afterOpen.isEmpty)
        let idle = try await engineB.run(options: options)
        XCTAssertEqual(idle.transferred, 0)

        try await engineB.evict("/강의자료.pdf")
        XCTAssertFalse(libB.exists("/강의자료.pdf"))
        let back = await engineB.placeholders(in: "/")
        XCTAssertEqual(back.count, 1)
        let stillIdle = try await engineB.run(options: options)
        XCTAssertEqual(stillIdle.deletedRemote, 0)   // evicting is not deleting
    }

    func testEmptyNASIsNotMirroredAsMassDeletion() async throws {
        let (engineA, libA) = device("A")
        for i in 0..<6 { try Data("\(i)".utf8).write(to: libA.url(for: "/f\(i).txt")) }
        _ = try await engineA.run(options: options)
        // Simulate a NAS that suddenly lists nothing (unmounted volume…).
        for i in 0..<6 { try await nas.delete("/home/Notes/f\(i).txt") }
        do {
            _ = try await engineA.run(options: options)
            XCTFail("expected the safety stop")
        } catch SyncError.suspiciousEmptyRemote {
            XCTAssertEqual(try libA.list("/").count, 6)
        }
    }

    func testMissingRemoteFolderAfterSetupIsAnError() async throws {
        let (engineA, libA) = device("A")
        try Data("x".utf8).write(to: libA.url(for: "/a.txt"))
        _ = try await engineA.run(options: options)
        try await nas.delete("/home/Notes")
        do {
            _ = try await engineA.run(options: options)
            XCTFail("expected an error")
        } catch SyncError.remoteFolderMissing {
            XCTAssertTrue(libA.exists("/a.txt"))
        }
    }
}
