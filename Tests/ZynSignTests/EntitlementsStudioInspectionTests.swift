import Foundation
import XCTest
@testable import ZynSign

final class EntitlementsStudioInspectionTests: XCTestCase {
    private func reader(_ bytes: [UInt8]) -> SyntheticArchiveReader {
        SyntheticArchiveReader(entryTable: validPackageEntryTable(), contentByPath: ["Payload/Example.app/Example": Data(bytes)])
    }
    private func inspect(_ reader: SyntheticArchiveReader) throws -> [EntitlementStudioTarget] {
        try EntitlementsStudioInspection.inspect(reader: reader, executableName: "Example", parser: ReadOnlyMachOParser())
    }
    func testEmbeddedClaimsAreReadFromExecutableNotProfile() throws {
        let claims = try CodeSigningEntitlements(values: ["aps-environment": .string("development"), "future.key": .integer(3)])
        let blob = try EntitlementsCanonicalSerializer().blob(claims)
        let source = reader(MachOFixtures.signedThin(MachOFixtures.superBlob([(5, Array(blob.bytes))])))
        XCTAssertEqual(try inspect(source).first?.entitlements, claims)
        XCTAssertEqual(source.requestedPaths, [makePath("Payload/Example.app/Example")])
    }
    func testUnsignedAndMalformedAreNotEmptyClaims() throws {
        XCTAssertNil(try inspect(reader(MachOFixtures.thin())).first?.entitlements)
        let malformed = MachOFixtures.genericBlob(0xFADE7171, payload: [1, 2, 3])
        let result = try inspect(reader(MachOFixtures.signedThin(MachOFixtures.superBlob([(5, malformed)]))))
        XCTAssertNil(result.first?.entitlements)
        XCTAssertTrue(result.first?.note.contains("could not be decoded") == true)
    }
    func testDEROnlyIsExplicitlyUnsupported() throws {
        let der = MachOFixtures.genericBlob(0xFADE7172, payload: [0x31, 0])
        let result = try inspect(reader(MachOFixtures.signedThin(MachOFixtures.superBlob([(7, der)]))))
        XCTAssertNil(result.first?.entitlements)
        XCTAssertTrue(result.first?.note.contains("DER-only") == true)
    }
    func testSymlinksDuplicatesAndUnsafeExecutableNamesAreRefusedBeforeReading() throws {
        let path = "Payload/Example.app/Example"
        for entries in [[makeEntry(path, kind: .symbolicLink)], [makeEntry(path), makeEntry(path)]] {
            let source = SyntheticArchiveReader(entryTable: validPackageEntryTable().filter { $0.path?.rawValue != path } + entries)
            XCTAssertThrowsError(try inspect(source))
            XCTAssertTrue(source.requestedPaths.isEmpty)
        }
        let source = reader(MachOFixtures.thin())
        XCTAssertThrowsError(try EntitlementsStudioInspection.inspect(reader: source, executableName: "../Example", parser: ReadOnlyMachOParser()))
        XCTAssertTrue(source.requestedPaths.isEmpty)
    }
    func testProfileParsingRejectsMalformedAndDirectClaimDictionaries() throws {
        XCTAssertThrowsError(try EntitlementsStudioInspection.parseProfile(Data([1, 2, 3])))
        let direct = try PropertyListSerialization.data(fromPropertyList: ["aps-environment": "development"], format: .xml, options: 0)
        XCTAssertThrowsError(try EntitlementsStudioInspection.parseProfile(direct))
        let profile = try PropertyListSerialization.data(fromPropertyList: ["TeamIdentifier": ["TEAM"], "Entitlements": ["aps-environment": "development"]], format: .xml, options: 0)
        XCTAssertEqual(try EntitlementsStudioInspection.parseProfile(profile).entitlements?["aps-environment"], .string("development"))
    }
    func testUseCaseClosesReaderOnSuccessAndFailure() async throws {
        let records = InMemoryApplicationRecordStore()
        let artifacts = SyntheticLibraryArtifactStore()
        let library = ApplicationLibrary(records: records, artifacts: artifacts)
        let content = Data([0])
        let id = ArtifactIdentifier()
        artifacts.hold(content, as: id)
        let record = LibraryFixtures.record(executableName: "Example", artifact: LibraryFixtures.reference(to: content, artifactID: id))
        try await records.insert(record)
        for bytes in [MachOFixtures.thin(), [UInt8(0)]] {
            let source = reader(bytes)
            let useCase = IPABundleContentsInspection(library: library, readerProvider: SyntheticArchiveReaderProvider.providing(source), machOParser: ReadOnlyMachOParser())
            _ = try? await useCase.inspectEntitlements(recordWithID: record.id)
            XCTAssertEqual(source.closeCount, 1)
        }
    }
}
