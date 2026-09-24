import Foundation
import XCTest
@testable import ZynSign

/// Tests for independent verification of signed application containers.
///
/// Each test signs a synthetic container with the pipeline and then holds
/// it to expectations the test states itself — read back from the produced
/// container rather than reused from the signing run, so the verifier is
/// exercised as an independent reader. Tampered expectations prove each
/// check can fail.
final class VerifySignedApplicationTests: XCTestCase {

    private typealias PolicyFixtures = ProvisioningPolicyFixtures

    private static let insideValidity = Date(timeIntervalSince1970: 1_800_000_000)

    private var temporaryDirectory: URL!

    override func setUp() {
        super.setUp()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zynsign-verify-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
        super.tearDown()
    }

    // MARK: - Checks

    func testVerifiesSignedContainer() async throws {
        let signed = try await signedContainer()
        let expectations = try expectations(for: signed, profile: CMSFixtures.validRSASignedAttributes)
        let report = try await VerifySignedApplication(digest: CryptoKitMessageDigest())
            .verify(containerURL: signed, expectations: expectations)

        XCTAssertTrue(report.passed)
        XCTAssertEqual(report.checks.map { $0.name }, [
            "structure",
            "metadata",
            "executable-present",
            "profile-bytes",
            "seal-bytes",
            "seal-digests",
            "main-executable",
            "nested-executables",
        ])
        XCTAssertTrue(report.checks.allSatisfy { $0.passed })
    }

