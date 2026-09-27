import XCTest
@testable import ZynSign

/// Repository metadata, update planning, address policy, and artifact
/// validation. These tests do not use the network.
final class DownloadCatalogTests: XCTestCase {

    func testURLPolicyRefusesInsecureEmbeddedAndNonHTTPSAddresses() {
        XCTAssertEqual(DownloadURLPolicy.classifyUserLink("").error, .empty)
        XCTAssertEqual(DownloadURLPolicy.classifyUserLink("http://example.com/a.ipa").error, .insecureTransport)
        XCTAssertEqual(DownloadURLPolicy.classifyUserLink("file:///tmp/a.ipa").error, .unsupportedScheme)
        XCTAssertEqual(DownloadURLPolicy.classifyUserLink("https://user:pw@example.com/a.ipa").error, .embeddedCredentials)
        guard case let .success(.artifact(url)) = DownloadURLPolicy.classifyUserLink("example.com/a.ipa") else {
            return XCTFail("A schemeless address should be read as https")
        }
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "example.com")
    }

    func testInstallLinkExtractsOnlyAnHTTPSManifest() {
        let link = URL(string: "itms-services://?action=download-manifest&url=https://example.com/manifest.plist")!
        XCTAssertEqual(DownloadURLPolicy.manifestURL(fromInstallLink: link)?.absoluteString, "https://example.com/manifest.plist")
        let insecure = URL(string: "itms-services://?action=download-manifest&url=http://example.com/manifest.plist")!
        XCTAssertNil(DownloadURLPolicy.manifestURL(fromInstallLink: insecure))
    }

    func testInstallManifestAcceptsOnlyASoftwarePackageHTTPSAsset() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>items</key><array><dict>
        <key>assets</key><array>
        <dict><key>kind</key><string>display-image</string><key>url</key><string>https://example.com/icon.png</string></dict>
        <dict><key>kind</key><string>software-package</string><key>url</key><string>https://example.com/Demo.ipa</string></dict>
        </array></dict></array></dict></plist>
        """.data(using: .utf8)!
        XCTAssertEqual(InstallManifestParser.ipaURL(from: plist)?.absoluteString, "https://example.com/Demo.ipa")

        let imageOnly = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>items</key><array><dict>
        <key>assets</key><array>
        <dict><key>kind</key><string>display-image</string><key>url</key><string>https://example.com/icon.png</string></dict>
        </array></dict></array></dict></plist>
        """.data(using: .utf8)!
        XCTAssertNil(InstallManifestParser.ipaURL(from: imageOnly))
        XCTAssertNil(InstallManifestParser.ipaURL(from: Data("not a plist".utf8)))
    }

    func testCatalogRejectsADocumentThatIsNotAFeed() {
        let rejected = RepositoryCatalogParser.examine(
            data: Data("hello".utf8),
            sourceURL: URL(string: "https://example.com/apps.json")!,
            fetchedAt: Date(timeIntervalSince1970: 1)
        )
        XCTAssertFalse(rejected.isAccepted)
        XCTAssertNil(rejected.catalog)
        XCTAssertTrue(rejected.findings.first?.contains("JSON") == true)
    }

    func testCatalogSkipsAppsWhoseDownloadAddressIsNotHTTPS() throws {
        let json = """
        {"name":"Example","identifier":"example","apps":[
          {"name":"Good","bundleIdentifier":"com.example.good","version":"1.0","downloadURL":"https://cdn.example.com/good.ipa","versionDate":"2026-01-02","localizedDescription":"Hello"},
          {"name":"Bad","bundleIdentifier":"com.example.bad","version":"9.0","downloadURL":"http://cdn.example.com/bad.ipa"},
          {"name":"File","bundleIdentifier":"com.example.file","version":"1.0","downloadURL":"file:///tmp/a.ipa"}
        ]}
        """.data(using: .utf8)!
        let examination = RepositoryCatalogParser.examine(
            data: json,
            sourceURL: URL(string: "https://example.com/apps.json")!,
            fetchedAt: Date(timeIntervalSince1970: 5)
        )
        let catalog = try XCTUnwrap(examination.catalog)
        XCTAssertEqual(catalog.apps.map(\.bundleIdentifier), ["com.example.good"])
        XCTAssertEqual(catalog.skippedAppCount, 2)
        XCTAssertEqual(catalog.apps[0].latest.downloadURL, "https://cdn.example.com/good.ipa")
    }

    func testCatalogPicksTheNewerVersionRatherThanArrayOrder() throws {
        let json = """
        {"name":"Example","apps":[{"name":"Demo","bundleIdentifier":"com.example.demo","versions":[
          {"version":"1.9","date":"2025-01-01","downloadURL":"https://cdn.example.com/1.9.ipa","localizedDescription":"Old"},
          {"version":"1.10","date":"2026-02-02","downloadURL":"https://cdn.example.com/1.10.ipa","localizedDescription":"New","sha256":"\(String(repeating: "ab", count: 32))"}
        ]}]}
        """.data(using: .utf8)!
        let catalog = try XCTUnwrap(RepositoryCatalogParser.examine(
            data: json,
            sourceURL: URL(string: "https://example.com/apps.json")!,
            fetchedAt: Date(timeIntervalSince1970: 5)
        ).catalog)
        XCTAssertEqual(catalog.apps[0].latest.version, "1.10")
        XCTAssertEqual(catalog.apps[0].latest.notes, "New")
        XCTAssertEqual(catalog.apps[0].versions.first?.version, "1.10")
    }

    func testMalformedDeclaredChecksumDropsThatVersion() throws {
        let json = """
        {"name":"Example","apps":[{"name":"Demo","bundleIdentifier":"com.example.demo","version":"1.0","downloadURL":"https://cdn.example.com/a.ipa","sha256":"not-a-hash"}]}
        """.data(using: .utf8)!
        let catalog = try XCTUnwrap(RepositoryCatalogParser.examine(
            data: json,
            sourceURL: URL(string: "https://example.com/apps.json")!,
            fetchedAt: Date(timeIntervalSince1970: 5)
        ).catalog)
        XCTAssertTrue(catalog.apps.isEmpty)
        XCTAssertEqual(catalog.skippedAppCount, 1)
    }

    func testUpdatePlannerSurfacesOnlyNewerConfiguredVersions() {
        let older = version("1.2", url: "https://cdn.example.com/1.2.ipa")
        let newer = version("1.3", url: "https://cdn.example.com/1.3.ipa", notes: "Fixes")
        let catalog = RepositoryCatalog(
            name: "Example",
            identifier: "example",
            sourceURL: "https://example.com/apps.json",
            apps: [RepositoryApp(
                name: "Demo",
                bundleIdentifier: "com.example.demo",
                subtitle: nil,
                developerName: "Ada",
                summary: nil,
                iconURL: nil,
                versions: [newer, older],
                latest: newer,
                versionComparisonIsDefinite: true
            )],
            fetchedAt: Date(timeIntervalSince1970: 5),
            skippedAppCount: 0
        )
        let installed = InstalledApplication(bundleIdentifier: "com.example.demo", name: "Demo", version: "1.2", build: "1", recordID: "r")
        let updates = UpdatePlanner.candidates(installed: [installed], catalogs: [catalog], ignored: [])
        XCTAssertEqual(updates.map(\.latestVersion), ["1.3"])
        XCTAssertEqual(updates.first?.installedVersion, "1.2")
        XCTAssertEqual(updates.first?.releaseNotes, "Fixes")
        XCTAssertEqual(updates.first?.comparisonText, "1.2 → 1.3")

        let same = UpdatePlanner.candidates(
            installed: [InstalledApplication(bundleIdentifier: "com.example.demo", name: "Demo", version: "1.3", build: "1", recordID: "r")],
            catalogs: [catalog],
            ignored: []
        )
        XCTAssertTrue(same.isEmpty)

        let ignored = UpdatePlanner.candidates(
            installed: [installed],
            catalogs: [catalog],
            ignored: [IgnoredAppVersion(bundleIdentifier: "com.example.demo", version: "1.3")]
        )
        XCTAssertTrue(ignored.isEmpty)

        let unknown = UpdatePlanner.candidates(
            installed: [InstalledApplication(bundleIdentifier: "com.example.demo", name: "Demo", version: nil, build: nil, recordID: nil)],
            catalogs: [catalog],
            ignored: []
        )
        XCTAssertTrue(unknown.isEmpty, "A missing installed version is not guessed newer or older")

        XCTAssertTrue(UpdatePlanner.candidates(installed: [installed], catalogs: [], ignored: []).isEmpty)
    }

    func testTwoSourcesAreNotCollapsed() {
        let first = catalog(name: "One", url: "https://one.example/apps.json", download: "https://one.example/a.ipa")
        let second = catalog(name: "Two", url: "https://two.example/apps.json", download: "https://two.example/a.ipa")
        let installed = InstalledApplication(bundleIdentifier: "com.example.demo", name: "Demo", version: "1.0", build: nil, recordID: nil)
        let updates = UpdatePlanner.candidates(installed: [installed], catalogs: [first, second], ignored: [])
        XCTAssertEqual(Set(updates.map(\.sourceName)), ["One", "Two"])
    }

    func testValidatorAcceptsASyntheticPackageAndRejectsANonArchive() async throws {
        let validator = IPADownloadValidator()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("IPAValidator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let package = directory.appendingPathComponent("good.ipa")
        try Data(ZipFixtureBuilder.archive(ZipFixtureBuilder.validPackage())).write(to: package)
        let accepted = await validator.validate(fileAt: package, expectedSHA256: nil)
        XCTAssertTrue(accepted.archiveReadable)
        XCTAssertTrue(accepted.ipaStructureAccepted)
        XCTAssertTrue(accepted.extractionReady)
        XCTAssertTrue(accepted.metadataAvailable)
        XCTAssertTrue(accepted.isImportReady)
        XCTAssertNil(accepted.checksumMatched)

        let junk = directory.appendingPathComponent("junk.ipa")
        try Data(ZipFixtureBuilder.notAnArchive()).write(to: junk)
        let rejected = await validator.validate(fileAt: junk, expectedSHA256: nil)
        XCTAssertFalse(rejected.isImportReady)
        XCTAssertFalse(rejected.archiveReadable)
        XCTAssertTrue(rejected.summary.contains("isolated"))

        let mismatch = await validator.validate(fileAt: package, expectedSHA256: String(repeating: "ab", count: 32))
        XCTAssertEqual(mismatch.checksumMatched, false)
        XCTAssertFalse(mismatch.isImportReady)
    }

    @MainActor
    func testRenderingDoesNotInventAPercentage() {
        let job = DownloadCenter.Job(
            id: DownloadJobIdentifier(),
            request: DownloadRequest(
                displayName: "Demo",
                bundleIdentifier: nil,
                version: "1.0",
                build: nil,
                sourceName: "Example",
                sourceKind: DownloadRequest.kindDirectLink,
                sourceIdentifier: nil,
                remoteURL: URL(string: "https://example.com/a.ipa")!,
                iconURL: nil,
                expectedSHA256: nil,
                expectedByteCount: nil,
                releaseNotes: nil,
                releaseDate: nil,
                versionHistory: []
            ),
            priority: .normal,
            state: .downloading,
            progress: DownloadTransferProgressFacts(receivedBytes: 10, expectedBytes: nil, bytesPerSecond: nil, estimatedRemainingSeconds: nil),
            enqueuedAt: Date(timeIntervalSince1970: 1),
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: nil,
            attemptCount: 1,
            resumeFact: .notCaptured,
            validation: nil,
            handoff: nil,
            importJobIDs: [],
            replacesJobIDs: [],
            duplicateChoice: nil,
            controlRequest: nil,
            log: []
        )
        XCTAssertFalse(DownloadCenterRendering.progressValue(for: job).contains("%"))
        XCTAssertTrue(DownloadCenterRendering.progressValue(for: job).contains("not yet known"))
        XCTAssertEqual(DownloadCenterRendering.milestoneAnnouncement(previous: nil, current: job) != nil, true)
        XCTAssertNil(DownloadCenterRendering.milestoneAnnouncement(previous: DownloadCenterRendering.milestoneToken(for: job), current: job))
    }

    private func version(_ version: String, url: String, notes: String? = nil) -> RepositoryAppVersion {
        RepositoryAppVersion(version: version, build: nil, date: nil, notes: notes, downloadURL: url, size: nil, sha256: nil)
    }

    private func catalog(name: String, url: String, download: String) -> RepositoryCatalog {
        let latest = version("1.2", url: download, notes: "Notes")
        return RepositoryCatalog(
            name: name,
            identifier: name,
            sourceURL: url,
            apps: [RepositoryApp(
                name: "Demo",
                bundleIdentifier: "com.example.demo",
                subtitle: nil,
                developerName: nil,
                summary: nil,
                iconURL: nil,
                versions: [latest],
                latest: latest,
                versionComparisonIsDefinite: true
            )],
            fetchedAt: Date(timeIntervalSince1970: 1),
            skippedAppCount: 0
        )
    }
}

private extension Result where Failure == DownloadURLRejection {
    var error: DownloadURLRejection? {
        if case let .failure(error) = self { return error }
        return nil
    }
}
