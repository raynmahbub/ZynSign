import XCTest
@testable import ZynSign

/// Tests for the application icon extractor over synthetic containers:
/// candidate selection, bundle-root discovery (with and without recorded
/// directory entries), the read bound, cache behaviour, and the honest
/// absence that presentation falls back from.
final class AppIconExtractionTests: XCTestCase {

    // MARK: - Bundle-root discovery

    func testTheApplicationBundleRootIsDiscoveredFromADirectoryEntry() throws {
        let root = try XCTUnwrap(AppIconExtraction.applicationBundleRoot(in: [
            makeEntry("Payload", kind: .directory),
            makeEntry("Payload/Example.app", kind: .directory),
            makeEntry("Payload/Example.app/Info.plist"),
        ]))
        XCTAssertEqual(root.rawValue, "Payload/Example.app")
    }

    func testTheApplicationBundleRootIsDiscoveredFromInfoPlistWhenNoDirectoryEntryExists() throws {
        let root = try XCTUnwrap(AppIconExtraction.applicationBundleRoot(in: [
            makeEntry("Payload/Example.app/Info.plist"),
            makeEntry("Payload/Example.app/Example"),
        ]))
        XCTAssertEqual(root.rawValue, "Payload/Example.app")
    }

    func testAContainerWithoutAnApplicationBundleHasNoRoot() {
        XCTAssertNil(AppIconExtraction.applicationBundleRoot(in: [
            makeEntry("Example.app/Info.plist"),
            makeEntry("README"),
        ]))
    }

    // MARK: - Candidate selection

    func testThePreferredHomeScreenIconIsChosen() throws {
        let icon = Data("<icon>".utf8)
        let reader = SyntheticArchiveReader(
            entryTable: validPackageEntryTable() + [
                makeEntry("Payload/Example.app/AppIcon29x29@2x.png", uncompressedSize: icon.count),
                makeEntry("Payload/Example.app/AppIcon60x60@2x.png", uncompressedSize: icon.count),
            ],
            contentByPath: [
                "Payload/Example.app/AppIcon60x60@2x.png": icon,
                "Payload/Example.app/AppIcon29x29@2x.png": icon,
            ]
        )

        let extracted = try XCTUnwrap(AppIconExtraction.extractIcon(using: reader, maximumBytes: 512 * 1024))

        XCTAssertEqual(extracted, icon)
        XCTAssertEqual(reader.requestedPaths, [makePath("Payload/Example.app/AppIcon60x60@2x.png")])
    }

    func testANamedAppIconFallbackIsChosenWhenNoPreferredNameExists() throws {
        let icon = Data("<icon>".utf8)
        let reader = SyntheticArchiveReader(
            entryTable: validPackageEntryTable() + [
                makeEntry("Payload/Example.app/CustomAppIconFile.png", uncompressedSize: icon.count),
            ],
            contentByPath: [
                "Payload/Example.app/CustomAppIconFile.png": icon,
            ]
        )

        let extracted = try XCTUnwrap(AppIconExtraction.extractIcon(using: reader, maximumBytes: 512 * 1024))

        XCTAssertEqual(extracted, icon)
    }

    func testEntriesDeeperThanTheBundleRootAreNeverConsidered() throws {
        let reader = SyntheticArchiveReader(
            entryTable: validPackageEntryTable() + [
                makeEntry("Payload/Example.app/Assets.xcassets/AppIcon.appiconset/AppIcon60x60@2x.png"),
            ]
        )

        XCTAssertNil(AppIconExtraction.extractIcon(using: reader, maximumBytes: 512 * 1024))
    }

    func testAContainerWithNoIconProducesNoIcon() {
        let reader = SyntheticArchiveReader(entryTable: validPackageEntryTable())

        XCTAssertNil(AppIconExtraction.extractIcon(using: reader, maximumBytes: 512 * 1024))
    }

    func testAnOversizedIconIsRefusedAndTheNextCandidateIsTried() throws {
        let small = Data("\("<small>")".utf8)
        let oversized = Data(count: 600 * 1024)
        let reader = SyntheticArchiveReader(
            entryTable: validPackageEntryTable() + [
                makeEntry("Payload/Example.app/AppIcon60x60@2x.png", uncompressedSize: oversized.count),
                makeEntry("Payload/Example.app/Icon.png", uncompressedSize: small.count),
            ],
            contentByPath: [
                "Payload/Example.app/AppIcon60x60@2x.png": oversized,
                "Payload/Example.app/Icon.png": small,
            ]
        )

        let extracted = try XCTUnwrap(AppIconExtraction.extractIcon(using: reader, maximumBytes: 512 * 1024))

        XCTAssertEqual(extracted, small)
    }

    func testAnUnreadableEntryTableProducesNoIcon() {
        let reader = SyntheticArchiveReader(
            entryTable: validPackageEntryTable(),
            failure: .entryTableUnreadable
        )

        XCTAssertNil(AppIconExtraction.extractIcon(using: reader, maximumBytes: 512 * 1024))
    }

    // MARK: - Caching

    func testAnExtractedIconIsCachedAndReusedWithoutReopeningTheArchive() async throws {
        let workDirectory = try LibraryFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let icon = Data("<icon>".utf8)
        let artifact = ArtifactIdentifier()
        let reader = SyntheticArchiveReader(
            entryTable: validPackageEntryTable() + [
                makeEntry("Payload/Example.app/AppIcon60x60@2x.png", uncompressedSize: icon.count),
            ],
            contentByPath: [
                "Payload/Example.app/AppIcon60x60@2x.png": icon,
            ]
        )
        let provider = CountingReaderProvider(reader: reader)
        let extraction = AppIconExtraction(
            readerProvider: provider,
            cacheDirectory: workDirectory
        )

        let first = await extraction.iconData(for: artifact)
        let second = await extraction.iconData(for: artifact)

        XCTAssertEqual(first, icon)
        XCTAssertEqual(second, icon)
        XCTAssertEqual(provider.count, 1, "The second read must be served from cache.")
        XCTAssertTrue(reader.closeCount >= 1, "The reader is closed on every outcome.")
    }

    func testAMissingArtifactProducesNoIconWithoutFailing() async throws {
        let workDirectory = try LibraryFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let extraction = AppIconExtraction(
            readerProvider: SyntheticArchiveReaderProvider.failing(
                ZynSignError.artifactStorageFailure(
                    diagnosticDetail: "no such artifact"
                )
            ),
            cacheDirectory: workDirectory
        )

        let data = await extraction.iconData(for: ArtifactIdentifier())

        XCTAssertNil(data)
    }
}

// MARK: - Doubles

/// A provider that counts how many readers it handed out, so the cache can
/// be observed doing its job.
private final class CountingReaderProvider: ArtifactArchiveReaderProvider {
    let reader: SyntheticArchiveReader
    private(set) var count: Int

    init(reader: SyntheticArchiveReader) {
        self.reader = reader
        self.count = 0
    }

    func archiveReader(for artifact: ArtifactIdentifier) throws -> any ArchiveReader {
        count += 1
        return reader
    }
}
