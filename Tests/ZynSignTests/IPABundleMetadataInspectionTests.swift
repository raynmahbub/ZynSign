import Foundation
import XCTest
@testable import ZynSign

/// Tests for the bundle metadata inspection use case, against an in-memory
/// archive reader double. No filesystem, container, or binary fixture is
/// involved.
final class IPABundleMetadataInspectionTests: XCTestCase {

    private let bundlePathRaw = "Payload/Example.app"
    private let infoPlistPathRaw = "Payload/Example.app/Info.plist"
    private let validIdentifier = "com.example.synthetic"

    /// A full, valid declared-metadata fixture.
    private var fullMetadataRoot: [String: Any] {
        [
            BundleInformationKeys.bundleIdentifier: validIdentifier,
            BundleInformationKeys.displayName: "Synthetic App",
            BundleInformationKeys.shortVersion: "1.0",
            BundleInformationKeys.buildVersion: "1",
            BundleInformationKeys.executable: "Example",
            BundleInformationKeys.minimumOSVersion: "17.0",
            BundleInformationKeys.deviceFamily: [1, 2],
            BundleInformationKeys.iconName: "AppIcon",
        ]
    }

    // MARK: - Fixture construction

    private func makePlist(_ root: [String: Any]) -> Data {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0) else {
            XCTFail("Could not build a property list fixture")
            return Data()
        }
        return data
    }

    /// An examined artifact that passed structural examination: one bundle,
    /// a valid classification, state `inspected`.
    private func inspectedArtifact() throws -> IPAArtifact {
        let artifact = IPAArtifact(
            id: ArtifactIdentifier(uuid: UUID(uuidString: "6B3FD418-6C5E-4E2A-9B1A-2C3D4E5F6071")!),
            sourceFileName: "Example.ipa"
        )
        let bundlePath = try XCTUnwrap(ArchivePath(rawValue: bundlePathRaw))
        let bundle = try ApplicationBundle(bundlePath: bundlePath)
        return artifact.examined(bundle: bundle, validation: ValidationResult.valid())
    }

    /// The entry table of a structurally valid package, with an optional
    /// executable entry.
    private func defaultEntryTable(executable: String? = "Example", executableKind: ArchiveEntryKind = .regularFile) -> [ArchiveEntry] {
        var table = [
            makeEntry(IPALayout.payloadDirectoryName, kind: .directory),
            makeEntry(bundlePathRaw, kind: .directory),
            makeEntry(infoPlistPathRaw, kind: .regularFile, uncompressedSize: 256, compressedSize: 128),
        ]
        if let executable {
            table.append(makeEntry("\(bundlePathRaw)/\(executable)", kind: executableKind))
        }
        return table
    }

    private func reader(
        entryTable: [ArchiveEntry]? = nil,
        root: [String: Any]? = nil,
        plistContent: Data? = nil,
        failure: SyntheticArchiveReader.Failure? = nil
    ) -> SyntheticArchiveReader {
        var contentByPath: [String: Data] = [:]
        if let root = root {
            contentByPath[infoPlistPathRaw] = makePlist(root)
        } else if let plistContent = plistContent {
            contentByPath[infoPlistPathRaw] = plistContent
        }
        return SyntheticArchiveReader(
            entryTable: entryTable ?? defaultEntryTable(),
            contentByPath: contentByPath,
            failure: failure
        )
    }

    private func inspection(
        over reader: any ArchiveReader,
        limits: ArchiveLimits = .default
    ) -> IPABundleMetadataInspection {
        IPABundleMetadataInspection(
            readerProvider: SyntheticArchiveReaderProvider.providing(reader),
            limits: limits
        )
    }

    private func errorCodes(of artifact: IPAArtifact) -> [ValidationIssueCode] {
        artifact.validation?.errors.map(\.code) ?? []
    }

    // MARK: - Successful examination

    func testInspectedArtifactGainsMetadataAndIdentifiedBundle() throws {
        let reader = reader(root: fullMetadataRoot)
        let examined = inspection(over: reader).inspect(try inspectedArtifact())

        XCTAssertEqual(examined.state, .inspected)
        XCTAssertTrue(examined.permitsLaterStages)
        XCTAssertEqual(examined.validation?.classification, .valid)
        XCTAssertTrue(examined.validation?.findings.isEmpty ?? false)

        let metadata = try XCTUnwrap(examined.metadata)
        XCTAssertEqual(metadata.identity.bundleIdentifier.rawValue, validIdentifier)
        XCTAssertEqual(metadata.identity.displayName, "Synthetic App")
        XCTAssertEqual(metadata.executableName, "Example")
        XCTAssertEqual(metadata.minimumOSVersion, "17.0")
        XCTAssertEqual(metadata.deviceFamily, [.phone, .pad])
        XCTAssertEqual(metadata.iconName, "AppIcon")

        let bundle = try XCTUnwrap(examined.discoveredBundle)
        XCTAssertTrue(bundle.isIdentified)
        XCTAssertEqual(bundle.identity?.bundleIdentifier.rawValue, validIdentifier)
        XCTAssertEqual(bundle.executablePath?.rawValue, "Payload/Example.app/Example")
    }

    func testMetadataWithoutExecutableDeclarationLeavesBundleUnresolved() throws {
        var root = fullMetadataRoot
        root[BundleInformationKeys.executable] = nil
        let reader = reader(root: root)
        let examined = inspection(over: reader).inspect(try inspectedArtifact())

        XCTAssertEqual(examined.state, .inspected)
        XCTAssertNil(try XCTUnwrap(examined.metadata).executableName)
        XCTAssertNil(try XCTUnwrap(examined.discoveredBundle).executablePath)
        XCTAssertTrue(try XCTUnwrap(examined.discoveredBundle).isIdentified)
    }

    func testPlistIsReadExactlyOnce() throws {
        let reader = reader(root: fullMetadataRoot)
        _ = inspection(over: reader).inspect(try inspectedArtifact())
        let infoPath = try XCTUnwrap(ArchivePath(rawValue: infoPlistPathRaw))
        XCTAssertEqual(reader.requestedPaths, [infoPath])
    }

    func testReaderIsClosedExactlyOnce() throws {
        let reader = reader(root: fullMetadataRoot)
        _ = inspection(over: reader).inspect(try inspectedArtifact())
        XCTAssertEqual(reader.closeCount, 1)
    }

    // MARK: - Gate: only structurally valid artifacts are examined

    func testUnexaminedArtifactIsReturnedUnchanged() throws {
        let reader = reader(root: fullMetadataRoot)
        let artifact = IPAArtifact(
            id: ArtifactIdentifier(uuid: UUID(uuidString: "6B3FD418-6C5E-4E2A-9B1A-2C3D4E5F6071")!),
            sourceFileName: "Example.ipa"
        )
        let result = inspection(over: reader).inspect(artifact)
        XCTAssertEqual(result, artifact)
        XCTAssertNil(result.metadata)
        XCTAssertEqual(reader.closeCount, 0)
        XCTAssertTrue(reader.requestedPaths.isEmpty)
    }

    func testStructurallyInvalidArtifactIsReturnedUnchanged() throws {
        let reader = reader(root: fullMetadataRoot)
        let artifact = IPAArtifact(
            id: ArtifactIdentifier(uuid: UUID(uuidString: "6B3FD418-6C5E-4E2A-9B1A-2C3D4E5F6071")!)
        )
        let rejected = artifact.examined(
            bundle: nil,
            validation: ValidationResult.invalid(
                findings: [
                    ValidationFinding(severity: .error, code: .missingApplicationBundle, detail: "synthetic structural failure")
                ]
            )
        )
        let result = inspection(over: reader).inspect(rejected)
        XCTAssertEqual(result, rejected)
        XCTAssertEqual(reader.closeCount, 0)
    }

    // MARK: - Failed metadata

    func testMetadataFailureInvalidatesArtifact() throws {
        var root = fullMetadataRoot
        root[BundleInformationKeys.bundleIdentifier] = nil
        let reader = reader(root: root)
        let examined = inspection(over: reader).inspect(try inspectedArtifact())

        XCTAssertEqual(examined.state, .invalid)
        XCTAssertFalse(examined.permitsLaterStages)
        XCTAssertNil(examined.metadata)
        XCTAssertEqual(errorCodes(of: examined), [.missingRequiredMetadata])
        XCTAssertFalse(try XCTUnwrap(examined.discoveredBundle).isIdentified)
    }

    func testMalformedPlistContentIsRecorded() throws {
        let reader = reader(plistContent: Data("not a property list".utf8))
        let examined = inspection(over: reader).inspect(try inspectedArtifact())

        XCTAssertEqual(examined.state, .invalid)
        XCTAssertEqual(errorCodes(of: examined), [.unreadableInfoPlist])
    }

    func testReaderFindingsAreStampedWithTheInfoPlistLocation() throws {
        let reader = reader(plistContent: Data("not a property list".utf8))
        let examined = inspection(over: reader).inspect(try inspectedArtifact())

        let infoPath = try XCTUnwrap(ArchivePath(rawValue: infoPlistPathRaw))
        XCTAssertEqual(examined.validation?.errors.first?.location, infoPath)
    }

    func testMissingInfoPlistEntryIsRecorded() throws {
        // Defensive: structural examination already requires the entry, but
        // a table that no longer carries it must be reported, not trusted.
        let table = [
            makeEntry(IPALayout.payloadDirectoryName, kind: .directory),
            makeEntry(bundlePathRaw, kind: .directory),
            makeEntry("\(bundlePathRaw)/Example"),
        ]
        let reader = SyntheticArchiveReader(entryTable: table)
        let examined = inspection(over: reader).inspect(try inspectedArtifact())

        XCTAssertEqual(examined.state, .invalid)
        XCTAssertEqual(errorCodes(of: examined), [.missingInfoPlist])
    }

    func testInfoPlistThatIsNotARegularFileIsRecorded() throws {
        let table = [
            makeEntry(IPALayout.payloadDirectoryName, kind: .directory),
            makeEntry(bundlePathRaw, kind: .directory),
            makeEntry(infoPlistPathRaw, kind: .directory),
        ]
        let reader = SyntheticArchiveReader(entryTable: table)
        let examined = inspection(over: reader).inspect(try inspectedArtifact())

        XCTAssertEqual(examined.state, .invalid)
        XCTAssertEqual(errorCodes(of: examined), [.missingInfoPlist])
    }

    func testUnreadablePlistContentIsRecorded() throws {
        let reader = reader(root: fullMetadataRoot, failure: .contentUnreadable)
        let examined = inspection(over: reader).inspect(try inspectedArtifact())

        XCTAssertEqual(examined.state, .invalid)
        XCTAssertEqual(errorCodes(of: examined), [.unreadableInfoPlist])
        XCTAssertEqual(reader.closeCount, 1)
    }

    func testOversizedPlistIsRefusedByPolicy() throws {
        // A policy bound below the fixture size: the reader must refuse the
        // read rather than truncate it, and the use case must record it.
        let limits = ArchiveLimits(
            maximumEntryCount: 100_000,
            maximumEntryNameLength: 4_096,
            maximumPathDepth: 32,
            maximumEntryBytes: 2 * 1_024 * 1_024 * 1_024,
            maximumTotalUncompressedBytes: 16 * 1_024 * 1_024 * 1_024,
            maximumCompressionRatio: 1_000,
            maximumInspectionReadBytes: 128
        )
        let reader = reader(root: fullMetadataRoot)
        let examined = inspection(over: reader, limits: limits).inspect(try inspectedArtifact())

        XCTAssertEqual(examined.state, .invalid)
        XCTAssertEqual(errorCodes(of: examined), [.unreadableInfoPlist])
        XCTAssertNil(examined.metadata)
    }

    // MARK: - Executable resolution

    func testExecutableDeclaredButAbsentIsRecorded() throws {
        var root = fullMetadataRoot
        root[BundleInformationKeys.executable] = "Ghost"
        let reader = reader(entryTable: defaultEntryTable(executable: nil), root: root)
        let examined = inspection(over: reader).inspect(try inspectedArtifact())

        XCTAssertEqual(examined.state, .invalid)
        XCTAssertEqual(errorCodes(of: examined), [.missingExecutable])
        // The declaration itself is accurate metadata and stays recorded;
        // the missing file is reported, and the bundle gains no path.
        XCTAssertEqual(try XCTUnwrap(examined.metadata).executableName, "Ghost")
        XCTAssertNil(try XCTUnwrap(examined.discoveredBundle).executablePath)
        XCTAssertTrue(try XCTUnwrap(examined.discoveredBundle).isIdentified)
    }

    func testExecutableThatIsNotARegularFileIsRecorded() throws {
        let reader = reader(
            entryTable: defaultEntryTable(executable: "Example", executableKind: .symbolicLink),
            root: fullMetadataRoot
        )
        let examined = inspection(over: reader).inspect(try inspectedArtifact())

        XCTAssertEqual(examined.state, .invalid)
        XCTAssertEqual(errorCodes(of: examined), [.missingExecutable])
        XCTAssertNil(try XCTUnwrap(examined.discoveredBundle).executablePath)
    }

    // MARK: - Failure boundaries

    /// A failure type standing in for an arbitrary platform error whose
    /// rendering carries a filesystem location. ZynSign must not copy such
    /// text into a finding.
    private struct ForeignPlistReadError: Error, CustomStringConvertible {
        var description: String { "cannot open /Users/someone/private/Example.ipa" }
    }

    /// A reader that fails at a chosen stage with a foreign error.
    private final class ForeignFailingReader: ArchiveReader {
        enum Stage {
            case entryTable
            case content
        }

        private let stage: Stage
        private let table: [ArchiveEntry]
        private(set) var closeCount = 0

        init(stage: Stage, table: [ArchiveEntry]) {
            self.stage = stage
            self.table = table
        }

        func readEntryTable() throws -> [ArchiveEntry] {
            if stage == .entryTable {
                throw ForeignPlistReadError()
            }
            return table
        }

        func containsEntry(at path: ArchivePath) throws -> Bool {
            table.contains { $0.path == path }
        }

        func entryKind(at path: ArchivePath) throws -> ArchiveEntryKind? {
            table.first { $0.path == path }?.kind
        }

        func readEntryData(at path: ArchivePath, maximumBytes: Int) throws -> Data {
            if stage == .content {
                throw ForeignPlistReadError()
            }
            throw ZynSignError.invalidArtifact(diagnosticDetail: "unreachable in this fixture")
        }

        func close() {
            closeCount += 1
        }
    }

    func testForeignFailureDetailIsNotCopiedIntoFindings() throws {
        let reader = ForeignFailingReader(stage: .content, table: defaultEntryTable())
        let examined = inspection(over: reader).inspect(try inspectedArtifact())

        XCTAssertEqual(errorCodes(of: examined), [.unreadableInfoPlist])
        let detail = try XCTUnwrap(examined.validation?.errors.first?.detail)
        XCTAssertFalse(detail.contains("/Users/someone/private"))
        XCTAssertTrue(detail.contains("ForeignPlistReadError"))
        XCTAssertEqual(reader.closeCount, 1)
    }

    func testProviderFailureIsRecordedAsUnreadableArchive() throws {
        let inspection = IPABundleMetadataInspection(
            readerProvider: SyntheticArchiveReaderProvider.failing(
                with: ZynSignError.artifactNotAvailable(diagnosticDetail: "no archive held")
            )
        )
        let examined = inspection.inspect(try inspectedArtifact())

        XCTAssertEqual(examined.state, .invalid)
        XCTAssertEqual(errorCodes(of: examined), [.unreadableArchive])
        XCTAssertNil(examined.metadata)
    }

    func testUnenumerableContainerIsRecorded() throws {
        let reader = reader(root: fullMetadataRoot, failure: .entryTableUnreadable)
        let examined = inspection(over: reader).inspect(try inspectedArtifact())

        XCTAssertEqual(examined.state, .invalid)
        XCTAssertEqual(errorCodes(of: examined), [.unreadableArchive])
        XCTAssertEqual(reader.closeCount, 1)
    }
}
