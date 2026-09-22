import XCTest
@testable import ZynSign

final class IPAArtifactTests: XCTestCase {

    private func identifier() throws -> ArtifactIdentifier {
        let uuid = try XCTUnwrap(UUID(uuidString: "6B3FD418-6C5E-4E2A-9B1A-2C3D4E5F6071"))
        return ArtifactIdentifier(uuid: uuid)
    }

    private func bundle() throws -> ApplicationBundle {
        let bundlePath = try XCTUnwrap(ArchivePath(rawValue: "Payload/Example.app"))
        return try ApplicationBundle(bundlePath: bundlePath)
    }

    private func rejection(classification: ValidationClassification) -> ValidationResult {
        ValidationResult(
            classification: classification,
            findings: [
                ValidationFinding(
                    severity: .error,
                    code: .missingApplicationBundle,
                    detail: "synthetic rejection detail"
                )
            ]
        )
    }

    private func identity() throws -> ApplicationIdentity {
        try ApplicationIdentity(
            bundleIdentifier: "com.example.application",
            displayName: "Example",
            shortVersionString: "1.0",
            buildVersion: "1"
        )
    }

    private func metadata() throws -> ApplicationMetadata {
        ApplicationMetadata(identity: try identity(), executableName: "Example")
    }

    private func identifiedBundle() throws -> ApplicationBundle {
        let bundlePath = try XCTUnwrap(ArchivePath(rawValue: "Payload/Example.app"))
        return try ApplicationBundle(
            bundlePath: bundlePath,
            identity: try identity(),
            executablePath: try XCTUnwrap(ArchivePath(rawValue: "Payload/Example.app/Example"))
        )
    }

    func testFreshImportStartsUnexamined() throws {
        let artifact = IPAArtifact(id: identifier(), sourceFileName: "Example.ipa")
        XCTAssertEqual(artifact.id, identifier())
        XCTAssertEqual(artifact.state, .imported)
        XCTAssertEqual(artifact.sourceFileName, "Example.ipa")
        XCTAssertNil(artifact.discoveredBundle)
        XCTAssertNil(artifact.validation)
        XCTAssertFalse(artifact.isExamined)
        XCTAssertFalse(artifact.permitsLaterStages)
    }

    func testFreshImportWithoutSourceFileName() throws {
        let artifact = IPAArtifact(id: identifier())
        XCTAssertNil(artifact.sourceFileName)
        XCTAssertEqual(artifact.state, .imported)
    }

    func testSourceFileNameIsPreservedVerbatim() throws {
        let artifact = IPAArtifact(id: identifier(), sourceFileName: "  My App (1).ipa  ")
        XCTAssertEqual(artifact.sourceFileName, "  My App (1).ipa  ")
    }

    func testExaminationWithValidResultInspectsArtifact() throws {
        let artifact = IPAArtifact(id: identifier(), sourceFileName: "Example.ipa")
        let examined = artifact.examined(bundle: bundle(), validation: ValidationResult.valid())
        XCTAssertEqual(examined.id, identifier())
        XCTAssertEqual(examined.state, .inspected)
        XCTAssertEqual(examined.sourceFileName, "Example.ipa")
        XCTAssertEqual(examined.discoveredBundle, bundle())
        XCTAssertEqual(examined.validation, ValidationResult.valid())
        XCTAssertTrue(examined.isExamined)
        XCTAssertTrue(examined.permitsLaterStages)
    }

    func testExaminationWithRejectingResultInvalidatesArtifact() throws {
        for classification in [ValidationClassification.invalid, .unsupported, .ambiguous] {
            let artifact = IPAArtifact(id: identifier())
            let examined = artifact.examined(bundle: nil, validation: rejection(classification: classification))
            XCTAssertEqual(examined.state, .invalid, "\(classification) must invalidate the artifact.")
            XCTAssertTrue(examined.isExamined)
            XCTAssertFalse(examined.permitsLaterStages)
        }
    }

