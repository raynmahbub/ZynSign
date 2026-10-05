import XCTest
@testable import ZynSign

final class IPSWFirmwareCatalogTests: XCTestCase {

    func testLoadsDevicesAndFirmwareFromTheExpectedAPIEndpoints() async throws {
        let transport = StubIPSWCatalogTransport(responses: [
            "https://api.ipsw.me/v4/devices": Data("""
            [
              {"name":"iPhone 13 Pro","identifier":"iPhone14,2"},
              {"name":"iPhone 12","identifier":"iPhone13,2"}
            ]
            """.utf8),
            "https://api.ipsw.me/v4/device/iPhone14,2?type=ipsw": Data("""
            {
              "firmwares": [
                {
                  "identifier":"iPhone14,2",
                  "version":"18.0",
                  "buildid":"22A3354",
                  "filesize":1127855,
                  "releasedate":"2024-09-16T17:00:00Z",
                  "signed":true,
                  "url":"https://updates.cdn-apple.com/ios/Example.ipsw"
                },
                {
                  "identifier":"iPhone14,2",
                  "version":"17.7",
                  "buildid":"21H16",
                  "signed":false,
                  "url":"https://updates.cdn-apple.com/ios/Older.ipsw"
                }
              ]
            }
            """.utf8),
        ])
        let service = IPSWFirmwareCatalogService(transport: transport)

        let devices = try await service.devices()
        let device = try XCTUnwrap(devices.first { $0.identifier == "iPhone14,2" })
        let firmware = try await service.firmwares(for: device)

        XCTAssertEqual(devices.map(\.name), ["iPhone 12", "iPhone 13 Pro"])
        XCTAssertEqual(firmware.map(\.version), ["18.0", "17.7"])
        XCTAssertEqual(firmware.first?.buildID, "22A3354")
        XCTAssertEqual(firmware.first?.signed, true)
        XCTAssertNotNil(firmware.first?.releaseDate)
        XCTAssertEqual(firmware.first?.appleDownloadURL?.host, "updates.cdn-apple.com")
        XCTAssertEqual(firmware.last?.signed, false)
        let requests = await transport.requestedURLs()
        XCTAssertEqual(requests.count, 2)
    }

    func testRejectsUnsafeDeviceIdentifierBeforeMakingARequest() async throws {
        let transport = StubIPSWCatalogTransport(responses: [:])
        let service = IPSWFirmwareCatalogService(transport: transport)
        let malicious = IPSWDevice(name: "Invalid", identifier: "../other-host")

        do {
            _ = try await service.firmwares(for: malicious)
            XCTFail("An unsafe identifier must be refused.")
        } catch let error as IPSWFirmwareCatalogError {
            XCTAssertEqual(error, .invalidDeviceIdentifier)
        }
        let requests = await transport.requestedURLs()
        XCTAssertTrue(requests.isEmpty)
    }

    func testRejectsOversizedAndMalformedResponses() async throws {
        let oversizedTransport = StubIPSWCatalogTransport(responses: [
            "https://api.ipsw.me/v4/devices": Data(count: IPSWFirmwareCatalogService.maximumResponseBytes + 1),
        ])
        do {
            _ = try await IPSWFirmwareCatalogService(transport: oversizedTransport).devices()
            XCTFail("An oversized catalog response must be refused.")
        } catch let error as IPSWFirmwareCatalogError {
            XCTAssertEqual(error, .responseTooLarge)
        }

        let malformedTransport = StubIPSWCatalogTransport(responses: [
            "https://api.ipsw.me/v4/devices": Data("not json".utf8),
        ])
        do {
            _ = try await IPSWFirmwareCatalogService(transport: malformedTransport).devices()
            XCTFail("Malformed catalog data must be refused.")
        } catch let error as IPSWFirmwareCatalogError {
            XCTAssertEqual(error, .malformedResponse)
        }
    }

    func testOnlyHTTPSAppleFirmwareURLsAreExposedAsDownloadLinks() throws {
        let decoder = JSONDecoder()
        let safe = try decoder.decode(IPSWFirmware.self, from: Data("""
        {"identifier":"iPhone14,2","version":"18.0","buildid":"22A3354","signed":true,"url":"https://updates.cdn-apple.com/ios/Example.ipsw"}
        """.utf8))
        let insecure = try decoder.decode(IPSWFirmware.self, from: Data("""
        {"identifier":"iPhone14,2","version":"18.0","buildid":"22A3354","signed":true,"url":"http://updates.cdn-apple.com/ios/Example.ipsw"}
        """.utf8))
        let untrustedHost = try decoder.decode(IPSWFirmware.self, from: Data("""
        {"identifier":"iPhone14,2","version":"18.0","buildid":"22A3354","signed":true,"url":"https://example.com/Example.ipsw"}
        """.utf8))

        XCTAssertNotNil(safe.appleDownloadURL)
        XCTAssertNil(insecure.appleDownloadURL)
        XCTAssertNil(untrustedHost.appleDownloadURL)
    }
}

private actor StubIPSWCatalogTransport: IPSWFirmwareCatalogTransport {
    private let responses: [String: Data]
    private var requests: [URL] = []

    init(responses: [String: Data]) {
        self.responses = responses
    }

    func fetch(url: URL, timeout: TimeInterval) async throws -> Data {
        requests.append(url)
        guard let response = responses[url.absoluteString] else {
            throw IPSWFirmwareCatalogError.requestFailed
        }
        return response
    }

    func requestedURLs() -> [URL] { requests }
}
