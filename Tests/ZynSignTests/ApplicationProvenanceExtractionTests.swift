import XCTest
@testable import ZynSign

/// Tests for reading the developer and team a package declares, the
/// sanitising of those declarations, and the cache that keeps them.
final class ApplicationProvenanceExtractionTests: XCTestCase {

    private typealias Fixtures = LibraryOrganizationFixtures

    // MARK: - Extraction

    func testTheTeamComesFromTheEmbeddedProfileAndTheDeveloperFromStoreMetadata() {
        let reader = Fixtures.provenanceReader(
            profile: Fixtures.signedProfileBytes(teamIdentifier: "ABCDE12345", teamName: "Acme Team"),
            storeMetadata: Fixtures.storeMetadata(artistName: "Acme Studios")
        )

        let provenance = ApplicationProvenanceExtraction.extract(
            using: reader,
            maximumProfileBytes: 1_048_576,
            maximumMetadataBytes: 1_048_576,
            profilePayload: { _ in nil }
        )

        XCTAssertEqual(provenance, ApplicationProvenance(developerName: "Acme Studios", teamIdentifier: "ABCDE12345", teamName: "Acme Team"))
        XCTAssertEqual(provenance.displayDeveloper, "Acme Studios")
    }

    func testADecodedPayloadIsPreferredOverScanningTheBytes() {
        let decoded = Fixtures.profilePropertyList(teamIdentifier: "DECODED001", teamName: nil)
        let reader = Fixtures.provenanceReader(
            profile: Fixtures.signedProfileBytes(teamIdentifier: "SCANNED001", teamName: nil),
            storeMetadata: nil
        )

        let provenance = ApplicationProvenanceExtraction.extract(
            using: reader,
            maximumProfileBytes: 1_048_576,
            maximumMetadataBytes: 1_048_576,
            profilePayload: { _ in decoded }
        )

        XCTAssertEqual(provenance.teamIdentifier, "DECODED001")
    }

    func testAPackageDeclaringNothingIsUnknown() {
        let reader = Fixtures.provenanceReader(profile: nil, storeMetadata: nil)

        let provenance = ApplicationProvenanceExtraction.extract(
            using: reader,
            maximumProfileBytes: 1_048_576,
            maximumMetadataBytes: 1_048_576,
            profilePayload: { _ in nil }
        )

        XCTAssertEqual(provenance, .unknown)
        XCTAssertTrue(provenance.isEmpty)
    }

    func testAnOversizedProfileIsNotRead() {
        let reader = Fixtures.provenanceReader(
            profile: Fixtures.signedProfileBytes(teamIdentifier: "ABCDE12345", teamName: nil),
            storeMetadata: nil
        )

        let provenance = ApplicationProvenanceExtraction.extract(
            using: reader,
            maximumProfileBytes: 16,
            maximumMetadataBytes: 16,
            profilePayload: { _ in nil }
        )

        XCTAssertNil(provenance.teamIdentifier)
    }

    func testDeclarationsAreSanitised() {
        let provenance = ApplicationProvenance(
            developerName: "  Acme\nStudios\u{0000} ",
            teamIdentifier: "NOT A TEAM ID!",
            teamName: String(repeating: "x", count: 500)
        )

        XCTAssertEqual(provenance.developerName, "Acme Studios")
        XCTAssertNil(provenance.teamIdentifier, "A team identifier must be a short run of letters and digits.")
        XCTAssertEqual(provenance.teamName?.count, ApplicationProvenance.maximumNameLength)
    }

    // MARK: - Resolution and cache

    func testResolvedProvenanceIsCachedForTheLaunchAndAcrossLaunches() async throws {
        let directory = try LibraryFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("Provenance.json")
        let artifact = ArtifactIdentifier()
        let provider = PerArtifactArchiveReaderProvider(readers: [
            artifact: Fixtures.provenanceReader(
                profile: Fixtures.signedProfileBytes(teamIdentifier: "ABCDE12345", teamName: "Acme"),
                storeMetadata: nil
            ),
        ])
        let extraction = ApplicationProvenanceExtraction(readerProvider: provider, cacheLocation: cache)

        let first = await extraction.resolve([artifact])
        let second = await extraction.resolve([artifact])

        XCTAssertEqual(first[artifact]?.teamIdentifier, "ABCDE12345")
        XCTAssertEqual(second, first)
        XCTAssertEqual(provider.openCount(for: artifact), 1, "A resolved package is not read again.")

        let relaunched = ApplicationProvenanceExtraction(readerProvider: provider, cacheLocation: cache)
        let known = await relaunched.knownProvenance()
        XCTAssertEqual(known[artifact]?.teamName, "Acme")
        XCTAssertEqual(provider.openCount(for: artifact), 1, "The cache is read, not the package.")
    }

    func testAnArchiveThatCannotBeOpenedIsNotCached() async {
        let artifact = ArtifactIdentifier()
        let provider = PerArtifactArchiveReaderProvider()
        let extraction = ApplicationProvenanceExtraction(readerProvider: provider, cacheLocation: nil)

        let first = await extraction.resolve([artifact])
        let second = await extraction.resolve([artifact])

        XCTAssertTrue(first.isEmpty)
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(provider.openCount(for: artifact), 2, "An unopenable archive is tried again.")
    }

    func testForgettingRemovesCachedResults() async {
        let artifact = ArtifactIdentifier()
        let provider = PerArtifactArchiveReaderProvider(readers: [
            artifact: Fixtures.provenanceReader(profile: nil, storeMetadata: Fixtures.storeMetadata(artistName: "Acme")),
        ])
        let extraction = ApplicationProvenanceExtraction(readerProvider: provider, cacheLocation: nil)
        _ = await extraction.resolve([artifact])

        await extraction.forget([artifact])
        let known = await extraction.knownProvenance()

        XCTAssertNil(known[artifact])
    }

    func testADamagedCacheIsIgnoredAndRebuilt() async throws {
        let directory = try LibraryFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("Provenance.json")
        try Data("damaged".utf8).write(to: cache)
        let artifact = ArtifactIdentifier()
        let provider = PerArtifactArchiveReaderProvider(readers: [
            artifact: Fixtures.provenanceReader(profile: nil, storeMetadata: Fixtures.storeMetadata(artistName: "Acme")),
        ])
        let extraction = ApplicationProvenanceExtraction(readerProvider: provider, cacheLocation: cache)

        let resolved = await extraction.resolve([artifact])

        XCTAssertEqual(resolved[artifact]?.developerName, "Acme")
        let relaunched = ApplicationProvenanceExtraction(readerProvider: provider, cacheLocation: cache)
        let known = await relaunched.knownProvenance()
        XCTAssertEqual(known[artifact]?.developerName, "Acme")
    }
}
