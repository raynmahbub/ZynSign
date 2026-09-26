import Foundation
import XCTest
@testable import ZynSign

@MainActor
final class EntitlementsStudioModelTests: XCTestCase {
    private func setup(universal: Bool = false) async throws -> (EntitlementsStudioModel, LibraryEntry, IPABundleContentsInspection, SyntheticArchiveReader) {
        let claims = try CodeSigningEntitlements(values: ["aps-environment": .string("development")])
        let blob = try EntitlementsCanonicalSerializer().blob(claims)
        let thin = MachOFixtures.signedThin(MachOFixtures.superBlob([(5, Array(blob.bytes))]))
        let bytes: [UInt8]
        if universal {
            let otherClaims = try CodeSigningEntitlements(values: ["aps-environment": .string("production")])
            let otherBlob = try EntitlementsCanonicalSerializer().blob(otherClaims)
            let other = MachOFixtures.signedThin(MachOFixtures.superBlob([(5, Array(otherBlob.bytes))]), cpu: MachOFixtures.x86_64)
            bytes = MachOFixtures.fat([(MachOFixtures.arm64, 0, thin), (MachOFixtures.x86_64, 0, other)])
        } else { bytes = thin }
        let reader = SyntheticArchiveReader(entryTable: validPackageEntryTable(), contentByPath: ["Payload/Example.app/Example": Data(bytes)])
        let records = InMemoryApplicationRecordStore()
        let artifacts = SyntheticLibraryArtifactStore()
        let library = ApplicationLibrary(records: records, artifacts: artifacts)
        let id = ArtifactIdentifier()
        let content = Data([0])
        artifacts.hold(content, as: id)
        let record = LibraryFixtures.record(executableName: "Example", artifact: LibraryFixtures.reference(to: content, artifactID: id))
        try await records.insert(record)
        let observed = try await library.entry(withID: record.id)
        let entry = try XCTUnwrap(observed)
        let inspection = IPABundleContentsInspection(library: library, readerProvider: SyntheticArchiveReaderProvider.providing(reader), machOParser: ReadOnlyMachOParser())
        let model = EntitlementsStudioModel()
        await model.load(entry: entry, inspection: inspection)
        try await ready(model)
        return (model, entry, inspection, reader)
    }

    private func ready(_ model: EntitlementsStudioModel) async throws {
        // Bounded wait for background parsing/analysis, without blocking MainActor.
        for _ in 0..<300 {
            if model.analysis != nil && !model.isParsingProfile { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Analysis did not settle")
    }
    private func profile(_ environment: String) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [
            "TeamIdentifier": ["TEAM"], "ApplicationIdentifierPrefix": ["PREFIX"],
            "Entitlements": ["aps-environment": environment, "application-identifier": "PREFIX.com.example.synthetic"]
        ], format: .xml, options: 0)
    }
    private func identity(team: String) -> SigningIdentity {
        let metadata = CertificateMetadata(
            subject: .init(commonName: "Synthetic", organizationalUnit: team, rawRepresentation: "Synthetic"),
            issuer: .init(commonName: "Synthetic CA", rawRepresentation: "Synthetic CA"),
            serialNumber: CertificateSerialNumber(hexadecimal: "01")!,
            notValidBefore: Date(timeIntervalSince1970: 0), notValidAfter: Date(timeIntervalSince1970: 4_000_000_000),
            publicKeyInfo: .init(algorithm: .rsa, keySizeInBits: 2048), signatureAlgorithm: .sha256WithRSAEncryption,
            sha256Fingerprint: CertificateFingerprint(hexDigest: String(repeating: "ab", count: 32))!
        )
        return SigningIdentity(certificate: metadata, keyAvailability: .unavailable)
    }

    func testProfileConfigurationAndCertificateChangesInvalidateWithoutReReadingApp() async throws {
        let (model, entry, inspection, reader) = try await setup()
        model.selectProfile(data: try profile("development"), name: "Synthetic.mobileprovision")
        XCTAssertNil(model.profile, "Old profile must not remain selected while parsing")
        try await ready(model)
        XCTAssertEqual(model.analysis?.rows.first?.finding.status, .compatible)
        let originalRows = model.analysis?.rows
        model.emitDEREntitlements = true
        XCTAssertNil(model.analysis, "A stale verdict must never survive configuration changes")
        try await ready(model)
        XCTAssertEqual(model.analysis?.rows, originalRows)
        XCTAssertTrue(model.analysis?.checks.first { $0.id == "encoding" }?.message.contains("DER") == true)
        let wrong = identity(team: "OTHER")
        let right = identity(team: "TEAM")
        model.identities = [wrong, right]
        model.selectedIdentityID = wrong.id
        try await ready(model)
        XCTAssertTrue(model.signingBlocked)
        model.selectedIdentityID = right.id
        try await ready(model)
        XCTAssertFalse(model.signingBlocked)
        model.removeProfile()
        try await ready(model)
        XCTAssertEqual(model.analysis?.rows.first?.finding.status, .unknown)
        await model.load(entry: entry, inspection: inspection)
        XCTAssertEqual(reader.requestedPaths.count, 1, "Selections and navigation use the parsed source cache")
        await model.retry(entry: entry, inspection: inspection)
        try await ready(model)
        XCTAssertEqual(reader.requestedPaths.count, 2)
    }

    func testLatestProfileWinsAndRemovalInvalidatesInFlightWork() async throws {
        let (model, _, _, _) = try await setup()
        model.selectProfile(data: try profile("production"), name: "Old.mobileprovision")
        model.selectProfile(data: try profile("development"), name: "New.mobileprovision")
        try await ready(model)
        XCTAssertEqual(model.profileFileName, "New.mobileprovision")
        XCTAssertEqual(model.analysis?.rows.first?.finding.status, .compatible)
        model.selectProfile(data: try profile("production"), name: "Removed.mobileprovision")
        model.removeProfile()
        try await ready(model)
        XCTAssertNil(model.profileData)
        XCTAssertNil(model.profile)
        XCTAssertEqual(model.analysis?.rows.first?.finding.status, .unknown)
    }

    func testMalformedReplacementClearsPreviousProfileAndKeepsUnknownClaimsVisible() async throws {
        let (model, _, _, _) = try await setup()
        model.selectProfile(data: try profile("development"), name: "Good.mobileprovision")
        try await ready(model)
        model.selectProfile(data: Data([0]), name: "Bad.mobileprovision")
        try await ready(model)
        XCTAssertNil(model.profileData)
        XCTAssertNotNil(model.profileError)
        XCTAssertEqual(model.analysis?.rows.count, 1)
        XCTAssertEqual(model.analysis?.rows.first?.finding.status, .unknown)
    }

    func testDifferingArchitecturesAreSeparateAndAnyConflictBlocksSigning() async throws {
        let (model, _, _, _) = try await setup(universal: true)
        XCTAssertEqual(model.targets.count, 2)
        model.selectProfile(data: try profile("development"), name: "Synthetic.mobileprovision")
        try await ready(model)
        XCTAssertEqual(model.analysis?.rows.first?.finding.status, .compatible)
        XCTAssertTrue(model.signingBlocked, "A conflict in an unselected architecture must still block")
        model.selectedTargetID = 1
        try await ready(model)
        XCTAssertEqual(model.analysis?.rows.first?.finding.status, .blocked)
        XCTAssertEqual(model.analysis?.rows.first?.value, .string("production"))
    }
}
