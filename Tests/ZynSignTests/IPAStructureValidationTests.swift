import XCTest
@testable import ZynSign

final class IPAStructureValidationTests: XCTestCase {

    private let validator = IPAStructureValidator()

    private func codes(of inspection: IPAStructureInspection) -> [ValidationIssueCode] {
        inspection.validation.errors.map(\.code)
    }

    // MARK: - Valid packages

    func testAcceptsStructurallyValidPackage() {
        let inspection = validator.validate(entryTable: validPackageEntryTable())
        XCTAssertTrue(inspection.isValid)
        XCTAssertEqual(inspection.validation.classification, .valid)
        XCTAssertTrue(inspection.validation.findings.isEmpty)
        XCTAssertEqual(inspection.bundle?.bundlePath.rawValue, "Payload/Example.app")
        XCTAssertFalse(inspection.bundle?.isIdentified ?? true)
    }

    func testAcceptsPackageWhoseContainerOmitsDirectoryEntries() {
        let inspection = validator.validate(entryTable: [
            makeEntry("Payload/Example.app/Info.plist"),
        ])
        XCTAssertEqual(inspection.validation.classification, .valid)
        XCTAssertEqual(inspection.bundle?.bundlePath.rawValue, "Payload/Example.app")
    }

    func testRejectsContainerWithNoEntries() {
        let inspection = validator.validate(entryTable: [])
        XCTAssertEqual(inspection.validation.classification, .invalid)
        XCTAssertTrue(codes(of: inspection).contains(.missingPayloadDirectory))
        XCTAssertTrue(codes(of: inspection).contains(.missingApplicationBundle))
    }

    func testValidResultCarriesNoErrorFindings() {
        let inspection = validator.validate(entryTable: validPackageEntryTable())
        XCTAssertTrue(inspection.validation.isConsistent)
        XCTAssertTrue(inspection.validation.errors.isEmpty)
    }

    // MARK: - Missing layout

    func testRejectsPackageWithoutPayloadDirectory() {
        let inspection = validator.validate(entryTable: [
            makeEntry("Unpacked", kind: .directory),
            makeEntry("Unpacked/Example.app", kind: .directory),
        ])
        XCTAssertEqual(inspection.validation.classification, .invalid)
        XCTAssertTrue(codes(of: inspection).contains(.missingPayloadDirectory))
        XCTAssertNil(inspection.bundle)
    }

    func testRejectsPackageWithoutApplicationBundle() {
        let inspection = validator.validate(entryTable: [
            makeEntry("Payload", kind: .directory),
            makeEntry("Payload/README.txt"),
        ])
        XCTAssertEqual(inspection.validation.classification, .invalid)
        XCTAssertTrue(codes(of: inspection).contains(.missingApplicationBundle))
        XCTAssertNil(inspection.bundle)
    }

    func testRejectsApplicationNameThatIsNotADirectory() {
        let inspection = validator.validate(entryTable: [
            makeEntry("Payload", kind: .directory),
            makeEntry("Payload/Example.app", kind: .regularFile),
        ])
        XCTAssertEqual(inspection.validation.classification, .invalid)
        XCTAssertTrue(codes(of: inspection).contains(.missingApplicationBundle))
        XCTAssertEqual(inspection.validation.warnings.map(\.code), [.inconsistentMetadata])
    }

    func testRejectsBundleWithoutInformationFile() {
        let inspection = validator.validate(entryTable: [
            makeEntry("Payload", kind: .directory),
            makeEntry("Payload/Example.app", kind: .directory),
            makeEntry("Payload/Example.app/Example"),
        ])
        XCTAssertEqual(inspection.validation.classification, .invalid)
        XCTAssertTrue(codes(of: inspection).contains(.missingInfoPlist))
    }

    func testRejectsInformationFileThatIsNotARegularFile() {
        let inspection = validator.validate(entryTable: [
            makeEntry("Payload", kind: .directory),
            makeEntry("Payload/Example.app", kind: .directory),
            makeEntry("Payload/Example.app/Info.plist", kind: .directory),
        ])
        XCTAssertEqual(inspection.validation.classification, .invalid)
        XCTAssertTrue(codes(of: inspection).contains(.missingInfoPlist))
    }

    // MARK: - Ambiguity

    func testReportsAmbiguousCandidatesAsAmbiguous() {
        let inspection = validator.validate(entryTable: [
            makeEntry("Payload", kind: .directory),
            makeEntry("Payload/First.app", kind: .directory),
            makeEntry("Payload/First.app/Info.plist"),
            makeEntry("Payload/Second.app", kind: .directory),
            makeEntry("Payload/Second.app/Info.plist"),
        ])
        XCTAssertEqual(inspection.validation.classification, .ambiguous)
        XCTAssertEqual(codes(of: inspection), [.multipleApplicationBundles])
        XCTAssertFalse(inspection.validation.classification.permitsLaterStages)
        XCTAssertNil(inspection.bundle)
    }

