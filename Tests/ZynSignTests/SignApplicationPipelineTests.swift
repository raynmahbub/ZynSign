import Foundation
import XCTest
@testable import ZynSign

/// Tests for the end-to-end application signing pipeline.
///
/// The success paths sign synthetic containers assembled at run time: an
/// information file declaring the fixture bundle, unsigned Mach-O fixture
/// binaries, and the synthetic profile container the provisioning suites
/// already commit. No real application, identity, or profile is involved.
/// Failure paths prove each stage refuses what it must and delivers
/// nothing.
final class SignApplicationPipelineTests: XCTestCase {

    private typealias PolicyFixtures = ProvisioningPolicyFixtures

    /// An instant inside the synthetic fixture profile's validity period.
    private static let insideValidity = Date(timeIntervalSince1970: 1_800_000_000)

    private var temporaryDirectory: URL!

    override func setUp() {
        super.setUp()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zynsign-pipeline-tests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Success paths

    func testSignsUnsignedApplicationEndToEnd() async throws {
        let identities = try NestedSigningTestIdentityStore()
        let source = try writeSource(entries: [
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
        ])
        let output = temporaryDirectory.appendingPathComponent("Signed.ipa")
        let pipeline = makePipeline(identities: identities)

        let result = try await pipeline.sign(SignApplicationRequest(
            sourceURL: source,
            profile: CMSFixtures.validRSASignedAttributes,
            identityID: identities.id,
            entitlements: try CodeSigningEntitlements(values: [:]),
            outputURL: output,
            options: SignApplicationOptions(deviceContext: .identified(PolicyFixtures.deviceA))
        ))

        XCTAssertEqual(result.status, .signed)
        XCTAssertEqual(result.outputURL, output)
        XCTAssertNil(result.failure)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let stages = try XCTUnwrap(result.stages)
        XCTAssertEqual(stages.integrity.bundleIdentifier.rawValue, PolicyFixtures.bundleIdentifier)
        XCTAssertEqual(stages.integrity.executableName, "Synthetic")
        XCTAssertEqual(stages.profile.overallStatus, .valid)
        XCTAssertEqual(stages.discovery.nestedItemCount, 0)
        XCTAssertEqual(stages.nested.totalTargets, 0)
        XCTAssertEqual(stages.nested.failedCount, 0)
        XCTAssertEqual(stages.sealing.sealedFileCount, 2)
        XCTAssertEqual(stages.sealing.nestedSealCount, 0)
        XCTAssertGreaterThan(stages.mainExecutable.signatureByteCount, 0)
        XCTAssertEqual(stages.packaging.bundlePath.rawValue, "Payload/Synthetic.app")
        XCTAssertTrue(stages.verification.passed)
        XCTAssertTrue(stages.verification.checks.allSatisfy { $0.passed })
    }

    func testSignsNestedFrameworkEndToEnd() async throws {
        let identities = try NestedSigningTestIdentityStore()
        let source = try writeSource(entries: [
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
            .directory("Payload/Synthetic.app/Frameworks"),
            .directory("Payload/Synthetic.app/Frameworks/Test.framework"),
            ZipFixtureBuilder.Entry(
                name: "Payload/Synthetic.app/Frameworks/Test.framework/Info.plist",
                content: Array(informationFile(
                    bundleIdentifier: "com.example.synthetic.nested",
                    executable: "Test"
                ))
            ),
            ZipFixtureBuilder.Entry(
                name: "Payload/Synthetic.app/Frameworks/Test.framework/Test",
                content: Array(MachOSigningFixtures.unsignedMachO),
                unixMode: 0o100_755
            ),
        ])
        let output = temporaryDirectory.appendingPathComponent("SignedNested.ipa")
        let pipeline = makePipeline(identities: identities)

        let result = try await pipeline.sign(SignApplicationRequest(
            sourceURL: source,
            profile: CMSFixtures.validRSASignedAttributes,
            identityID: identities.id,
            entitlements: try CodeSigningEntitlements(values: [:]),
            outputURL: output,
            options: SignApplicationOptions(deviceContext: .identified(PolicyFixtures.deviceA))
        ))

        XCTAssertEqual(result.status, .signed)
        let stages = try XCTUnwrap(result.stages)
        XCTAssertEqual(stages.discovery.nestedItemCount, 1)
        XCTAssertEqual(stages.nested.totalTargets, 1)
        XCTAssertEqual(stages.nested.successfullySignedCount, 1)
        XCTAssertEqual(stages.sealing.nestedSealCount, 1)
        XCTAssertTrue(stages.verification.passed)
    }

    // MARK: - Refusals

    func testRefusesStructurallyInvalidSource() async throws {
        let identities = try NestedSigningTestIdentityStore()
        let source = temporaryDirectory.appendingPathComponent("broken.ipa")
        try Data("not a container".utf8).write(to: source)
        let output = temporaryDirectory.appendingPathComponent("Signed.ipa")

        let result = try await makePipeline(identities: identities).sign(SignApplicationRequest(
            sourceURL: source,
            profile: CMSFixtures.validRSASignedAttributes,
            identityID: identities.id,
            entitlements: try CodeSigningEntitlements(values: [:]),
            outputURL: output,
            options: SignApplicationOptions(deviceContext: .identified(PolicyFixtures.deviceA))
        ))

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.failure?.stage, .integrity)
        XCTAssertNil(result.outputURL)
        XCTAssertNil(result.stages)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testRefusesIncompatibleProfile() async throws {
        let identities = try NestedSigningTestIdentityStore()
        let source = try writeSource(entries: [
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
        ])
        let output = temporaryDirectory.appendingPathComponent("Signed.ipa")

        let result = try await makePipeline(identities: identities).sign(SignApplicationRequest(
            sourceURL: source,
            profile: Data("not a profile".utf8),
            identityID: identities.id,
            entitlements: try CodeSigningEntitlements(values: [:]),
            outputURL: output,
            options: SignApplicationOptions(deviceContext: .identified(PolicyFixtures.deviceA))
        ))

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.failure?.stage, .profile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testRefusesAlreadySignedExecutable() async throws {
        let identities = try NestedSigningTestIdentityStore()
        let source = try writeSource(entries: [
            .directory("Payload"),
            .directory("Payload/Synthetic.app"),
            ZipFixtureBuilder.Entry(
                name: "Payload/Synthetic.app/Info.plist",
                content: Array(informationFile())
            ),
            ZipFixtureBuilder.Entry(
                name: "Payload/Synthetic.app/Synthetic",
                content: Array(MachOSigningFixtures.expectedSignedMachO),
                unixMode: 0o100_755
            ),
        ])
        let output = temporaryDirectory.appendingPathComponent("Signed.ipa")

        let result = try await makePipeline(identities: identities).sign(SignApplicationRequest(
            sourceURL: source,
            profile: CMSFixtures.validRSASignedAttributes,
            identityID: identities.id,
            entitlements: try CodeSigningEntitlements(values: [:]),
            outputURL: output,
            options: SignApplicationOptions(deviceContext: .identified(PolicyFixtures.deviceA))
        ))

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.failure?.stage, .mainExecutable)
        XCTAssertEqual(result.failure?.category, .unsupportedInput)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    // MARK: - Helpers

    private func makePipeline(identities: NestedSigningTestIdentityStore) -> SignApplicationPipeline {
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
        return SignApplicationPipeline(
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
    }

    private func writeSource(entries: [ZipFixtureBuilder.Entry]) throws -> URL {
        let location = temporaryDirectory.appendingPathComponent("\(UUID().uuidString).ipa", isDirectory: false)
        try Data(ZipFixtureBuilder.archive(entries)).write(to: location)
        return location
    }

    private func informationFile(
        bundleIdentifier: String = PolicyFixtures.bundleIdentifier,
        executable: String = "Synthetic"
    ) -> Data {
        Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
              <key>CFBundleIdentifier</key><string>\(bundleIdentifier)</string>
              <key>CFBundleExecutable</key><string>\(executable)</string>
              <key>CFBundleShortVersionString</key><string>1.0</string>
              <key>CFBundleVersion</key><string>1</string>
              <key>MinimumOSVersion</key><string>17.0</string>
              <key>UIDeviceFamily</key><array><integer>1</integer></array>
            </dict></plist>
            """.utf8
        )
    }
}
