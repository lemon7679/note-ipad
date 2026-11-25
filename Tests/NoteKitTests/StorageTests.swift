import Foundation
import XCTest
@testable import NoteKit

final class NotebookPackageTests: XCTestCase {
    func testCreateWriteAndReadBack() throws {
        let dir = try TempDir()
        var doc = NotebookDocument(title: "선형대수/필기", pageCount: 3)
        let package = try NotebookPackage.create(in: dir.url, document: doc)
        XCTAssertEqual(package.url.lastPathComponent, "선형대수-필기.inknote")
        XCTAssertEqual(try package.readDocument().pages.count, 3)

        let pageID = doc.pages[0].id
        try package.writeInk(Data([1, 2, 3]), pageID: pageID)
        XCTAssertEqual(package.readInk(pageID: pageID), Data([1, 2, 3]))

        doc.pages.removeFirst()
        try package.write(doc)
        package.pruneInk(keeping: doc)
        XCTAssertNil(package.readInk(pageID: pageID))

        // A second notebook with the same title gets a unique folder.
        let second = try NotebookPackage.create(in: dir.url, document: NotebookDocument(title: "선형대수/필기"))
        XCTAssertEqual(second.url.lastPathComponent, "선형대수-필기 2.inknote")
    }

    func testDuplicateGetsNewIdentity() throws {
        let dir = try TempDir()
        let doc = NotebookDocument(title: "원본")
        let package = try NotebookPackage.create(in: dir.url, document: doc)
        try package.writeInk(Data([9]), pageID: doc.pages[0].id)
        let copy = try package.duplicate(into: dir.url, title: "원본 사본")
        let copied = try copy.readDocument()
        XCTAssertNotEqual(copied.id, doc.id)
        XCTAssertEqual(copied.title, "원본 사본")
        XCTAssertEqual(copy.readInk(pageID: doc.pages[0].id), Data([9]))
    }

    func testAnnotatingPDFCopiesTheSource() throws {
        let dir = try TempDir()
        let pdf = dir.url.appendingPathComponent("강의.pdf")
        try Data("%PDF-1.4 fake".utf8).write(to: pdf)
        let sizes = [PageSize(width: 612, height: 792), PageSize(width: 792, height: 612)]
        let package = try NotebookPackage.createAnnotating(pdfURL: pdf, title: "강의", pageSizes: sizes,
                                                           in: dir.sub("lib"), linkedPath: "/강의.pdf")
        let doc = try package.readDocument()
        XCTAssertEqual(doc.pages.map(\.background), [.pdf(pageIndex: 0), .pdf(pageIndex: 1)])
        XCTAssertEqual(doc.pages[1].size.width, 792)
        XCTAssertEqual(doc.pdf?.linkedPath, "/강의.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.assetURL("source.pdf").path))
    }

    func testNewerFormatIsRejected() throws {
        let dir = try TempDir()
        var doc = NotebookDocument(title: "미래")
        let package = try NotebookPackage.create(in: dir.url, document: doc)
        doc.format = 99
        try package.write(doc)
        XCTAssertThrowsError(try package.readDocument())
    }
}

final class LibraryFileSystemTests: XCTestCase {
    func testListingClassifiesItems() throws {
        let dir = try TempDir()
        let lib = LibraryFileSystem(root: dir.url)
        try lib.createFolder(named: "강의", in: "/")
        try NotebookPackage.create(in: dir.url, document: NotebookDocument(title: "노트"))
        try Data("x".utf8).write(to: dir.url.appendingPathComponent("자료.pdf"))
        try Data("x".utf8).write(to: dir.url.appendingPathComponent(".DS_Store"))
        let items = try lib.list("/")
        let kinds = Dictionary(uniqueKeysWithValues: items.map { ($0.fileName, $0.kind) })
        XCTAssertEqual(kinds, ["강의": .folder, "노트.inknote": .notebook, "자료.pdf": .pdf])
        XCTAssertEqual(items.first { $0.kind == .notebook }?.displayName, "노트")
        XCTAssertEqual(lib.summary(ofNotebook: "/노트.inknote")?.pageCount, 1)
    }

    func testRenameMoveDuplicate() throws {
        let dir = try TempDir()
        let lib = LibraryFileSystem(root: dir.url)
        try NotebookPackage.create(in: dir.url, document: NotebookDocument(title: "초안"))
        let renamed = try lib.rename("/초안.inknote", to: "최종")
        XCTAssertEqual(renamed, "/최종.inknote")
        XCTAssertEqual(lib.summary(ofNotebook: renamed)?.title, "최종")

        let folder = try lib.createFolder(named: "보관", in: "/")
        let moved = try lib.move(renamed, toFolder: folder)
        XCTAssertEqual(moved, "/보관/최종.inknote")
        XCTAssertThrowsError(try lib.move(folder, toFolder: "/보관"))   // into itself

        let copy = try lib.duplicate(moved)
        XCTAssertEqual(copy, "/보관/최종 사본.inknote")
        XCTAssertNotEqual(lib.summary(ofNotebook: copy)?.title, nil)

        try Data("pdf".utf8).write(to: dir.url.appendingPathComponent("a.pdf"))
        XCTAssertEqual(try lib.rename("/a.pdf", to: "b.pdf"), "/b.pdf")
        XCTAssertEqual(try lib.duplicate("/b.pdf"), "/b 사본.pdf")
        XCTAssertEqual(lib.allFolders(), ["/보관"])
        XCTAssertEqual(Set(lib.search("최종").map(\.path)), ["/보관/최종.inknote", "/보관/최종 사본.inknote"])
    }