    func testExaminationDerivationMatchesStateTransitionTable() throws {
        for classification in ValidationClassification.allCases {
            let artifact = IPAArtifact(id: identifier())
            let validation = classification == .valid
                ? ValidationResult.valid()
                : rejection(classification: classification)
            let examined = artifact.examined(bundle: nil, validation: validation)
            XCTAssertEqual(examined.state, ArtifactState.state(following: classification))
        }
    }

    func testExaminationDoesNotMutateOriginal() throws {
        let artifact = IPAArtifact(id: identifier())
        _ = artifact.examined(bundle: bundle(), validation: ValidationResult.valid())
        XCTAssertEqual(artifact.state, .imported)
        XCTAssertFalse(artifact.isExamined)
    }

    func testArtifactsWithSameValuesAreEqual() throws {
        let first = IPAArtifact(id: identifier(), sourceFileName: "Example.ipa")
        let second = IPAArtifact(id: identifier(), sourceFileName: "Example.ipa")
        XCTAssertEqual(first, second)
    }

    func testArtifactsWithDifferentIdentifiersAreNotEqual() throws {
        let first = IPAArtifact(id: identifier(), sourceFileName: "Example.ipa")
        let second = IPAArtifact(sourceFileName: "Example.ipa")
        XCTAssertNotEqual(first, second)
    }

    // MARK: - Metadata examination

    func testFreshImportHasNoMetadata() throws {
        let artifact = IPAArtifact(id: identifier(), sourceFileName: "Example.ipa")
        XCTAssertNil(artifact.metadata)
    }

    func testStructuralExaminationRecordsNoMetadata() throws {
        let artifact = IPAArtifact(id: identifier())
        let examined = artifact.examined(bundle: bundle(), validation: ValidationResult.valid())
        XCTAssertNil(examined.metadata)
    }

    func testMetadataExaminationRecordsMetadataAndIdentifiedBundle() throws {
        let artifact = IPAArtifact(id: identifier(), sourceFileName: "Example.ipa")
        let examined = artifact.examined(bundle: bundle(), validation: ValidationResult.valid())
        let identified = try identifiedBundle()
        let updated = examined.metadataExamined(
            bundle: identified,
            metadata: try metadata(),
            validation: ValidationResult.valid()
        )
        XCTAssertEqual(updated.state, .inspected)
        XCTAssertEqual(updated.discoveredBundle, identified)
        XCTAssertEqual(updated.metadata, metadata())
        XCTAssertTrue(updated.permitsLaterStages)
    }

    func testMetadataExaminationFailureInvalidatesArtifact() throws {
        let artifact = IPAArtifact(id: identifier())
        let examined = artifact.examined(bundle: bundle(), validation: ValidationResult.valid())
        let updated = examined.metadataExamined(
            bundle: bundle(),
            metadata: nil,
            validation: ValidationResult.invalid(
                findings: [
                    ValidationFinding(
                        severity: .error,
                        code: .missingRequiredMetadata,
                        detail: "synthetic metadata failure detail"
                    )
                ]
            )
        )
        XCTAssertEqual(updated.state, .invalid)
        XCTAssertNil(updated.metadata)
        XCTAssertFalse(updated.permitsLaterStages)
        XCTAssertEqual(updated.validation?.errors.map(\.code), [.missingRequiredMetadata])
    }

    func testMetadataExaminationDoesNotMutateOriginal() throws {
        let artifact = IPAArtifact(id: identifier())
        let examined = artifact.examined(bundle: bundle(), validation: ValidationResult.valid())
        _ = examined.metadataExamined(
            bundle: try identifiedBundle(),
            metadata: try metadata(),
            validation: ValidationResult.valid()
        )
        XCTAssertNil(examined.metadata)
        XCTAssertNil(examined.discoveredBundle?.identity)
    }
}
