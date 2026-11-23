import Foundation
import XCTest
@testable import NoteKit

final class WebDAVParserTests: XCTestCase {
    func testApacheStyleResponse() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/dav/Notes/</D:href>
            <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype>
              <D:getlastmodified>Mon, 23 Nov 2026 07:20:00 GMT</D:getlastmodified></D:prop>
              <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
          </D:response>
          <D:response>
            <D:href>/dav/Notes/%EA%B0%95%EC%9D%98%20%EC%9E%90%EB%A3%8C.pdf</D:href>
            <D:propstat><D:prop><D:resourcetype/><D:getcontentlength>3400</D:getcontentlength>
              <D:getlastmodified>Sun, 22 Nov 2026 10:00:00 GMT</D:getlastmodified>
              <D:getetag>W/"abc-123"</D:getetag></D:prop>
              <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
            <D:propstat><D:prop><D:quota/></D:prop><D:status>HTTP/1.1 404 Not Found</D:status></D:propstat>
          </D:response>
          <D:response>
            <D:href>/dav/Notes/선형대수.inknote/</D:href>
            <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
              <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
          </D:response>
        </D:multistatus>
        """
        let items = try WebDAVMultistatusParser.parse(Data(xml.utf8), basePath: "/dav")
        XCTAssertEqual(items.map(\.path), ["/Notes", "/Notes/강의 자료.pdf", "/Notes/선형대수.inknote"])
        XCTAssertTrue(items[0].isDirectory)
        XCTAssertFalse(items[1].isDirectory)
        XCTAssertEqual(items[1].size, 3400)
        XCTAssertEqual(items[1].etag, "abc-123")
        XCTAssertEqual(items[1].signature, "e:abc-123")
        XCTAssertEqual(items[1].modified, HTTPDate.parse("Sun, 22 Nov 2026 10:00:00 GMT"))
        XCTAssertTrue(items[2].isDirectory)
    }

    func testNextcloudStyleAbsoluteHrefs() throws {
        let xml = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
         <d:response><d:href>https://cloud.example/remote.php/dav/files/me/Notes/a%2Bb.pdf</d:href>
          <d:propstat><d:prop><d:getcontentlength>10</d:getcontentlength><d:resourcetype/>
           <d:getetag>&quot;5f1&quot;</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
         </d:response>
        </d:multistatus>
        """
        let items = try WebDAVMultistatusParser.parse(Data(xml.utf8), basePath: "/remote.php/dav/files/me")
        XCTAssertEqual(items.map(\.path), ["/Notes/a+b.pdf"])
        XCTAssertEqual(items[0].etag, "5f1")
    }

    func testGarbageIsAnError() {
        XCTAssertThrowsError(try WebDAVMultistatusParser.parse(Data("<not".utf8), basePath: "/"))
    }

    func testURLEncodingOfPaths() {
        let client = WebDAVClient(baseURL: URL(string: "https://nas.local:5006/dav/")!, username: "", password: "")
        XCTAssertEqual(client.url(for: "/강의 자료/a#1?.pdf").absoluteString,
                       "https://nas.local:5006/dav/%EA%B0%95%EC%9D%98%20%EC%9E%90%EB%A3%8C/a%231%3F.pdf")
        XCTAssertEqual(client.url(for: "/Notes", directory: true).absoluteString, "https://nas.local:5006/dav/Notes/")
        XCTAssertEqual(client.basePath, "/dav")
    }

    func testHTTPDates() {
        let d = HTTPDate.parse("Mon, 23 Nov 2026 07:20:00 GMT")
        XCTAssertNotNil(d)
        XCTAssertEqual(HTTPDate.format(d!), "Mon, 23 Nov 2026 07:20:00 GMT")
    }
}

