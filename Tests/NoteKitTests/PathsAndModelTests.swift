import Foundation
import XCTest
@testable import NoteKit

final class PathsTests: XCTestCase {
    func testNormalizeAndJoin() {
        XCTAssertEqual(RemotePath.normalize(""), "/")
        XCTAssertEqual(RemotePath.normalize("a//b/./c/"), "/a/b/c")
        XCTAssertEqual(RemotePath.normalize("/a/b/../c"), "/a/c")
        XCTAssertEqual(RemotePath.join("/home/Notes", "강의/선형대수.inknote"), "/home/Notes/강의/선형대수.inknote")
        XCTAssertEqual(RemotePath.parent("/a/b"), "/a")
        XCTAssertEqual(RemotePath.parent("/a"), "/")
        XCTAssertEqual(RemotePath.name("/a/b.pdf"), "b.pdf")
        XCTAssertEqual(RemotePath.pathExtension("/a/B.PDF"), "pdf")
        XCTAssertEqual(RemotePath.pathExtension("/a/.hidden"), "")
    }

    func testRelativeAndAncestor() {
        XCTAssertEqual(RemotePath.relative("/home/Notes/a/b", to: "/home/Notes"), "/a/b")
        XCTAssertEqual(RemotePath.relative("/home/Notes", to: "/home/Notes"), "/")
        XCTAssertNil(RemotePath.relative("/home/NotesX/a", to: "/home/Notes"))
        XCTAssertEqual(RemotePath.relative("/x", to: "/"), "/x")
        XCTAssertTrue(RemotePath.isAncestor("/a", of: "/a/b"))
        XCTAssertFalse(RemotePath.isAncestor("/a", of: "/ab"))
        XCTAssertTrue(RemotePath.isAncestor("/", of: "/anything"))
    }

    func testPackageRootAndIgnoredNames() {
        XCTAssertEqual(FileNaming.packageRoot(of: "/강의/선형대수.inknote/pages/x.ink"), "/강의/선형대수.inknote")
        XCTAssertEqual(FileNaming.packageRoot(of: "/a.inknote"), "/a.inknote")
        XCTAssertNil(FileNaming.packageRoot(of: "/강의/자료.pdf"))
        XCTAssertTrue(FileNaming.isIgnored(".DS_Store"))
        XCTAssertTrue(FileNaming.isIgnored("@eaDir"))
        XCTAssertTrue(FileNaming.isIgnored("#recycle"))
        XCTAssertFalse(FileNaming.isIgnored("노트.pdf"))
    }

    func testSanitizeUniqueAndConflictNames() {
        XCTAssertEqual(FileNaming.sanitize("  a/b:c?  "), "a-b-c-")
        XCTAssertEqual(FileNaming.sanitize("..."), "제목 없음")
        let taken: Set<String> = ["노트.inknote", "노트 2.inknote"]
        XCTAssertEqual(FileNaming.unique(base: "노트", ext: "inknote") { taken.contains($0) }, "노트 3.inknote")
        let date = ISO8601DateFormatter().date(from: "2026-11-23T05:02:00Z")!
        let name = FileNaming.conflictCopyName(for: "보고서.inknote", device: "iPad", date: date)
        XCTAssertTrue(name.hasPrefix("보고서 (충돌 사본 iPad 2026-11-23 "), name)
        XCTAssertTrue(name.hasSuffix(").inknote"), name)
    }
}

final class ModelTests: XCTestCase {
    func testDocumentRoundTripsThroughJSON() throws {
        var doc = NotebookDocument(title: "선형대수", paper: PaperStyle(template: .grid, color: .ivory), pageCount: 2)
        doc.pages[1].background = .pdf(pageIndex: 4)
        doc.pages[1].elements = [PageElement(kind: .text, frame: ElementFrame(x: 10, y: 20, width: 100, height: 30),
                                             text: "메모", fontSize: 14, colorHex: "#1C1C1E")]
        doc.pdf = PDFSource(file: "source.pdf", originalName: "강의.pdf", linkedPath: "/강의.pdf")
        let data = try NotebookDocument.encoder.encode(doc)
        let back = try NotebookDocument.decoder.decode(NotebookDocument.self, from: data)
        XCTAssertEqual(back.title, doc.title)
        XCTAssertEqual(back.pages, doc.pages)
        XCTAssertEqual(back.pdf, doc.pdf)
        XCTAssertEqual(back.pages[1].background.pdfPageIndex, 4)
        XCTAssertEqual(back.pages[0].paper.template, .grid)
    }

    func testPaperAndColors() {
        XCTAssertEqual(PaperStyle(template: .ruled).effectiveSpacing, Units.mm(8), accuracy: 1e-9)
        XCTAssertEqual(PaperStyle(template: .ruled, spacing: 20).effectiveSpacing, 20)
        XCTAssertEqual(PageSizePreset.a4.size.landscape.width, 841.89)
        let custom = PageSize.millimeters(width: 210, height: 297)
        XCTAssertEqual(custom.width, PageSizePreset.a4.size.width, accuracy: 0.01)
        XCTAssertEqual(custom.millimeterLabel, "210 × 297 mm")
        XCTAssertEqual(PageSize.millimeters(width: 1, height: 5000).widthMM, 50, accuracy: 1e-9)
        XCTAssertEqual(PageSize.millimeters(width: 1, height: 5000).heightMM, 1200, accuracy: 1e-9)
        XCTAssertEqual(RGBAColor(hex: "#2F5BD3")?.hex, "#2F5BD3")
        XCTAssertNil(RGBAColor(hex: "zzz"))
        XCTAssertEqual(RGBAColor(hex: "FF000080")?.a ?? 0, 128.0 / 255.0, accuracy: 1e-9)
    }

    func testAccountURLs() {
        var a = NASAccount(name: "Home", kind: .synology, host: "https://192.168.0.20/", useHTTPS: true)
        XCTAssertEqual(a.baseURL?.absoluteString, "https://192.168.0.20:5001")
        a.kind = .webdav
        a.port = 443
        a.endpointPath = "remote.php/dav/files/me/"
        XCTAssertEqual(a.baseURL?.absoluteString, "https://192.168.0.20:443/remote.php/dav/files/me")
        a.host = ""
        XCTAssertNil(a.baseURL)
    }

    func testAccountStoreAndCredentials() throws {
        let dir = try TempDir()
        let store = AccountStore(fileURL: dir.url.appendingPathComponent("accounts.json"))
        XCTAssertTrue(store.load().isEmpty)
        let account = NASAccount(name: "NAS", host: "nas.local", username: "me", syncFolder: "/home/Notes")
        try store.save([account])
        XCTAssertEqual(store.load(), [account])
        let creds = InMemoryCredentialStore()
        creds.setSecret("pw", for: account.passwordKey)
        XCTAssertEqual(creds.secret(for: account.passwordKey), "pw")
        creds.setSecret(nil, for: account.passwordKey)
        XCTAssertNil(creds.secret(for: account.passwordKey))
    }
}

/// A temporary directory removed when the test ends.
final class TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("NoteKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func sub(_ name: String) -> URL {
        let u = url.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}
