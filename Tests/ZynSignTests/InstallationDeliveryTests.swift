import XCTest
@testable import ZynSign

/// Tests for the installation delivery hand-off.
///
/// The hand-off produces operator artifacts — a manifest, an install link,
/// channel steps — and must never imply that ZynSign itself installs. These
/// tests pin the manifest shape, the link encoding, the HTTPS requirement,
/// and the honesty of the channel text.
final class InstallationDeliveryTests: XCTestCase {

    private func makePackage() throws -> InstallationDeliveryPackage {
        let artifact = LibraryFixtures.acceptedArtifact()
        let record = try ApplicationRecord(
            admitting: artifact,
            reference: LibraryFixtures.reference(artifactID: artifact.id),
            importedAt: LibraryFixtures.importDate
        )
        return InstallationDeliveryPackage(
            signedIPA: URL(fileURLWithPath: "/Documents/Signed/Example_signed.ipa"),
            record: record
        )
    }

    // MARK: - Package

    func testPackageCarriesRecordIdentityAndOutputName() throws {
        let package = try makePackage()
        XCTAssertEqual(package.fileName, "Example_signed.ipa")
        XCTAssertEqual(package.bundleIdentifier, "com.example.synthetic")
        XCTAssertEqual(package.displayName, "Example")
        XCTAssertFalse(package.bundleVersion.isEmpty)
    }

    // MARK: - Hosting URL validation

    func testHTTPSHostingURLIsValidatedAndTrimmed() throws {
        let service = InstallationDeliveryService()
        let url = try service.validateHostingURL("  https://example.com/App_signed.ipa  ")
        XCTAssertEqual(url.absoluteString, "https://example.com/App_signed.ipa")
    }

    func testPlainHTTPHostingURLIsRefused() {
        let service = InstallationDeliveryService()
        XCTAssertThrowsError(try service.validateHostingURL("http://example.com/App_signed.ipa")) { error in
            XCTAssertEqual(error as? InstallationDeliveryError, .hostingURLMustBeHTTPS)
        }
    }

    func testLocalFileHostingURLIsRefused() {
        let service = InstallationDeliveryService()
        XCTAssertThrowsError(try service.validateHostingURL("file:///Documents/Signed/App_signed.ipa")) { error in
            XCTAssertEqual(error as? InstallationDeliveryError, .hostingURLMustBeHTTPS)
        }
    }

    func testUnparsableHostingURLIsRefused() {
        let service = InstallationDeliveryService()
        XCTAssertThrowsError(try service.validateHostingURL("not a url")) { error in
            XCTAssertEqual(error as? InstallationDeliveryError, .hostingURLUnparsable)
        }
    }

    func testErrorMessagesCarryNoURL() {
        for error in [InstallationDeliveryError.hostingURLMustBeHTTPS, .hostingURLUnparsable, .manifestSerializationFailed, .manifestWriteFailed] {
            XCTAssertFalse(error.userMessage.contains("http"), "Error text must not echo URLs.")
            XCTAssertFalse(error.userMessage.contains("/"), "Error text must not echo paths.")
        }
    }

    // MARK: - Manifest

