import Foundation
import XCTest
@testable import ZynSign

final class ZynSourcesAndCertificatesTests: XCTestCase {

    func testZynCertificateBundleJSONAndPlistRoundTrip() throws {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let original = ZynCertificateBundle(
            name: "StudioDevCert",
            password: "secret-passphrase",
            p12Data: Data([0x30, 0x82, 0x01, 0x02]),
            mobileProvisionData: Data([0x30, 0x80, 0x06, 0x09]),
            notes: "Primary team identity",
            createdAt: fixedDate
        )
        let jsonEncoded = try ZynCertificateBundleCodec.encode(original)
        let jsonDecoded = try ZynCertificateBundleCodec.decode(jsonEncoded)
        XCTAssertEqual(jsonDecoded, original)

        let plistEncoded = try ZynCertificateBundleCodec.encodePropertyList(original)
        let plistDecoded = try ZynCertificateBundleCodec.decode(plistEncoded)
        XCTAssertEqual(plistDecoded, original)
    }

    func testPassphraseCandidateGeneratorIncludesFilenameStemsAndCustomEntries() {
        let candidates = ZynCertificateBundleCodec.generatePassphraseCandidates(
            fileName: "DeveloperCert_Pass2026.p12",
            customCandidates: ["my-custom-key"]
        )
        XCTAssertTrue(candidates.contains("my-custom-key"))
        XCTAssertTrue(candidates.contains("DeveloperCert_Pass2026"))
        XCTAssertTrue(candidates.contains("1234"))
    }

    func testEncodedCatalogPayloadDecoderHandlesBase64TokensAndCompactManifest() throws {
        let urlsText = "https://repo.zynsign.io/apps.json\nhttps://mirror.zynsign.io/catalog.json"
        let token = "source[\(Data(urlsText.utf8).base64EncodedString())]source"
        let decodedURLs = EncodedCatalogPayloadDecoder.decodeSourceListText(token)
        XCTAssertEqual(decodedURLs, [
            "https://repo.zynsign.io/apps.json",
            "https://mirror.zynsign.io/catalog.json"
        ])

        let compactJSON = """
        {
          "name": "Compact Repo",
          "apps": [
            {
              "name": "Demo Client",
              "bundleID": "io.zynsign.demo",
              "version": "2.4.0",
              "down": "https://cdn.zynsign.io/DemoClient.ipa"
            }
          ]
        }
        """
        let normalized = EncodedCatalogPayloadDecoder.normalizeManifestPayload(Data(compactJSON.utf8))
        let parsed = try JSONSerialization.jsonObject(with: normalized) as? [String: Any]
        let apps = parsed?["apps"] as? [[String: Any]]
        XCTAssertEqual(apps?.first?["bundleIdentifier"] as? String, "io.zynsign.demo")
        XCTAssertEqual(apps?.first?["downloadURL"] as? String, "https://cdn.zynsign.io/DemoClient.ipa")
    }

    func testDNSRevocationShieldProfileAndDownloadLinkExtractor() throws {
        let configData = try DNSRevocationShieldProfile.generateMobileconfig(
            displayName: "ZynSign Shield",
            protocolKind: .https,
            endpoint: "https://dns.quad9.net/dns-query"
        )
        let plist = try PropertyListSerialization.propertyList(from: configData, options: [], format: nil) as? [String: Any]
        XCTAssertEqual(plist?["PayloadType"] as? String, "Configuration")

        let base = try XCTUnwrap(URL(string: "https://downloads.zynsign.io/"))
        let html = """
        <a href="https://downloads.zynsign.io/releases/AppOne.ipa">Direct IPA</a>
        <a href="itms-services://?action=download-manifest&amp;url=https%3A%2F%2Fota.zynsign.io%2Fmanifest.plist">OTA</a>
        """
        let links = DownloadLinkExtractor.extractFromHTML(html, baseURL: base)
        XCTAssertEqual(links.count, 2)
        XCTAssertTrue(links.contains { $0.url.absoluteString == "https://downloads.zynsign.io/releases/AppOne.ipa" })
        XCTAssertTrue(links.contains { $0.kind == .otaManifest })
    }
}
