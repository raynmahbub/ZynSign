import Foundation
import XCTest
@testable import ZynSign

final class ZynWorkspaceAndWebDAVTests: XCTestCase {

    // MARK: - LAN Web Workspace: targets

    private func components(_ target: String) -> Result<[String], WebDAVRequestRejection> {
        WebDAVPathPolicy.components(fromTarget: target)
    }

    func testTargetParsingAcceptsOriginAndAbsoluteForms() {
        XCTAssertEqual(try? components("/Packages/Sample.ipa").get(), ["Packages", "Sample.ipa"])
        XCTAssertEqual(try? components("http://192.168.1.4:8088/Packages/Sample.ipa").get(), ["Packages", "Sample.ipa"])
        XCTAssertEqual(try? components("HTTPS://host/Files/").get(), ["Files"])
        XCTAssertEqual(try? components("/").get(), [])
        XCTAssertEqual(try? components("/Packages/Sample.ipa?cache=1").get(), ["Packages", "Sample.ipa"])
    }

    func testTargetParsingRefusesTraversalHoweverItIsEncoded() {
        XCTAssertEqual(components("/../../etc/passwd"), .failure(.traversal))
        XCTAssertEqual(components("/%2e%2e/etc"), .failure(.traversal))
        XCTAssertEqual(components("/Packages/%2e%2e%2fetc"), .failure(.traversal))
        XCTAssertEqual(components("/Packages/.."), .failure(.traversal))
    }

    func testTargetParsingRefusesAmbiguousAndReinterpretableNames() {
        XCTAssertEqual(components("/Packages//Sample.ipa"), .failure(.emptyComponent))
        XCTAssertEqual(components("/Packages/bad\u{01}name.ipa"), .failure(.reservedCharacter))
        XCTAssertEqual(components("/Packages/bad\\name.ipa"), .failure(.reservedCharacter))
        XCTAssertEqual(components("/.hidden.ipa"), .failure(.hiddenName))
        XCTAssertEqual(components("/Packages/trailing."), .failure(.trailingDotOrSpace))
        XCTAssertEqual(components("/Packages/name "), .failure(.trailingDotOrSpace))
        XCTAssertEqual(components("/Packages/COM1"), .failure(.reservedCharacter))
        XCTAssertEqual(components("/" + String(repeating: "x", count: 256)), .failure(.componentTooLong(limit: 255)))
        XCTAssertEqual(components(String(repeating: "/x", count: 17)), .failure(.tooManyComponents(limit: 16)))
        XCTAssertEqual(components("/Packages/%ZZ"), .failure(.undecodableTarget))
    }

    func testTargetParsingRefusesWhatIsNotAPath() {
        XCTAssertEqual(components("Packages/Sample.ipa"), .failure(.unreadableTarget))
        XCTAssertEqual(components("ftp://host/Packages/Sample.ipa"), .failure(.unreadableTarget))
        XCTAssertEqual(LANWebWorkspaceService.handleRequest(
            head: head("GET", "ftp://host/x"),
            bodyFileURL: nil,
            rootDirectory: FileManager.default.temporaryDirectory,
            webdavEnabled: true,
            expectedUser: Self.user,
            expectedPass: Self.password,
            maximumDownloadBytes: 4_096,
            protectedTopLevelDirectories: LANWebWorkspaceService.protectedTopLevelDirectories
        ).status, 400)
    }

    // MARK: - LAN Web Workspace: credentials

    func testCredentialIsRequiredAndNeverEmptyOrShort() {
        XCTAssertNotNil(LANWebWorkspaceService.credentialRefusal(username: "zynsign", password: ""))
        XCTAssertNotNil(LANWebWorkspaceService.credentialRefusal(username: "zynsign", password: "short"))
        XCTAssertNotNil(LANWebWorkspaceService.credentialRefusal(username: "zyn:sign", password: Self.password))
        XCTAssertNotNil(LANWebWorkspaceService.credentialRefusal(username: "  ", password: Self.password))
        XCTAssertNil(LANWebWorkspaceService.credentialRefusal(username: "zynsign", password: Self.password))
        XCTAssertFalse(WebDAVProtocol.verifyBasicAuthorization(headerValue: nil, expectedUsername: "user", expectedPassword: ""))
    }

    func testEveryUnauthenticatedMethodIsAnsweredBeforeAnythingIsDecided() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("keep".utf8).write(to: root.appendingPathComponent("Packages/keep.ipa"))

        for method in ["GET", "HEAD", "PROPFIND", "PUT", "DELETE", "MKCOL", "MOVE", "COPY", "OPTIONS"] {
            let response = dispatch(head(method, "/Packages/keep.ipa", authorized: false), root: root)
            XCTAssertEqual(response.status, 401, method)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Packages/keep.ipa").path))
    }

    func testARequestFromAnotherSiteIsRefusedEvenWithACredential() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let victim = root.appendingPathComponent("Packages/victim.ipa")
        try Data("bytes".utf8).write(to: victim)

