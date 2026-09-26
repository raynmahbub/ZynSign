import Foundation
import XCTest
@testable import ZynSign

/// Real read-only archive/profile orchestration with a synthetic CMS signature
/// mechanism. No private key is requested and no signing pipeline is run.
final class SigningDiagnosticsServiceTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try LibraryFixtures.makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    func testPackageEvidenceIsIncrementalAndMissingArtifactsInvalidateTheCache() async throws {
        let (service, record, artifacts, reader, _) = fixture()
        let first = try await service.analyze(recordWithID: record.id)
        XCTAssertEqual(first.report.state(for: .package), .passed)
        XCTAssertEqual(first.report.state(for: .metadata), .passed)
        XCTAssertEqual(reader.closeCount, 1)

        _ = try await service.analyze(recordWithID: record.id, emitDEREntitlements: true)
        XCTAssertEqual(reader.closeCount, 1, "Changing an option must not re-read the unchanged archive.")
        _ = try await service.analyze(recordWithID: record.id, force: true)
        XCTAssertEqual(reader.closeCount, 2, "Signing preflight bypasses package cache.")

        artifacts.drop(record.artifact.artifactID)
        let missing = try await service.analyze(recordWithID: record.id)
        XCTAssertEqual(missing.report.state(for: .package), .blocked)
        XCTAssertTrue(missing.report.issues.contains(where: { $0.id == .packageMissing }))
        artifacts.hold(Data([0x01, 0x02, 0x03]), as: record.artifact.artifactID)
        let restored = try await service.analyze(recordWithID: record.id)
        XCTAssertEqual(restored.report.state(for: .package), .passed)
        XCTAssertEqual(reader.closeCount, 3)
    }

    func testOnlyAuthenticatedProfileProvidesEntitlementsAndChangedOptionUsesCachedCMS() async throws {
        let (service, record, _, _, verifier) = fixture()
        let profile = CMSFixtures.validRSASignedAttributes
        let verified = try await service.analyze(recordWithID: record.id, profileData: profile)
        XCTAssertNotNil(verified.entitlements)
        XCTAssertGreaterThan(verified.entitlements?.count ?? 0, 0)
        XCTAssertEqual(verifier.callCount, 1)
        // This authenticated development fixture restricts device IDs. No
        // target device was supplied, so coverage must stay unknown.
        XCTAssertEqual(verified.report.state(for: .profile), .unsupported)
        XCTAssertTrue(verified.report.issues.contains(where: { $0.id == .deviceUnverified }))

        let unsupportedDER = try await service.analyze(
            recordWithID: record.id, profileData: profile, emitDEREntitlements: true
        )
        XCTAssertEqual(verifier.callCount, 1, "Policy and options change; CMS input is unchanged.")
        XCTAssertEqual(unsupportedDER.report.state(for: .signingOptions), .unsupported)
        XCTAssertEqual(unsupportedDER.changes?.added, [.derUnavailable])
        XCTAssertEqual(unsupportedDER.changes?.resolved, [.legacyEntitlements])

        await service.identitiesDidChange()
        _ = try await service.analyze(recordWithID: record.id, profileData: profile)
        XCTAssertEqual(verifier.callCount, 2, "An identity-store change invalidates certificate relationships.")

        verifier.result = false
        await service.identitiesDidChange()
        let rejected = try await service.analyze(recordWithID: record.id, profileData: profile)
        XCTAssertNil(rejected.entitlements, "Never replace unverified claims with an empty entitlement set.")
        XCTAssertEqual(rejected.report.state(for: .profile), .blocked)
        XCTAssertTrue(rejected.report.issues.contains(where: { $0.id == .profileUnverified }))
    }

    func testCachedProfileDoesNotInheritAPreviousAppsPolicyOutcome() async throws {
        let (service, record, artifacts, _, _) = fixture()
        let profile = CMSFixtures.validRSASignedAttributes
        _ = try await service.analyze(recordWithID: record.id, profileData: profile)
        artifacts.drop(record.artifact.artifactID)
        let missingPackage = try await service.analyze(recordWithID: record.id, profileData: profile)

        XCTAssertEqual(missingPackage.report.state(for: .package), .blocked)
        XCTAssertNotNil(missingPackage.entitlements)
        XCTAssertFalse(missingPackage.report.issues.contains(where: { $0.id == .profileUnsupported }))
        XCTAssertNotEqual(missingPackage.report.state(for: .bundleIdentifier), .passed)
    }

    func testMalformedOrOversizedProfileCannotProduceSigningClaims() async throws {
        let (service, record, _, _, _) = fixture()
        for input in [Data([0x00]), Data(repeating: 0x30, count: ProvisioningProfileInput.maximumByteCount + 1)] {
            let analysis = try await service.analyze(recordWithID: record.id, profileData: input)
            XCTAssertNil(analysis.entitlements)
            XCTAssertEqual(analysis.report.status, .blocked)
            XCTAssertNotEqual(analysis.report.state(for: .profile), .passed)
        }
    }

    private func fixture() -> (
        SigningDiagnosticsService, ApplicationRecord, SyntheticLibraryArtifactStore,
        SyntheticArchiveReader, RecordingCMSSignatureVerifier
    ) {
        let content = Data([0x01, 0x02, 0x03])
        let reference = LibraryFixtures.reference(to: content)
        let record = LibraryFixtures.record(artifact: reference)
        let artifacts = SyntheticLibraryArtifactStore()
        artifacts.hold(content, as: reference.artifactID)
        let records = InMemoryApplicationRecordStore(records: [record])
        let library = ApplicationLibrary(records: records, artifacts: artifacts)
        let reader = ImportFixtures.validReader()
        let identities = TestIdentityStore()
        let verifier = RecordingCMSSignatureVerifier()
        let clock = FixedEvaluationClock(instant: instant)
        let policy = ValidateProvisioningConfigurationUseCase(
            policyValidator: ProvisioningPolicyValidator(clock: clock), identityStore: identities
        )
        let pipeline = ValidateProvisioningProfileUseCase(
            profileVerification: ProvisioningProfileVerificationUseCase(
                cmsVerifier: ProvisioningProfileCMSVerifier(
                    certificateParser: AppleCertificateParser(), signatureVerifier: verifier
                ),
                inspection: ProvisioningProfileInspectionUseCase(
                    payloadDecoder: UnusedPayloadDecoder(),
                    parser: PropertyListProvisioningProfileParser(certificateParser: AppleCertificateParser()),
                    clock: clock
                ),
                identityStore: identities
            ),
            configurationValidation: policy
        )
        let history = FileSigningDiagnosticsHistoryStore(
            location: directory.appendingPathComponent("SigningDiagnostics.json")
        )
        let date = instant
        let service = SigningDiagnosticsService(
            library: library, readerProvider: SyntheticArchiveReaderProvider.providing(reader),
            identities: identities, profilePipeline: pipeline, policy: policy,
            digest: CryptoKitMessageDigest(), historyStore: history, now: { date }
        )
        return (service, record, artifacts, reader, verifier)
    }
}
