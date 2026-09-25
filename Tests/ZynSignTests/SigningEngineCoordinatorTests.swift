import Foundation
import XCTest
@testable import ZynSign

/// Tests for the signing engine: the coordinator that executes one complete
/// signing run behind a single entry point.
///
/// The success paths sign the same synthetic containers the pipeline tests
/// sign — an information file, unsigned Mach-O fixtures, and the profile
/// container the provisioning suites already commit. Failure paths prove the
/// engine's promises: the run stops before signing when validation refuses,
/// the original is never modified, the working copy is always discarded, an
/// artifact that was already at the delivery location survives a failed run,
/// and nothing partial is ever delivered.
final class SigningEngineCoordinatorTests: XCTestCase {

    private typealias PolicyFixtures = ProvisioningPolicyFixtures

    /// An instant inside the synthetic fixture profile's validity period.
    private static let insideValidity = Date(timeIntervalSince1970: 1_800_000_000)

    private var temporaryDirectory: URL!

    override func setUp() {
        super.setUp()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zynsign-engine-tests-\(UUID().uuidString)", isDirectory: true)
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

    func testSignsEndToEndAndDeliversAVerifiedContainer() async throws {
        let identities = try NestedSigningTestIdentityStore()
        let source = try writeSource(entries: applicationEntries())
        let output = temporaryDirectory.appendingPathComponent("Signed.ipa")
        let engine = makeEngine(identities: identities)

        let result = try await engine.sign(try makeRequest(source: source, output: output, identity: identities))

        XCTAssertEqual(result.status, .signed)
        XCTAssertEqual(result.outputURL, output)
        XCTAssertNil(result.failure)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))

        // Every stage reports a structured outcome, in execution order.
        XCTAssertEqual(result.stages.map(\.stage), SigningEngineStage.allCases)
        for stage in [SigningEngineStage.preparing, .validating, .signingApplication, .verifying, .packaging, .complete] {
            XCTAssertEqual(result.outcome(for: stage)?.status, .succeeded, "\(stage.title) did not succeed")
        }
        // A bundle with no nested code reports its nested stages as skipped,
        // with a reason — never as work that happened.
        for stage in SigningEngineStage.allCases where stage.isNestedSigningStage {
            XCTAssertEqual(result.outcome(for: stage)?.status, .skipped, "\(stage.title) should be skipped")
        }
        XCTAssertTrue(result.failedStages.isEmpty)

        let summary = try XCTUnwrap(result.summary)
        XCTAssertEqual(summary.bundleName, "Synthetic.app")
        XCTAssertEqual(summary.bundleIdentifier, PolicyFixtures.bundleIdentifier)
        XCTAssertEqual(summary.executableName, "Synthetic")
        XCTAssertEqual(summary.nestedTargetCount, 0)
        XCTAssertEqual(summary.signedBinaryCount, 1)
        XCTAssertEqual(summary.sealedResourceCount, 2)
        XCTAssertGreaterThan(summary.containerByteCount, 0)
        XCTAssertTrue(summary.verificationPassed)

        // Independent verification of the working copy, then of the delivered
        // container: both ran, and both passed.
        let verification = try XCTUnwrap(result.verification)
        XCTAssertTrue(verification.passed)
        XCTAssertTrue(verification.checks.contains { $0.name == "main/page-hashes" })
        XCTAssertTrue(verification.checks.contains { $0.name == "main/special-slots" })
        XCTAssertTrue(verification.checks.contains { $0.name == "main/signature" })
        XCTAssertTrue(verification.checks.contains { $0.name == "main/provisioning-compatibility" })
        XCTAssertTrue(verification.checks.contains { $0.name == "main/bundle-consistency" })
        let container = try XCTUnwrap(result.containerVerification)
        XCTAssertTrue(container.passed)
        XCTAssertTrue(container.checks.allSatisfy(\.passed))