        XCTAssertEqual(dispatch(
            head("DELETE", "/Packages/victim.ipa", headers: [
                "host": "192.168.1.4:8088",
                "origin": "http://evil.example"
            ]),
            root: root
        ).status, 403)
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))

        XCTAssertEqual(dispatch(
            head("PUT", "/Packages/new.ipa", headers: [
                "host": "192.168.1.4:8088",
                "sec-fetch-site": "cross-site"
            ]),
            root: root
        ).status, 403)

        XCTAssertEqual(dispatch(
            head("DELETE", "/Packages/victim.ipa", headers: [
                "host": "192.168.1.4:8088",
                "origin": "http://192.168.1.4:8088"
            ]),
            root: root
        ).status, 204)
        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path))
    }

    func testAuthenticatedRequestReachesTheWorkspaceAndWebDAVGateHolds() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(dispatch(head("GET", "/"), root: root).status, 200)
        XCTAssertEqual(dispatch(head("DELETE", "/Packages"), root: root).status, 403)
        XCTAssertEqual(dispatch(head("PROPFIND", "/Packages"), root: root, webdavEnabled: false).status, 405)
        XCTAssertEqual(dispatch(head("MKCOL", "/Files/Sub"), root: root, webdavEnabled: false).status, 405)
        XCTAssertEqual(dispatch(head("DELETE", "/Packages"), root: root, webdavEnabled: false).status, 405)
        // The dashboard's own upload is the one write that survives the drive
        // being off; that mode exists to receive files.
        XCTAssertEqual(dispatch(head("PUT", "/Files/browser.ipa", length: 0), root: root, webdavEnabled: false).status, 201)
        XCTAssertEqual(dispatch(head("MKCOL", "/Files/Sub"), root: root).status, 201)
        XCTAssertEqual(dispatch(head("GET", "/Files"), root: root).status, 404)
    }

    // MARK: - LAN Web Workspace: mutations

    func testTheWorkspaceRootAndItsCategoryFoldersCannotBeRemovedOrReplaced() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(dispatch(head("DELETE", "/"), root: root).status, 403)
        XCTAssertEqual(dispatch(head("DELETE", "/Tweaks"), root: root).status, 403)
        XCTAssertEqual(dispatch(head("MOVE", "/Packages", headers: ["destination": "/Files/Packages"]), root: root).status, 403)
        XCTAssertEqual(dispatch(head("COPY", "/Files/new.ipa", headers: ["destination": "/Materials"]), root: root).status, 403)
        XCTAssertEqual(dispatch(head("PUT", "/", length: 0), root: root).status, 403)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Tweaks").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Packages").path))
    }

    func testDeleteRequiresTheCredentialAndStaysInsideTheWorkspace() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let victim = root.appendingPathComponent("Packages/victim.ipa")
        try Data("bytes".utf8).write(to: victim)

        XCTAssertEqual(dispatch(head("DELETE", "/Packages/victim.ipa", authorized: false), root: root).status, 401)
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))
        XCTAssertEqual(dispatch(head("DELETE", "/Packages/victim.ipa"), root: root).status, 204)
        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path))
    }

    func testMoveAndCopyRefuseOverwritesAndAcceptAbsoluteDestinations() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: existing)
        let source = root.appendingPathComponent("Files/source.ipa")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("ipa".utf8).write(to: source)

        for method in ["MOVE", "COPY"] {
            let response = dispatch(head(method, "/missing.txt", headers: ["destination": "/keep.txt"]), root: root)
            XCTAssertNotEqual(response.status, 201)
            XCTAssertEqual(try Data(contentsOf: existing), Data("keep".utf8))
        }
        XCTAssertEqual(dispatch(head("MOVE", "/keep.txt", headers: ["destination": "/keep.txt"]), root: root).status, 412)

        let absolute = "http://127.0.0.1:8088/Materials/moved.ipa"
        XCTAssertEqual(dispatch(head("MOVE", "/Files/source.ipa", headers: ["destination": absolute]), root: root).status, 201)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Materials/moved.ipa").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testSymlinksCannotCarryARequestOutOfTheWorkspace() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Packages"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        try Data("outside".utf8).write(to: base.appendingPathComponent("secret.txt"))
        let realFile = base.appendingPathComponent("secret.ipa")
        try Data("outside".utf8).write(to: realFile)
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: base)

        XCTAssertEqual(dispatch(head("GET", "/link/secret.txt"), root: root).status, 403)
        XCTAssertEqual(dispatch(head("PUT", "/link/secret.ipa", length: 0), root: root).status, 403)
        XCTAssertEqual(dispatch(head("DELETE", "/link/secret.ipa"), root: root).status, 403)
        XCTAssertEqual(try Data(contentsOf: realFile), Data("outside".utf8))
        let listed = String(decoding: dispatch(head("PROPFIND", "/", headers: ["depth": "1"]), root: root).body, as: UTF8.self)
        XCTAssertFalse(listed.contains("link"))
    }

    // MARK: - LAN Web Workspace: bodies

    func testAnIncompleteUploadIsNeverPublished() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let partial = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("four".utf8).write(to: partial)
        defer { try? FileManager.default.removeItem(at: partial) }

        let target = root.appendingPathComponent("Packages/partial.ipa")
        XCTAssertEqual(dispatch(head("PUT", "/Packages/partial.ipa", length: 10), bodyFileURL: partial, root: root).status, 400)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))

        let complete = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("0123456789".utf8).write(to: complete)
        XCTAssertEqual(dispatch(head("PUT", "/Packages/complete.ipa", length: 10), bodyFileURL: complete, root: root).status, 201)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Packages/complete.ipa")), Data("0123456789".utf8))
    }

    func testADownloadPastTheServedBoundIsRefusedByName() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let big = root.appendingPathComponent("Packages/big.ipa")
        try Data(repeating: 0x41, count: 4_097).write(to: big)

        XCTAssertEqual(dispatch(head("GET", "/Packages/big.ipa"), root: root, maximumDownloadBytes: 4_096).status, 413)
        XCTAssertEqual(dispatch(head("GET", "/Packages/big.ipa"), root: root, maximumDownloadBytes: 8_192).status, 200)
    }

    func testWebDAVFramingRefusalsStayRefused() {
        XCTAssertNil(WebDAVProtocol.parseHead(Data("PUT /a HTTP/1.1\r\nContent-Length: 1\r\ncontent-length: 2\r\n\r\n".utf8)))
        XCTAssertNil(WebDAVProtocol.parseHead(Data("PUT /a HTTP/1.1\r\nHost: local\r\n\r\n".utf8)))
        XCTAssertNil(WebDAVProtocol.parseHead(Data("GET /a HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)))
    }

    func testWebDAVMultistatusRendering() {
        let xml = WebDAVProtocol.renderMultiStatusXML(resources: [
            .init(hrefPath: "/dav/", displayName: "dav", isDirectory: true, byteSize: 0, modifiedAt: Date())
        ])
        let rendered = String(decoding: xml, as: UTF8.self)
        XCTAssertTrue(rendered.contains("<D:multistatus"))
        XCTAssertTrue(rendered.contains("<D:collection/>"))
    }

    // MARK: - LAN Web Workspace: dashboard

    func testDashboardDoesNotPutFileNamesInInlineJavaScript() {
        let item = WebDAVProtocol.ResourceMetadata(hrefPath: "/a'file.txt", displayName: "a'file.txt",
            isDirectory: false, byteSize: 1, modifiedAt: Date())
        let html = String(decoding: WebDAVProtocol.renderDashboardHTML(items: [item], webdavEnabled: true), as: UTF8.self)
        XCTAssertFalse(html.contains("delItem('/a'file.txt')"))
        XCTAssertTrue(html.contains("delItem(this.dataset.href)"))
        // With the drive off the page offers no control the server would refuse.
        let browserOnly = String(decoding: WebDAVProtocol.renderDashboardHTML(items: [item], webdavEnabled: false), as: UTF8.self)
        XCTAssertFalse(browserOnly.contains("delItem("))
    }

    // MARK: - LAN Web Workspace: helpers

    private static let user = "zynsign"
    private static let password = "correct-horse-battery"

    private func head(
        _ method: String,
        _ target: String,
        headers: [String: String] = [:],
        length: Int = 0,
        authorized: Bool = true
    ) -> WebDAVProtocol.HTTPRequestHead {
        var resolved = headers
        if authorized {
            let token = Data("\(Self.user):\(Self.password)".utf8).base64EncodedString()
            resolved["authorization"] = "Basic \(token)"
        }
        return WebDAVProtocol.HTTPRequestHead(method: method, rawTarget: target, headers: resolved, contentLength: length)
    }

    private func dispatch(
        _ head: WebDAVProtocol.HTTPRequestHead,
        bodyFileURL: URL? = nil,
        root: URL,
        webdavEnabled: Bool = true,
        maximumDownloadBytes: Int = 4_096
    ) -> WebDAVProtocol.HTTPResponseMessage {
        LANWebWorkspaceService.handleRequest(
            head: head,
            bodyFileURL: bodyFileURL,
            rootDirectory: root,
            webdavEnabled: webdavEnabled,
            expectedUser: Self.user,
            expectedPass: Self.password,
            maximumDownloadBytes: maximumDownloadBytes,
            protectedTopLevelDirectories: LANWebWorkspaceService.protectedTopLevelDirectories
        )
    }

    private func makeWorkspace() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for category in LANWebWorkspaceService.categories {
            try fm.createDirectory(at: root.appendingPathComponent(category), withIntermediateDirectories: true)
        }
        return root
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