    func testTrashRestore() throws {
        let dir = try TempDir()
        let lib = LibraryFileSystem(root: dir.sub("lib"))
        let trash = TrashBin(directory: dir.sub("trash"))
        let folder = try lib.createFolder(named: "강의", in: "/")
        try NotebookPackage.create(in: lib.url(for: folder), document: NotebookDocument(title: "노트"))
        try lib.delete("/강의/노트.inknote", trash: trash)
        XCTAssertFalse(lib.exists("/강의/노트.inknote"))
        XCTAssertEqual(trash.entries().map(\.displayName), ["노트"])
        let restored = try trash.restore(trash.entries()[0], into: lib)
        XCTAssertEqual(restored, "/강의/노트.inknote")
        XCTAssertTrue(trash.entries().isEmpty)
    }

    func testNotebookAndFileCopyToAnotherSource() throws {
        let dir = try TempDir()
        let device = LibraryFileSystem(root: dir.sub("device"))
        let nas = LibraryFileSystem(root: dir.sub("nas"))
        let pdf = dir.url.appendingPathComponent("모의고사.pdf")
        try Data((0..<2048).map { UInt8($0 % 256) }).write(to: pdf)
        let package = try NotebookPackage.createAnnotating(pdfURL: pdf, title: "모의고사",
                                                           pageSizes: [PageSize(width: 595, height: 842)], in: device.root)
        let doc = try package.readDocument()
        try package.writeInk(Data([4, 5, 6]), pageID: doc.pages[0].id)
        let notePath = "/" + package.url.lastPathComponent
        let folder = try nas.createFolder(named: "국어", in: "/")
        try NotebookPackage.create(in: nas.url(for: folder), document: NotebookDocument(title: "모의고사"))

        let copied = try nas.copy(notePath, from: device, into: folder)
        XCTAssertEqual(copied, "/국어/모의고사 2.inknote")
        let back = NotebookPackage(url: nas.url(for: copied))
        XCTAssertEqual(try back.readDocument().id, doc.id)
        XCTAssertEqual(back.readInk(pageID: doc.pages[0].id), Data([4, 5, 6]))
        XCTAssertEqual(try Data(contentsOf: back.assetURL("source.pdf")).count, 2048)
        XCTAssertEqual(try nas.list(folder).first { $0.path == copied }?.kind, .notebook)
        // The original stays until the caller removes it.
        XCTAssertTrue(device.exists(notePath))

        try device.importFile(from: pdf, into: "/")
        XCTAssertEqual(try nas.copy("/모의고사.pdf", from: device, into: "/"), "/모의고사.pdf")
        XCTAssertEqual(try Data(contentsOf: nas.url(for: "/모의고사.pdf")).count, 2048)

        XCTAssertThrowsError(try nas.copy("/없음.inknote", from: device, into: "/"))
    }
}

final class InkOutlineParserTests: XCTestCase {
    func testParsesEngineSVG() {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="200pt" height="100pt" viewBox="0 0 200 100">
        <rect width="100%" height="100%" fill="#ffffff"/>
        <g opacity="0.5">
        <path d="M10,10 L20,10 20,20 10,20Z" fill="#1c1c1e"/>
        <path d="M1.5,2 L3,4.25Z" fill="#ffe45c" stroke="#ffe45c" stroke-width="2.5" stroke-linejoin="round" opacity="0.4" style="mix-blend-mode:multiply"/>
        </g>
        </svg>
        """
        let outlines = InkOutlineParser.parse(svg)
        XCTAssertEqual(outlines.count, 2)
        XCTAssertEqual(outlines[0].points.count, 4)
        XCTAssertEqual(outlines[0].opacity, 0.5, accuracy: 1e-9)
        XCTAssertFalse(outlines[0].multiply)
        XCTAssertEqual(outlines[1].points, [.init(x: 1.5, y: 2), .init(x: 3, y: 4.25)])
        XCTAssertEqual(outlines[1].strokeWidth, 2.5)
        XCTAssertEqual(outlines[1].opacity, 0.2, accuracy: 1e-9)
        XCTAssertTrue(outlines[1].multiply)
    }

    func testParsesEraserHoleMasks() {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="200pt" height="100pt" viewBox="0 0 200 100">
        <g>
        <mask id="e7" maskUnits="userSpaceOnUse" x="0" y="0" width="50" height="50"><rect x="0" y="0" width="50" height="50" fill="#ffffff"/><polygon points="1,1 4,1 4,4 1,4" fill="#000000"/><polygon points="5,5 6,5 6,6" fill="#000000"/></mask>
        <path d="M0,0 L40,0 40,40 0,40Z" fill="#ffe45c" mask="url(#e7)" style="mix-blend-mode:multiply"/>
        <path d="M0,0 L10,0 10,10Z" fill="#1c1c1e"/>
        </g>
        </svg>
        """
        let outlines = InkOutlineParser.parse(svg)
        XCTAssertEqual(outlines.count, 2)   // mask shapes are not ink
        XCTAssertEqual(outlines[0].holes.count, 2)
        XCTAssertEqual(outlines[0].holes[0], [.init(x: 1, y: 1), .init(x: 4, y: 1), .init(x: 4, y: 4), .init(x: 1, y: 4)])
        XCTAssertTrue(outlines[1].holes.isEmpty)
    }
}