    // MARK: - Unsafe paths

    func testRejectsPathTraversalEntry() {
        let inspection = validator.validate(entryTable: validPackageEntryTable() + [
            makeRejectedEntry("Payload/Example.app/../../../etc/passwd"),
        ])
        XCTAssertEqual(inspection.validation.classification, .invalid)
        XCTAssertTrue(codes(of: inspection).contains(.unsafePath))
    }

    func testRejectsAbsolutePathEntry() {
        let inspection = validator.validate(entryTable: [
            makeRejectedEntry("/Payload/Example.app/Info.plist"),
        ])
        XCTAssertTrue(codes(of: inspection).contains(.unsafePath))
        XCTAssertEqual(inspection.validation.classification, .invalid)
    }

    func testRejectsBackslashAndDriveStylePaths() {
        let inspection = validator.validate(entryTable: [
            makeRejectedEntry("Payload\\Example.app\\Info.plist"),
            makeRejectedEntry("C:/Payload/Example.app"),
        ])
        XCTAssertEqual(codes(of: inspection).filter { $0 == .unsafePath }.count, 2)
    }

    func testRejectsSuspiciousPathNormalization() {
        let inspection = validator.validate(entryTable: [
            makeRejectedEntry("Payload/./Example.app"),
            makeRejectedEntry("Payload//Example.app"),
            makeRejectedEntry("./Payload/Example.app"),
        ])
        XCTAssertEqual(codes(of: inspection).filter { $0 == .unsafePath }.count, 3)
    }

    func testRejectsDuplicateEntries() {
        let inspection = validator.validate(entryTable: validPackageEntryTable() + [
            makeEntry("Payload/Example.app/Info.plist"),
        ])
        XCTAssertEqual(inspection.validation.classification, .invalid)
        XCTAssertTrue(codes(of: inspection).contains(.conflictingPaths))
    }

    func testRejectsFileAndDirectoryCollisionAtOnePath() {
        let inspection = validator.validate(entryTable: [
            makeEntry("Payload", kind: .directory),
            makeEntry("Payload/Example.app", kind: .directory),
            makeEntry("Payload/Example.app", kind: .regularFile),
            makeEntry("Payload/Example.app/Info.plist"),
        ])
        XCTAssertTrue(codes(of: inspection).contains(.conflictingPaths))
        let finding = inspection.validation.errors.first { $0.code == .conflictingPaths }
        XCTAssertTrue(finding?.detail.contains("twice") ?? false)
    }

    func testRejectsSymbolicLinkEntry() {
        let inspection = validator.validate(entryTable: validPackageEntryTable() + [
            makeEntry("Payload/Example.app/Link", kind: .symbolicLink),
        ])
        XCTAssertEqual(inspection.validation.classification, .unsupported)
        XCTAssertTrue(codes(of: inspection).contains(.unsupportedArchiveFeature))
    }

    func testRejectsUnmodelledEntryKind() {
        let inspection = validator.validate(entryTable: validPackageEntryTable() + [
            makeEntry("Payload/Example.app/Socket", kind: .unsupported),
        ])
        XCTAssertTrue(codes(of: inspection).contains(.unsupportedArchiveFeature))
    }

    // MARK: - Resource policy

    func testRejectsExcessiveEntryCount() {
        let limits = ArchiveLimits(
            maximumEntryCount: 4,
            maximumEntryNameLength: 256,
            maximumPathDepth: 8,
            maximumEntryBytes: 1_024,
            maximumTotalUncompressedBytes: 8_192,
            maximumCompressionRatio: 10,
            maximumInspectionReadBytes: 512
        )
        let table = validPackageEntryTable() + [
            makeEntry("Payload/Example.app/Extra-1"),
            makeEntry("Payload/Example.app/Extra-2"),
        ]
        let inspection = IPAStructureValidator(limits: limits).validate(entryTable: table)
        XCTAssertEqual(inspection.validation.classification, .unsupported)
        XCTAssertTrue(codes(of: inspection).contains(.resourceLimitExceeded))
    }

    func testRejectsOversizedDeclaredEntry() {
        let inspection = validator.validate(entryTable: [
            makeEntry("Payload", kind: .directory),
            makeEntry("Payload/Example.app", kind: .directory),
            makeEntry(
                "Payload/Example.app/Info.plist",
                uncompressedSize: ArchiveLimits.default.maximumEntryBytes + 1,
                compressedSize: 1024
            ),
        ])
        XCTAssertTrue(codes(of: inspection).contains(.resourceLimitExceeded))
        XCTAssertEqual(inspection.validation.classification, .unsupported)
    }

    func testRejectsExcessiveCompressionRatio() {
        let inspection = validator.validate(entryTable: [
            makeEntry("Payload", kind: .directory),
            makeEntry("Payload/Example.app", kind: .directory),
            makeEntry(
                "Payload/Example.app/Info.plist",
                uncompressedSize: (ArchiveLimits.default.maximumCompressionRatio + 1) * 1_000,
                compressedSize: 1_000
            ),
        ])
        XCTAssertTrue(codes(of: inspection).contains(.resourceLimitExceeded))
    }

