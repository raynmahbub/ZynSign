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
    /// A signature that carries only the DER slot is decoded rather than
    /// reported as unknown, and the note names the slot it read.
    func testDEROnlyClaimsAreDecoded() throws {
        let claims = try CodeSigningEntitlements(values: [
            "get-task-allow": .boolean(true),
            "aps-environment": .string("development"),
        ])
        let payload = try DEREntitlementsSerializer().serialize(claims)
        let der = MachOFixtures.genericBlob(0xFADE7172, payload: Array(payload))
        let result = try inspect(reader(MachOFixtures.signedThin(MachOFixtures.superBlob([(7, der)]))))
        XCTAssertEqual(result.first?.entitlements, claims)
        XCTAssertTrue(result.first?.note.contains("DER") == true)
        XCTAssertFalse(result.first?.note.contains("not implemented") == true)
    }

    /// An empty DER set is an empty claim set — not a missing one.
    func testAnEmptyDERSetIsDecodedAsEmpty() throws {
        let empty = try CodeSigningEntitlements(values: [:])
        let payload = try DEREntitlementsSerializer().serialize(empty)
        let der = MachOFixtures.genericBlob(0xFADE7172, payload: Array(payload))
        let result = try inspect(reader(MachOFixtures.signedThin(MachOFixtures.superBlob([(7, der)]))))
        XCTAssertEqual(result.first?.entitlements, empty)
    }

    /// A DER slot that cannot be decoded is malformed — never silently empty and
    /// never a partial set.
    func testAMalformedDERBlobIsNotEmptyClaims() throws {
        let der = MachOFixtures.genericBlob(0xFADE7172, payload: [0x31, 0x05, 0x30, 0x03])
        let result = try inspect(reader(MachOFixtures.signedThin(MachOFixtures.superBlob([(7, der)]))))
        XCTAssertNil(result.first?.entitlements)
        XCTAssertTrue(result.first?.note.contains("DER (slot 7)") == true)
        XCTAssertTrue(result.first?.note.contains("could not be decoded") == true)
    }

    /// Both slots, encoding the same claims, agree — and the XML slot is the one
    /// reported.
    func testTwoAgreeingSlotsReportNoDisagreement() throws {
        let claims = try CodeSigningEntitlements(values: ["get-task-allow": .boolean(true)])
        let xml = try EntitlementsCanonicalSerializer().blob(claims)
        let der = try DEREntitlementsSerializer().blob(claims)
        let result = try inspect(reader(MachOFixtures.signedThin(
            MachOFixtures.superBlob([(5, Array(xml.bytes)), (7, Array(der.bytes))])
        )))
        XCTAssertEqual(result.first?.entitlements, claims)
        XCTAssertTrue(result.first?.note.contains("XML (slot 5)") == true)
        XCTAssertFalse(result.first?.note.contains("different claim sets") == true)
    }

    /// Both slots, encoding different claims, is a fact the screen states: the
    /// XML claims are shown and the difference is named.
    func testTwoDisagreeingSlotsAreReported() throws {
        let xml = try EntitlementsCanonicalSerializer().blob(
            try CodeSigningEntitlements(values: ["get-task-allow": .boolean(false)])
        )
        let der = try DEREntitlementsSerializer().blob(
            try CodeSigningEntitlements(values: ["get-task-allow": .boolean(true)])
        )
        let result = try inspect(reader(MachOFixtures.signedThin(
            MachOFixtures.superBlob([(5, Array(xml.bytes)), (7, Array(der.bytes))])
        )))
        XCTAssertEqual(result.first?.entitlements?["get-task-allow"], .boolean(false))
        XCTAssertTrue(result.first?.note.contains("different claim sets") == true)
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
