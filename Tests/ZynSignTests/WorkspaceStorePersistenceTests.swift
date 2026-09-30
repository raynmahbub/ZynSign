import XCTest
@testable import ZynSign

/// Round-trip tests for the workspace's file-backed stores, each in its own
/// temporary directory: write, reopen through a fresh instance, read back.
final class WorkspaceStorePersistenceTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZynSignTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: - Tweak library

    func testTweakLibraryRoundTripsRecordsAndPayloads() throws {
        let library = FileTweakLibrary(directory: directory.appendingPathComponent("Tweaks"))
        let descriptor = TweakDescriptor(
            name: "Loader",
            fileName: "Loader.dylib",
            kind: .dynamicLibrary,
            byteSize: 3,
            sha256Hex: String(repeating: "a", count: 64)
        )
        try library.upsert(descriptor)
        try library.store(Data([1, 2, 3]), id: descriptor.id)

        let reopened = FileTweakLibrary(directory: directory.appendingPathComponent("Tweaks"))
        let records = try reopened.all()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.name, "Loader")
        XCTAssertEqual(try reopened.payload(for: descriptor.id), Data([1, 2, 3]))

        try reopened.remove(id: descriptor.id)
        XCTAssertTrue(try FileTweakLibrary(directory: directory.appendingPathComponent("Tweaks")).all().isEmpty)
    }

    func testTweakLibraryFingerprintLookup() throws {
        let library = FileTweakLibrary(directory: directory.appendingPathComponent("Tweaks"))
        let descriptor = TweakDescriptor(
            name: "One", fileName: "One.dylib", kind: .dynamicLibrary,
            byteSize: 1, sha256Hex: String(repeating: "b", count: 64)
        )
        try library.upsert(descriptor)
        XCTAssertEqual(try library.findByFingerprint(sha256Hex: String(repeating: "b", count: 64)).count, 1)
        XCTAssertTrue(try library.findByFingerprint(sha256Hex: String(repeating: "c", count: 64)).isEmpty)
    }

    // MARK: - App protection

    func testAppProtectionRoundTrips() throws {
        let location = directory.appendingPathComponent("AppProtection.json")
        let store = FileAppProtectionStore(location: location)
        try store.set(AppProtectionPolicy(requiresUnlock: true, concealed: true), recordID: "record-1")

        let reopened = FileAppProtectionStore(location: location)
        let policies = try reopened.all()
        XCTAssertEqual(policies.count, 1)
        XCTAssertEqual(policies["record-1"]?.concealed, true)
        XCTAssertEqual(policies["record-1"]?.requiresUnlock, true)

        try reopened.remove(recordID: "record-1")
        XCTAssertTrue(try FileAppProtectionStore(location: location).all().isEmpty)
    }

    // MARK: - Release feeds

    func testReleaseFeedCatalogRoundTrips() throws {
        let location = directory.appendingPathComponent("ReleaseFeeds.json")
        let catalog = FileReleaseFeedCatalog(location: location)
        let reference = ReleaseFeedReference(owner: "acme", repository: "launcher", trackedBundleIdentifier: "com.acme.launcher")
        try catalog.add(reference)
        // Adding the same repository twice must not duplicate it.
        try catalog.add(ReleaseFeedReference(owner: "acme", repository: "launcher"))

        let reopened = FileReleaseFeedCatalog(location: location)
        let feeds = try reopened.all()
        XCTAssertEqual(feeds.count, 1)
        XCTAssertEqual(feeds.first?.trackedBundleIdentifier, "com.acme.launcher")

        try reopened.replace(ReleaseFeedReference(owner: "acme", repository: "launcher", trackedBundleIdentifier: nil))
        XCTAssertNil(try FileReleaseFeedCatalog(location: location).all().first?.trackedBundleIdentifier)

        try reopened.remove(reference)
        XCTAssertTrue(try FileReleaseFeedCatalog(location: location).all().isEmpty)
    }

    func testReleaseFeedCatalogToleratesDocumentsWithoutTracking() throws {
        let location = directory.appendingPathComponent("ReleaseFeeds.json")
        let legacy = """
        {"schemaVersion":1,"feeds":[{"owner":"acme","repository":"launcher"}]}
        """
        try Data(legacy.utf8).write(to: location)
        let catalog = FileReleaseFeedCatalog(location: location)
        let feeds = try catalog.all()
        XCTAssertEqual(feeds.count, 1)
        XCTAssertNil(feeds.first?.trackedBundleIdentifier)
    }

    // MARK: - Revocation reports

    func testRevocationReportsRoundTrip() throws {
        let location = directory.appendingPathComponent("RevocationReports.json")
        let store = FileRevocationReportStore(location: location)
        let outcome = EndpointProbeOutcome(
            endpoint: RevocationEndpoint(channel: .ocsp, url: "http://ocsp.example.com/"),
            reachable: true,
            statusCode: 200,
            latencyMs: 42
        )
        try store.store(RevocationExposureReport(outcomes: [outcome], checkedAt: Date(timeIntervalSince1970: 1_000_000)), fingerprint: "aa")

        let reopened = FileRevocationReportStore(location: location)
        let report = try reopened.report(forFingerprint: "aa")
        XCTAssertEqual(report?.verdict, .exposed)
        XCTAssertEqual(report?.outcomes.first?.latencyMs, 42)
        XCTAssertEqual(report?.checkedAt.timeIntervalSince1970 ?? 0, 1_000_000, accuracy: 1)

        try reopened.remove(fingerprint: "aa")
        XCTAssertNil(try FileRevocationReportStore(location: location).report(forFingerprint: "aa"))
    }
}