        // Recovery facts: the working copy went away and the original was
        // re-measured, not assumed.
        let workingCopy = try XCTUnwrap(result.workingCopy)
        XCTAssertTrue(workingCopy.discarded)
        XCTAssertTrue(workingCopy.originalUnchanged)
        XCTAssertGreaterThan(workingCopy.reclaimedItemCount, 0)
    }

    func testSignsNestedFrameworkAndReportsItsStage() async throws {
        let identities = try NestedSigningTestIdentityStore()
        var entries = applicationEntries()
        entries.append(.directory("Payload/Synthetic.app/Frameworks"))
        entries.append(.directory("Payload/Synthetic.app/Frameworks/Test.framework"))
        entries.append(ZipFixtureBuilder.Entry(
            name: "Payload/Synthetic.app/Frameworks/Test.framework/Info.plist",
            content: Array(informationFile(
                bundleIdentifier: "com.example.synthetic.nested",
                executable: "Test"
            ))
        ))
        entries.append(ZipFixtureBuilder.Entry(
            name: "Payload/Synthetic.app/Frameworks/Test.framework/Test",
            content: Array(MachOSigningFixtures.unsignedMachO),
            unixMode: 0o100_755
        ))
        let source = try writeSource(entries: entries)
        let output = temporaryDirectory.appendingPathComponent("SignedNested.ipa")
        let engine = makeEngine(identities: identities)

        let result = try await engine.sign(try makeRequest(source: source, output: output, identity: identities))

        XCTAssertEqual(result.status, .signed)
        XCTAssertEqual(result.outcome(for: .signingFrameworks)?.status, .succeeded)
        XCTAssertEqual(result.outcome(for: .signingFrameworks)?.metrics.nestedTargetCount, 1)
        XCTAssertEqual(result.outcome(for: .signingExtensions)?.status, .skipped)
        let summary = try XCTUnwrap(result.summary)
        XCTAssertEqual(summary.nestedTargetCount, 1)
        XCTAssertEqual(summary.signedBinaryCount, 2)
        let verification = try XCTUnwrap(result.verification)
        XCTAssertTrue(verification.passed)
        XCTAssertTrue(
            verification.checks.contains { $0.name.hasPrefix("Frameworks/Test.framework/Test/page-hashes") },
            "The nested binary's page hashes were not verified"
        )
    }

    // MARK: - Refusals

    func testRefusesAlreadySignedInputBeforeSigningAnything() async throws {
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
        let originalBytes = try Data(contentsOf: source)
        let output = temporaryDirectory.appendingPathComponent("Signed.ipa")
        let engine = makeEngine(identities: identities)

        let result = try await engine.sign(try makeRequest(source: source, output: output, identity: identities))

        XCTAssertEqual(result.status, .failed)
        let failure = try XCTUnwrap(result.failure)
        XCTAssertEqual(failure.stage, .validating)
        XCTAssertEqual(failure.category, .unsupportedInput)
        XCTAssertFalse(failure.isRetryable)
        XCTAssertTrue(failure.originalUnchanged)
        XCTAssertTrue(failure.workingCopyDiscarded)
        XCTAssertFalse(failure.outputPreexisted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertNil(result.expectations)
        XCTAssertNil(result.summary)
        // The original container is byte-identical: validation only read it.
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        // The run stopped at validation — no signing stage ran.
        XCTAssertEqual(result.outcome(for: .validating)?.status, .failed)
        XCTAssertEqual(result.outcome(for: .signingApplication)?.status, .skipped)
        XCTAssertTrue(result.stages.first { $0.stage == .signingApplication }?.detail.hasPrefix("Not reached") ?? false)
    }

    func testRefusesWhenTheInformationFileIsMissing() async throws {
        let identities = try NestedSigningTestIdentityStore()
        let source = try writeSource(entries: [
            .directory("Payload"),
            .directory("Payload/Synthetic.app"),
            ZipFixtureBuilder.Entry(
                name: "Payload/Synthetic.app/Synthetic",
                content: Array(MachOSigningFixtures.unsignedMachO),
                unixMode: 0o100_755
            ),
        ])
        let output = temporaryDirectory.appendingPathComponent("Signed.ipa")
        let engine = makeEngine(identities: identities)

        let result = try await engine.sign(try makeRequest(source: source, output: output, identity: identities))

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.failure?.stage, .validating)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testFailedRunLeavesAnArtifactThatWasAlreadyThere() async throws {
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
        let sentinel = Data("an artifact from an earlier run".utf8)
        try sentinel.write(to: output)
        let engine = makeEngine(identities: identities)

        let result = try await engine.sign(try makeRequest(source: source, output: output, identity: identities))

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.failure?.outputPreexisted, true)
        XCTAssertEqual(try Data(contentsOf: output), sentinel)
    }

    // MARK: - Working copy

    func testDiscardsItsWorkingCopyOnSuccessAndOnFailure() async throws {
        let identities = try NestedSigningTestIdentityStore()
        let workingRoot = temporaryDirectory.appendingPathComponent("WorkingCopies", isDirectory: true)
        try FileManager.default.createDirectory(at: workingRoot, withIntermediateDirectories: true)
        let engine = makeEngine(identities: identities, workingDirectoryRoot: workingRoot)

        let source = try writeSource(entries: applicationEntries())
        let output = temporaryDirectory.appendingPathComponent("Signed.ipa")
        let signed = try await engine.sign(try makeRequest(source: source, output: output, identity: identities))
        XCTAssertEqual(signed.status, .signed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workingRoot.path), [])

        let refusedSource = try writeSource(entries: [
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
        let refused = try await engine.sign(try makeRequest(
            source: refusedSource,
            output: temporaryDirectory.appendingPathComponent("Refused.ipa"),
            identity: identities
        ))
        XCTAssertEqual(refused.status, .failed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workingRoot.path), [])
    }

    // MARK: - Progress

    func testReportsMonotonicProgressAndCompletesEveryStage() async throws {
        let identities = try NestedSigningTestIdentityStore()
        let source = try writeSource(entries: applicationEntries())
        let output = temporaryDirectory.appendingPathComponent("Signed.ipa")
        let engine = makeEngine(identities: identities)
        var snapshots: [SigningEngineProgress] = []

        let result = try await engine.sign(
            try makeRequest(source: source, output: output, identity: identities),
            progress: { snapshots.append($0) }
        )

        XCTAssertEqual(result.status, .signed)
        XCTAssertFalse(snapshots.isEmpty)
        XCTAssertEqual(snapshots.first?.currentStage, .preparing)
        for snapshot in snapshots {
            XCTAssertGreaterThanOrEqual(snapshot.fractionCompleted, 0)
            XCTAssertLessThanOrEqual(snapshot.fractionCompleted, 1)
            XCTAssertEqual(snapshot.records.count, SigningEngineStage.allCases.count)
        }
        let fractions = snapshots.map(\.fractionCompleted)
        XCTAssertEqual(fractions, fractions.sorted())
        // An estimate is either absent or a whole positive number of seconds.
        for snapshot in snapshots {
            if let seconds = snapshot.estimatedRemainingSeconds {
                XCTAssertGreaterThanOrEqual(seconds, 1)
            }
        }
        XCTAssertTrue(result.progress.isComplete)
        XCTAssertEqual(result.progress.fractionCompleted, 1, accuracy: 0.0001)
        XCTAssertEqual(result.progress.currentStage, nil)
        XCTAssertTrue(result.progress.accessibilityDescription.contains("Signing complete"))
    }

    // MARK: - Verify again

    func testVerifiesTheDeliveredContainerAgainWithoutRemovingIt() async throws {
        let identities = try NestedSigningTestIdentityStore()
        let source = try writeSource(entries: applicationEntries())
        let output = temporaryDirectory.appendingPathComponent("Signed.ipa")
        let engine = makeEngine(identities: identities)

        let result = try await engine.sign(try makeRequest(source: source, output: output, identity: identities))
        XCTAssertEqual(result.status, .signed)
        let expectations = try XCTUnwrap(result.expectations)

        let reVerification = try await engine.verifyAgain(containerURL: output, expectations: expectations)
        XCTAssertTrue(reVerification.passed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))

        // A container that no longer verifies is a reported refusal, and the
        // file the user has is never removed by verification.
        try Data("not a container any more".utf8).write(to: output)
        do {
            let tampered = try await engine.verifyAgain(containerURL: output, expectations: expectations)
            XCTAssertFalse(tampered.passed)
        } catch {
            XCTAssertTrue(error is ZynSignError)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    // MARK: - Helpers

    private func applicationEntries() -> [ZipFixtureBuilder.Entry] {
        [
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
        ]
    }

    private func makeRequest(
        source: URL,
        output: URL,
        identity: NestedSigningTestIdentityStore
    ) throws -> SigningEngineRequest {
        SigningEngineRequest(
            sourceURL: source,
            profile: CMSFixtures.validRSASignedAttributes,
            identityID: identity.id,
            entitlements: try CodeSigningEntitlements(values: [:]),
            outputURL: output,
            options: SignApplicationOptions(deviceContext: .identified(PolicyFixtures.deviceA))
        )
    }

    private func makeEngine(
        identities: NestedSigningTestIdentityStore,
        workingDirectoryRoot: URL? = nil
    ) -> SigningEngineCoordinator {
        SigningEngineCoordinator(
            pipeline: makePipeline(identities: identities),
            validator: SigningEngineBundleValidator(),
            workingCopyVerifier: SigningEngineVerifier(
                identities: identities,
                digest: CryptoKitMessageDigest(),
                cryptographicVerifier: NestedSigningTestVerifier()
            ),
            containerVerifier: VerifySignedApplication(
                digest: CryptoKitMessageDigest(),
                limits: .default
            ),
            digest: CryptoKitMessageDigest(),
            workingDirectoryRoot: workingDirectoryRoot
        )
    }

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