    func testDetectsProfileMismatch() async throws {
        let signed = try await signedContainer()
        let expectations = try expectations(for: signed, profile: Data("another profile".utf8))
        let report = try await VerifySignedApplication(digest: CryptoKitMessageDigest())
            .verify(containerURL: signed, expectations: expectations)

        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.checks.first { $0.name == "profile-bytes" }?.passed, false)
    }

    func testDetectsSealMismatch() async throws {
        let signed = try await signedContainer()
        var expectations = try expectations(for: signed, profile: CMSFixtures.validRSASignedAttributes)
        expectations = SignedApplicationExpectations(
            bundlePath: expectations.bundlePath,
            bundleIdentifier: expectations.bundleIdentifier,
            executableName: expectations.executableName,
            executablePath: expectations.executablePath,
            profile: expectations.profile,
            sealedCodeResources: Data("another seal".utf8),
            entitlements: expectations.entitlements,
            nestedExecutablePaths: expectations.nestedExecutablePaths
        )
        let report = try await VerifySignedApplication(digest: CryptoKitMessageDigest())
            .verify(containerURL: signed, expectations: expectations)

        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.checks.first { $0.name == "seal-bytes" }?.passed, false)
    }

    func testDetectsMetadataMismatch() async throws {
        let signed = try await signedContainer()
        var expectations = try expectations(for: signed, profile: CMSFixtures.validRSASignedAttributes)
        expectations = SignedApplicationExpectations(
            bundlePath: expectations.bundlePath,
            bundleIdentifier: try XCTUnwrap(BundleIdentifier(rawValue: "com.example.other")),
            executableName: expectations.executableName,
            executablePath: expectations.executablePath,
            profile: expectations.profile,
            sealedCodeResources: expectations.sealedCodeResources,
            entitlements: expectations.entitlements,
            nestedExecutablePaths: expectations.nestedExecutablePaths
        )
        let report = try await VerifySignedApplication(digest: CryptoKitMessageDigest())
            .verify(containerURL: signed, expectations: expectations)

        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.checks.first { $0.name == "metadata" }?.passed, false)
    }

    func testRefusesUnreadableContainer() async throws {
        let garbage = temporaryDirectory.appendingPathComponent("garbage.ipa")
        try Data("not a container".utf8).write(to: garbage)
        let expectations = SignedApplicationExpectations(
            bundlePath: try XCTUnwrap(ArchivePath(rawValue: "Payload/Synthetic.app")),
            bundleIdentifier: try XCTUnwrap(BundleIdentifier(rawValue: PolicyFixtures.bundleIdentifier)),
            executableName: "Synthetic",
            executablePath: try XCTUnwrap(ArchivePath(rawValue: "Payload/Synthetic.app/Synthetic")),
            profile: CMSFixtures.validRSASignedAttributes,
            sealedCodeResources: Data("seal".utf8),
            entitlements: try CodeSigningEntitlements(values: [:]),
            nestedExecutablePaths: []
        )
        do {
            _ = try await VerifySignedApplication(digest: CryptoKitMessageDigest())
                .verify(containerURL: garbage, expectations: expectations)
            XCTFail("Expected the unreadable container to throw.")
        } catch {
            XCTAssertTrue(error is ZynSignError)
        }
    }

    // MARK: - Helpers

    private func signedContainer() async throws -> URL {
        let identities = try NestedSigningTestIdentityStore()
        let source = temporaryDirectory.appendingPathComponent("source.ipa")
        try Data(ZipFixtureBuilder.archive([
            .directory("Payload"),
            .directory("Payload/Synthetic.app"),
            ZipFixtureBuilder.Entry(
                name: "Payload/Synthetic.app/Info.plist",
                content: Array(informationFile())
            ),
            ZipFixtureBuilder.Entry(
                name: "Payload/Synthetic.app/Synthetic",
                content: Array(MachOSigningFixtures.unsignedMachO),
                unixMode: 0o100_755
            ),
        ])).write(to: source)
        let output = temporaryDirectory.appendingPathComponent("Signed.ipa")
        // The validation stages resolve the request's signing identity by ID.
        // The signing store cannot answer that question, so validation gets
        // its own store carrying the request identity's ID with the fixture
        // profile's certificate fingerprint.
        let validationIdentities = TestIdentityStore()
        let metadata = PolicyFixtures.identityMetadata(
            fingerprint: PolicyFixtures.fingerprint(CMSFixtures.signerCertificateFingerprint)
        )
        validationIdentities.identities = [
            SigningIdentity(
                id: identities.id,
                certificate: metadata.certificate,
                keyAvailability: metadata.keyAvailability,
                association: metadata.association,
                capabilityState: metadata.capabilityState
            ),
        ]
        let pipeline = SignApplicationPipeline(
            identities: identities,
            digest: CryptoKitMessageDigest(),
            signatureVerifier: NestedSigningTestVerifier(),
            profileValidation: ValidateProvisioningProfileUseCase(
                profileVerification: ProvisioningProfileVerificationUseCase(
                    cmsVerifier: ProvisioningProfileCMSVerifier(
                        certificateParser: AppleCertificateParser(),
                        signatureVerifier: RecordingCMSSignatureVerifier()
                    ),
                    inspection: ProvisioningProfileInspectionUseCase(
                        payloadDecoder: UnusedPayloadDecoder(),
                        parser: PropertyListProvisioningProfileParser(certificateParser: AppleCertificateParser()),
                        clock: FixedEvaluationClock(instant: Self.insideValidity)
                    ),
                    identityStore: validationIdentities
                ),
                configurationValidation: ValidateProvisioningConfigurationUseCase(
                    policyValidator: ProvisioningPolicyValidator(clock: FixedEvaluationClock(instant: Self.insideValidity)),
                    identityStore: validationIdentities
                )
            ),
            writer: ZipArchiveWriter()
        )
        let result = try await pipeline.sign(SignApplicationRequest(
            sourceURL: source,
            profile: CMSFixtures.validRSASignedAttributes,
            identityID: identities.id,
            entitlements: try CodeSigningEntitlements(values: [:]),
            outputURL: output,
            options: SignApplicationOptions(deviceContext: .identified(PolicyFixtures.deviceA))
        ))
        XCTAssertEqual(result.status, .signed)
        return try XCTUnwrap(result.outputURL)
    }

    private func expectations(for container: URL, profile: Data) throws -> SignedApplicationExpectations {
        let reader = ZipArchiveReader(location: container)
        defer { reader.close() }
        let sealPath = try XCTUnwrap(ArchivePath(rawValue: "Payload/Synthetic.app/_CodeSignature/CodeResources"))
        let sealed = try reader.readEntryData(at: sealPath, maximumBytes: 1_000_000)
        return SignedApplicationExpectations(
            bundlePath: try XCTUnwrap(ArchivePath(rawValue: "Payload/Synthetic.app")),
            bundleIdentifier: try XCTUnwrap(BundleIdentifier(rawValue: PolicyFixtures.bundleIdentifier)),
            executableName: "Synthetic",
            executablePath: try XCTUnwrap(ArchivePath(rawValue: "Payload/Synthetic.app/Synthetic")),
            profile: profile,
            sealedCodeResources: sealed,
            entitlements: try CodeSigningEntitlements(values: [:]),
            nestedExecutablePaths: []
        )
    }

    private func informationFile() -> Data {
        Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
              <key>CFBundleIdentifier</key><string>\(PolicyFixtures.bundleIdentifier)</string>
              <key>CFBundleExecutable</key><string>Synthetic</string>
              <key>CFBundleShortVersionString</key><string>1.0</string>
              <key>CFBundleVersion</key><string>1</string>
              <key>MinimumOSVersion</key><string>17.0</string>
              <key>UIDeviceFamily</key><array><integer>1</integer></array>
            </dict></plist>
            """.utf8
        )
    }
}
