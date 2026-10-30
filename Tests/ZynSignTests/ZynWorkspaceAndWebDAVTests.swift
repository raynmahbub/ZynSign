import Foundation
import XCTest
@testable import ZynSign

final class ZynWorkspaceAndWebDAVTests: XCTestCase {

    func testWebDAVMultistatusAndPathSanitization() {
        XCTAssertNil(WebDAVProtocol.sanitizePath("/../../etc/passwd"))
        XCTAssertEqual(WebDAVProtocol.sanitizePath("/Packages/Sample.ipa"), ["Packages", "Sample.ipa"])

        let xml = WebDAVProtocol.renderMultiStatusXML(resources: [
            .init(hrefPath: "/dav/", displayName: "dav", isDirectory: true, byteSize: 0, modifiedAt: Date())
        ])
        let rendered = String(decoding: xml, as: UTF8.self)
        XCTAssertTrue(rendered.contains("<D:multistatus"))
        XCTAssertTrue(rendered.contains("<D:collection/>"))
    }

    func testWebDAVRejectsAmbiguousFramingAndEmptyAuthentication() {
        XCTAssertNil(WebDAVProtocol.parseHead(Data("PUT /a HTTP/1.1\r\nContent-Length: 1\r\ncontent-length: 2\r\n\r\n".utf8)))
        XCTAssertNil(WebDAVProtocol.parseHead(Data("PUT /a HTTP/1.1\r\nHost: local\r\n\r\n".utf8)))
        XCTAssertFalse(WebDAVProtocol.verifyBasicAuthorization(headerValue: nil, expectedUsername: "user", expectedPassword: ""))
        let head = WebDAVProtocol.HTTPRequestHead(method: "GET", rawTarget: "/", headers: [:], contentLength: 0)
        let response = LANWebWorkspaceService.handleRequest(head: head, bodyFileURL: nil,
            rootDirectory: FileManager.default.temporaryDirectory, webdavEnabled: true,
            requiresAuth: true, expectedUser: "user", expectedPass: "")
        XCTAssertEqual(response.status, 401)
    }

    func testWebDAVDoesNotDeleteExistingFilesOnFailedMoveCopyOrPut() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let existing = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: existing)
        for method in ["MOVE", "COPY"] {
            let head = WebDAVProtocol.HTTPRequestHead(method: method, rawTarget: "/missing.txt",
                headers: ["destination": "/keep.txt"], contentLength: 0)
            let response = LANWebWorkspaceService.handleRequest(head: head, bodyFileURL: nil, rootDirectory: root,
                webdavEnabled: true, requiresAuth: false, expectedUser: "", expectedPass: "")
            XCTAssertNotEqual(response.status, 201)
            XCTAssertEqual(try Data(contentsOf: existing), Data("keep".utf8))
        }
        let same = WebDAVProtocol.HTTPRequestHead(method: "MOVE", rawTarget: "/keep.txt",
            headers: ["destination": "/keep.txt"], contentLength: 0)
        XCTAssertEqual(LANWebWorkspaceService.handleRequest(head: same, bodyFileURL: nil, rootDirectory: root,
            webdavEnabled: true, requiresAuth: false, expectedUser: "", expectedPass: "").status, 412)
        let put = WebDAVProtocol.HTTPRequestHead(method: "PUT", rawTarget: "/keep.txt", headers: [:], contentLength: 0)
        XCTAssertEqual(LANWebWorkspaceService.handleRequest(head: put, bodyFileURL: nil, rootDirectory: root,
            webdavEnabled: true, requiresAuth: false, expectedUser: "", expectedPass: "").status, 412)
        XCTAssertEqual(try Data(contentsOf: existing), Data("keep".utf8))
    }

    func testWebDAVRejectsSymlinkPath() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        try Data("outside".utf8).write(to: base.appendingPathComponent("secret.txt"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: base)
        let head = WebDAVProtocol.HTTPRequestHead(method: "GET", rawTarget: "/link/secret.txt", headers: [:], contentLength: 0)
        XCTAssertEqual(LANWebWorkspaceService.handleRequest(head: head, bodyFileURL: nil, rootDirectory: root,
            webdavEnabled: true, requiresAuth: false, expectedUser: "", expectedPass: "").status, 403)
    }

    func testDashboardDoesNotPutFileNamesInInlineJavaScript() {
        let item = WebDAVProtocol.ResourceMetadata(hrefPath: "/a'file.txt", displayName: "a'file.txt",
            isDirectory: false, byteSize: 1, modifiedAt: Date())
        let html = String(decoding: WebDAVProtocol.renderDashboardHTML(items: [item], webdavEnabled: true), as: UTF8.self)
        XCTAssertFalse(html.contains("delItem('/a'file.txt')"))
        XCTAssertTrue(html.contains("delItem(this.dataset.href)"))
    }

    func testPlistCodecAndHexDumpRoundTrip() throws {
        let sample: [String: PlistCustomValue] = [
            "AppTitle": .string("ZynSign"),
            "BuildNumber": .integer(42),
            "Enabled": .boolean(true)
        ]
        let xmlData = try PlistDocumentCodec.encode(sample, format: .xml)
        let decoded = try PlistDocumentCodec.decode(xmlData)
        XCTAssertEqual(decoded.root, sample)

        let rawBytes = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x41, 0x42])
        let hexLine = HexDumpFormatter.encodeHexString(rawBytes)
        XCTAssertTrue(hexLine.contains("DE AD BE EF"))
        let rows = HexDumpFormatter.formatWindow(data: rawBytes)
        XCTAssertEqual(rows.count, 1)
        let reparsed = try HexDumpFormatter.parseHexBytes("DE AD BE EF 41 42")
        XCTAssertEqual(reparsed, rawBytes)
    }

    func testIncomingURLRouterSupportsZynSignSchemesAndContainerLaunch() throws {
        let expectedIPA = try XCTUnwrap(URL(string: "https://cdn.zynsign.io/Test.ipa"))
        let installURL = try XCTUnwrap(URL(string: "zynsign://install?url=https://cdn.zynsign.io/Test.ipa"))
        XCTAssertEqual(
            IncomingURLRouter.parse(installURL),
            .installPackage(expectedIPA)
        )

        let expectedRepo = try XCTUnwrap(URL(string: "https://repo.zynsign.io/apps.json"))
        let sourceURL = try XCTUnwrap(URL(string: "zyn://source?url=https://repo.zynsign.io/apps.json"))
        XCTAssertEqual(
            IncomingURLRouter.parse(sourceURL),
            .addSource(expectedRepo)
        )

        let guestURL = try XCTUnwrap(URL(string: "zynsign://launch-guest?bundleId=io.zynsign.demo&slot=work"))
        XCTAssertEqual(
            IncomingURLRouter.parse(guestURL),
            .launchGuestContainer(bundleIdentifier: "io.zynsign.demo", slotID: "work")
        )
    }
}
