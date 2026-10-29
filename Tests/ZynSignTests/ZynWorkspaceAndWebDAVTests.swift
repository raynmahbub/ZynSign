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