    func testManifestCarriesAppleOTAShape() throws {
        let service = InstallationDeliveryService()
        let package = try makePackage()
        let packageURL = try service.validateHostingURL("https://example.com/apps/Example_signed.ipa")
        let manifestURL = try service.validateHostingURL("https://example.com/apps/manifest.plist")

        let manifest = try service.manifest(for: package, packageURL: packageURL, manifestURL: manifestURL)

        let items = try XCTUnwrap(manifest.propertyList["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        let assets = try XCTUnwrap(items[0]["assets"] as? [[String: Any]])
        XCTAssertEqual(assets[0]["kind"] as? String, "software-package")
        XCTAssertEqual(assets[0]["url"] as? String, "https://example.com/apps/Example_signed.ipa")
        let metadata = try XCTUnwrap(items[0]["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["bundle-identifier"] as? String, "com.example.synthetic")
        XCTAssertEqual(metadata["bundle-version"] as? String, package.bundleVersion)
        XCTAssertEqual(metadata["kind"] as? String, "software")
        XCTAssertEqual(metadata["title"] as? String, "Example")
    }

    func testManifestSerializesAsXMLPropertyList() throws {
        let service = InstallationDeliveryService()
        let package = try makePackage()
        let manifest = try service.manifest(
            for: package,
            packageURL: try service.validateHostingURL("https://example.com/App_signed.ipa"),
            manifestURL: try service.validateHostingURL("https://example.com/manifest.plist")
        )
        let data = try manifest.xmlData()
        let roundTripped = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertNotNil(roundTripped["items"])
    }

    func testManifestRefusesNonHTTPSAddresses() {
        let service = InstallationDeliveryService()
        let package = InstallationDeliveryPackage(
            fileName: "Example_signed.ipa",
            fileURL: URL(fileURLWithPath: "/Documents/Signed/Example_signed.ipa"),
            displayName: "Example",
            bundleIdentifier: "com.example.synthetic",
            bundleVersion: "1.0",
            buildVersion: nil
        )
        XCTAssertThrowsError(
            try service.manifest(
                for: package,
                packageURL: URL(string: "http://example.com/App_signed.ipa")!,
                manifestURL: URL(string: "https://example.com/manifest.plist")!
            )
        ) { error in
            XCTAssertEqual(error as? InstallationDeliveryError, .hostingURLMustBeHTTPS)
        }
    }

    // MARK: - Install link

    func testInstallLinkUsesItmsServicesWithEncodedManifestURL() throws {
        let service = InstallationDeliveryService()
        let package = try makePackage()
        let manifest = try service.manifest(
            for: package,
            packageURL: try service.validateHostingURL("https://example.com/apps/App_signed.ipa"),
            manifestURL: try service.validateHostingURL("https://example.com/apps/manifest.plist")
        )
        let link = try XCTUnwrap(manifest.installLink)
        XCTAssertEqual(link.scheme, "itms-services")
        let components = try XCTUnwrap(URLComponents(url: link, resolvingAgainstBaseURL: false))
        let query = try XCTUnwrap(components.queryItems)
        XCTAssertEqual(query.first(where: { $0.name == "action" })?.value, "download-manifest")
        XCTAssertEqual(query.first(where: { $0.name == "url" })?.value, "https://example.com/apps/manifest.plist")
    }

    // MARK: - Manifest file

    func testWrittenManifestExistsAndRoundTrips() throws {
        let service = InstallationDeliveryService()
        let package = try makePackage()
        let manifest = try service.manifest(
            for: package,
            packageURL: try service.validateHostingURL("https://example.com/Example_signed.ipa"),
            manifestURL: try service.validateHostingURL("https://example.com/manifest.plist")
        )
        let url = try service.writeManifest(manifest)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(url.lastPathComponent, "manifest.plist")
        let data = try Data(contentsOf: url)
        let roundTripped = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertNotNil(roundTripped["items"])
    }

    // MARK: - Channels

    func testEveryChannelHasHonestStepsAndARequirement() {
        XCTAssertEqual(InstallationDeliveryChannel.allCases.count, 3)
        for channel in InstallationDeliveryChannel.allCases {
            XCTAssertFalse(channel.title.isEmpty)
            XCTAssertFalse(channel.summary.isEmpty)
            XCTAssertFalse(channel.steps.isEmpty)
            XCTAssertFalse(channel.requirement.isEmpty)
            // The text never claims ZynSign performs the delivery.
            let text = ([channel.summary] + channel.steps + [channel.requirement]).joined(separator: " ")
            XCTAssertFalse(text.lowercased().contains("zynsign installs"))
        }
    }

    func testOverTheAirStepsMentionConfirmationAndTrust() {
        let steps = InstallationDeliveryChannel.overTheAir.steps.joined(separator: " ")
        XCTAssertTrue(steps.contains("confirm"), "OTA steps must include the device-side confirmation.")
        XCTAssertTrue(steps.lowercased().contains("trust"), "OTA steps must include the certificate-trust step.")
    }
}