final class SynologyHelperTests: XCTestCase {
    func testEncodingAndJSONArrays() {
        XCTAssertEqual(SynologyClient.encode("a+b c&d/é"), "a%2Bb%20c%26d%2F%C3%A9")
        XCTAssertEqual(SynologyClient.jsonArray(["/home/노트", "a\"b"]), #"["/home/노트","a\"b"]"#)
        let decoded = try? JSONSerialization.jsonObject(with: Data(SynologyClient.jsonArray(["/home/노트", "x"]).utf8)) as? [String]
        XCTAssertEqual(decoded, ["/home/노트", "x"])
    }

    func testEnvelopeDecoding() throws {
        let ok = try SynologyClient.decodeData(Data(#"{"success":true,"data":{"sid":"abc"}}"#.utf8))
        XCTAssertNil(ok.errorCode)
        XCTAssertEqual(ok.payload["sid"] as? String, "abc")
        let failed = try SynologyClient.decodeData(Data(#"{"success":false,"error":{"code":403}}"#.utf8))
        XCTAssertEqual(failed.errorCode, 403)
        XCTAssertEqual(SynologyClient.map(code: 403, api: "SYNO.API.Auth"), .twoFactorRequired)
        XCTAssertEqual(SynologyClient.map(code: 400, api: "SYNO.API.Auth"), .unauthorized)
        XCTAssertEqual(SynologyClient.map(code: 408, api: "SYNO.FileStation.List"), .notFound(""))
        XCTAssertThrowsError(try SynologyClient.decodeData(Data("<html>".utf8)))
    }

    func testFileItemParsing() {
        let file: [String: Any] = [
            "path": "/home/Notes/a.pdf", "isdir": false, "name": "a.pdf",
            "additional": ["size": 1234, "time": ["mtime": 1_795_000_000]],
        ]
        let item = SynologyClient.item(from: file)
        XCTAssertEqual(item?.path, "/home/Notes/a.pdf")
        XCTAssertEqual(item?.size, 1234)
        XCTAssertEqual(item?.modified, Date(timeIntervalSince1970: 1_795_000_000))
        XCTAssertEqual(item?.signature, "s:1234:1795000000")
    }

    func testMultipartPutsFileLast() throws {
        let dir = try TempDir()
        let file = dir.url.appendingPathComponent("a.ink")
        try Data([0, 1, 2]).write(to: file)
        let body = dir.url.appendingPathComponent("body")
        try SynologyClient.writeMultipart(to: body, boundary: "B", fields: [("path", "/home/Notes"), ("overwrite", "true")],
                                          fileField: "file", fileName: "a.ink", fileURL: file)
        let data = try Data(contentsOf: body)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("--B\r\nContent-Disposition: form-data; name=\"path\"\r\n\r\n/home/Notes\r\n"))
        let fileHeader = text.range(of: "filename=\"a.ink\"")!
        XCTAssertTrue(text.range(of: "name=\"overwrite\"")!.lowerBound < fileHeader.lowerBound)
        XCTAssertTrue(text.hasSuffix("\r\n--B--\r\n"))
        XCTAssertTrue(data.range(of: Data([0, 1, 2])) != nil)
    }
}

final class LocalFolderFileSystemTests: XCTestCase {
    func testBasicOperations() async throws {
        let dir = try TempDir()
        let fs = LocalFolderFileSystem(rootURL: dir.sub("share"))
        try await fs.createDirectory("/a/b")
        let src = dir.url.appendingPathComponent("src.txt")
        try Data("hello".utf8).write(to: src)
        let up = try await fs.upload(from: src, to: "/a/b/hello.txt", modified: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(up?.size, 5)
        XCTAssertEqual(up?.modified, Date(timeIntervalSince1970: 1_000_000))
        let all = try await fs.listRecursive("/")
        XCTAssertEqual(Set(all.map(\.path)), ["/a", "/a/b", "/a/b/hello.txt"])
        try await fs.move("/a/b/hello.txt", to: "/c/hi.txt")
        let moved = try await fs.stat("/c/hi.txt")
        XCTAssertNotNil(moved)
        let dl = dir.url.appendingPathComponent("dl.txt")
        try await fs.download("/c/hi.txt", to: dl)
        XCTAssertEqual(try String(contentsOf: dl, encoding: .utf8), "hello")
        try await fs.delete("/a")
        let gone = try await fs.stat("/a")
        XCTAssertNil(gone)
        let info = try await fs.testConnection(probeWrite: true, in: "/")
        XCTAssertTrue(info.writable)
    }
}
