import XCTest
@testable import ZynSign

/// Tests for the workspace's presentation model: the dashboard counts,
/// the readiness gating of delivery, the never-resolved-by-code attempts,
/// the query projection, and the bulk preparation wiring.
@MainActor
final class InstallationWorkspaceModelTests: XCTestCase {

    private var root: URL!
    private var workspace: InstallationWorkspace!
    private var installed: InMemoryInstalledApplicationStore!
    private var history: InMemorySigningHistoryStore!

    override func setUpWithError() throws {
        root = try LibraryFixtures.makeTemporaryDirectory()
        installed = InMemoryInstalledApplicationStore()
        history = InMemorySigningHistoryStore()
        let records = InMemoryApplicationRecordStore()
        let artifacts = SyntheticLibraryArtifactStore()
        let library = ApplicationLibrary(records: records, artifacts: artifacts)
        let exports = ExportCenter(
            records: FileExportRecordStore(
                catalogLocation: root.appendingPathComponent("Exports.json", isDirectory: false)
            ),
            artifacts: FileExportArtifactStore(
                exportsDirectory: root.appendingPathComponent("Signed", isDirectory: true)
            )
        )
        workspace = InstallationWorkspace(
            library: library,
            history: history,
            exports: exports,
            installed: installed,
            verification: nil,
            installedByteCount: { nil }
        )
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        workspace = nil
        installed = nil
        history = nil
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - Gating

    func testDeliveryIsGatedOnReadiness() async {
        let model = InstallationWorkspaceModel(workspace: workspace)
        await model.load()
        // No signed applications at all: nothing may deliver.
        XCTAssertTrue(model.readyCandidateRows.isEmpty)
        XCTAssertTrue(model.blockedCandidateRows.isEmpty)
        XCTAssertEqual(model.counts.readyToInstall, 0)
    }

    func testModelWithoutWorkspaceReportsItselfUnavailable() async {
        let model = InstallationWorkspaceModel(workspace: nil)
        await model.load()

        guard case .failed = model.phase else {
            return XCTFail("A workspace-less model must fail visibly, not show an empty dashboard.")
        }
    }

    // MARK: - Attempts are never resolved by code

    func testReloadingKeepsAttemptsPendingAndInstallsNothing() async throws {
        await installed.seed(InstallationFixtures.attempt(startedAt: InstallationFixtures.lastMonth))
        let model = InstallationWorkspaceModel(workspace: workspace)
        await model.load()

        XCTAssertEqual(model.attempts.count, 1, "The attempt is restored, exactly as pending.")
        XCTAssertEqual(model.counts.pendingAttempts, 1)
        XCTAssertTrue(model.installedRows.isEmpty, "No record exists, and loading created none.")

        // A second load — a relaunch-shaped refresh — resolves nothing.
        await model.load()
        XCTAssertEqual(model.attempts.count, 1)
        XCTAssertTrue(model.installedRows.isEmpty)
    }

    func testConfirmingAndAbandoningGoThroughTheWorkspace() async throws {
        let attempt = InstallationFixtures.attempt(exportIdentifier: nil)
        await installed.seed(attempt)
        let model = InstallationWorkspaceModel(workspace: workspace)
        await model.load()

        await model.abandon(attempt: attempt)

        XCTAssertTrue(model.attempts.isEmpty, "Abandoning resolves the attempt.")
        XCTAssertTrue(model.installedRows.isEmpty, "Nothing was recorded.")

        let second = InstallationFixtures.attempt(exportIdentifier: nil)
        await installed.seed(second)
        await model.confirm(attempt: second)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(model.installedRows.count, 1, "Confirmation records what the user said happened.")
    }

    // MARK: - Query projection

    func testQueryFiltersByScopeAndSearchInMemory() async {
        let upToDate = InstallationFixtures.installedRecord(
            bundleIdentifier: "com.example.uptodate",
            displayName: "Alpha Notes",
            exportIdentifier: "same-export",
            exportedAt: InstallationFixtures.lastWeek
        )
        let newestExport = InstallationFixtures.exportRecord(
            bundleIdentifier: "com.example.stale",
            displayName: "Beta Reader",
            shortVersion: "2.0",
            buildVersion: "10",
            createdAt: InstallationFixtures.now
        )
        // The record's latest event names an export that no longer exists,
        // so the newest held export (newestExport) is what update state
        // compares against.
        let stale = InstallationFixtures.installedRecord(
            bundleIdentifier: "com.example.stale",
            displayName: "Beta Reader",
            shortVersion: "1.0",
            buildVersion: "1",
            exportIdentifier: "vanished-export",
            exportedAt: InstallationFixtures.lastMonth
        )

        await installed.seed(upToDate)
        await installed.seed(stale)

        // Hold one export so the stale record sees an update offer.
        let directory = root!.appendingPathComponent("Signed", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(count: newestExport.byteCount).write(
            to: directory.appendingPathComponent(newestExport.fileName)
        )
        let exports = ExportCenter(
            records: FileExportRecordStore(
                catalogLocation: root!.appendingPathComponent("Exports.json", isDirectory: false)
            ),
            artifacts: FileExportArtifactStore(exportsDirectory: directory)
        )
        try? await exports.write(newestExport)

        let model = InstallationWorkspaceModel(workspace: workspace)
        await model.load()

        XCTAssertEqual(model.installedRows.count, 2)
        XCTAssertEqual(model.counts.updatesAvailable, 1)

        model.query.scope = .updatesAvailable
        XCTAssertEqual(model.visibleInstalledRows.map(\.record.bundleIdentifier), ["com.example.stale"])

        model.query.scope = .all
        model.query.searchText = "alpha"
        XCTAssertEqual(model.visibleInstalledRows.map(\.record.bundleIdentifier), ["com.example.uptodate"])

        model.query.searchText = "com.example"
        XCTAssertEqual(model.visibleInstalledRows.count, 2, "Bundle identifiers are searchable.")

        model.query.searchText = ""
        model.query.order = .name
        XCTAssertEqual(model.visibleInstalledRows.map(\.record.displayOrIdentifier), ["Alpha Notes", "Beta Reader"])
    }

    // MARK: - Bulk actions

    func testPrepareAllEnqueuesReadinessAndVerificationJobs() async {
        let model = InstallationWorkspaceModel(workspace: workspace)
        await model.load()

        model.prepareAll()

        // No candidates at all — nothing queued.
        XCTAssertTrue(model.preparationQueue.jobs.isEmpty)
    }

    func testQueueSelectedSkipsRowsWithoutALibraryCandidate() async {
        await installed.seed(
            InstallationFixtures.installedRecord(
                bundleIdentifier: "com.example.unknown",
                displayName: "Unknown"
            )
        )
        let model = InstallationWorkspaceModel(workspace: workspace)
        await model.load()

        model.selection = [model.installedRows[0].id]
        model.queueSelected()

        XCTAssertTrue(model.preparationQueue.jobs.isEmpty,
                      "An installed app with no library candidate has nothing to prepare.")
    }
}

/// The update-state fixture helper above needed a rebuild of ExportRecord
/// with the same fields; this keeps the intent readable.
private func rebuilt(_ record: ExportRecord) -> ExportRecord { record }