    func testRejectsExcessiveTotalDeclaredSize() {
        let perEntry = ArchiveLimits.default.maximumTotalUncompressedBytes
        let inspection = validator.validate(entryTable: [
            makeEntry("Payload", kind: .directory),
            makeEntry("Payload/Example.app", kind: .directory),
            makeEntry("Payload/Example.app/Info.plist", uncompressedSize: perEntry, compressedSize: 1024),
            makeEntry("Payload/Example.app/Extra", uncompressedSize: 1, compressedSize: 1),
        ])
        XCTAssertTrue(codes(of: inspection).contains(.resourceLimitExceeded))
    }

    func testRejectsExcessiveNestingDepth() {
        let limits = ArchiveLimits(
            maximumEntryCount: 100,
            maximumEntryNameLength: 256,
            maximumPathDepth: 3,
            maximumEntryBytes: 1_024,
            maximumTotalUncompressedBytes: 8_192,
            maximumCompressionRatio: 10,
            maximumInspectionReadBytes: 512
        )
        let inspection = IPAStructureValidator(limits: limits).validate(entryTable: [
            makeEntry("Payload", kind: .directory),
            makeEntry("Payload/Example.app", kind: .directory),
            makeEntry("Payload/Example.app/Resources/Deep/Info.plist"),
        ])
        XCTAssertTrue(codes(of: inspection).contains(.resourceLimitExceeded))
    }

    func testFindingCountIsBoundedForHostileContainers() {
        let hostile = (0..<500).map { index in
            makeRejectedEntry("../escape-\(index)")
        }
        let inspection = validator.validate(entryTable: hostile)
        let unsafeFindings = inspection.validation.findings.filter { $0.code == .unsafePath }
        XCTAssertEqual(unsafeFindings.count, IPAStructureValidator.maximumFindingsPerIssue)
        XCTAssertEqual(inspection.validation.classification, .invalid)
    }

    // MARK: - Classification precedence

    func testBrokenStructureOutweighsAmbiguity() {
        let inspection = validator.validate(entryTable: [
            makeEntry("Payload", kind: .directory),
            makeEntry("Payload/First.app", kind: .directory),
            makeEntry("Payload/Second.app", kind: .directory),
            makeRejectedEntry("../escape"),
        ])
        XCTAssertEqual(inspection.validation.classification, .invalid)
    }

    func testAmbiguityOutweighsUnsupportedFeatures() {
        let inspection = validator.validate(entryTable: [
            makeEntry("Payload", kind: .directory),
            makeEntry("Payload/First.app", kind: .directory),
            makeEntry("Payload/First.app/Info.plist"),
            makeEntry("Payload/Second.app", kind: .directory),
            makeEntry("Payload/Second.app/Info.plist"),
            makeEntry("Payload/First.app/Link", kind: .symbolicLink),
        ])
        XCTAssertEqual(inspection.validation.classification, .ambiguous)
    }

    func testEveryRejectingClassificationCarriesAtLeastOneError() {
        let tables: [[ArchiveEntry]] = [
            [],
            [makeEntry("Payload", kind: .directory)],
            [makeRejectedEntry("../escape")],
            [
                makeEntry("Payload", kind: .directory),
                makeEntry("Payload/A.app", kind: .directory),
                makeEntry("Payload/B.app", kind: .directory),
            ],
            [makeEntry("Payload/Example.app/Link", kind: .symbolicLink)],
        ]
        for table in tables {
            let inspection = validator.validate(entryTable: table)
            XCTAssertFalse(inspection.validation.isValid)
            XCTAssertTrue(inspection.validation.isConsistent)
            XCTAssertFalse(inspection.validation.errors.isEmpty)
        }
    }

    // MARK: - Nested bundles

    func testNestedBundleInsidePrimaryBundleProducesNoFinding() {
        let inspection = validator.validate(entryTable: validPackageEntryTable() + [
            makeEntry("Payload/Example.app/PlugIns", kind: .directory),
            makeEntry("Payload/Example.app/PlugIns/Widget.app", kind: .directory),
            makeEntry("Payload/Example.app/PlugIns/Widget.app/Info.plist"),
        ])
        XCTAssertEqual(inspection.validation.classification, .valid)
        XCTAssertTrue(inspection.validation.findings.isEmpty)
    }

    func testBundleDirectoryOutsidePrimaryBundleProducesWarningOnly() {
        let inspection = validator.validate(entryTable: validPackageEntryTable() + [
            makeEntry("Symbols", kind: .directory),
            makeEntry("Symbols/Example.app", kind: .directory),
        ])
        XCTAssertEqual(inspection.validation.classification, .valid)
        XCTAssertEqual(inspection.validation.warnings.map(\.code), [.inconsistentMetadata])
    }
}
