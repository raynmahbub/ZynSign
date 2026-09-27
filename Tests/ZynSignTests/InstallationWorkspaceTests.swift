import XCTest
@testable import ZynSign

/// Tests for the Installation Workspace use case: the candidate join,
/// readiness from held evidence, the record-by-confirmation flow, the
/// attempt lifecycle, update states, and the history projection.
final class InstallationWorkspaceTests: XCTestCase {

    private var root: URL!
    private var records: InMemoryApplicationRecordStore!
    private var artifacts: SyntheticLibraryArtifactStore!
    private var library: ApplicationLibrary!
    private var history: InMemorySigningHistoryStore!
    private var exports: ExportCenter!
    private var installed: InMemoryInstalledApplicationStore!
    private var workspace: InstallationWorkspace!

    override func setUpWithError() throws {
        root = try LibraryFixtures.makeTemporaryDirectory()
        records = InMemoryApplicationRecordStore()
        artifacts = SyntheticLibraryArtifactStore()
        library = ApplicationLibrary(records: records, artifacts: artifacts)
        history = InMemorySigningHistoryStore()
        let exportCatalog = root.appendingPathComponent("Exports.json", isDirectory: false)
        let exportDirectory = root.appendingPathComponent("Signed", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        exports = ExportCenter(
            records: FileExportRecordStore(catalogLocation: exportCatalog),
            artifacts: FileExportArtifactStore(exportsDirectory: exportDirectory)
        )
        installed = InMemoryInstalledApplicationStore()
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
        exports = nil
        history = nil
        library = nil
        artifacts = nil
        records = nil
        root = nil
        try super.tearDownWithError()
    }

    /// Places a byte-true artifact in export storage, so an export record's
    /// availability derives as available.
    private func holdArtifact(fileName: String, byteCount: Int) throws {
        let directory = root.appendingPathComponent("Signed", isDirectory: true)
        try Data(count: byteCount).write(to: directory.appendingPathComponent(fileName))
    }

    /// Imports one accepted package into the library and returns its record.
    private func importApplication(
        bundleIdentifier: String = "com.example.synthetic",
        displayName: String = "Example"
    ) async throws -> ApplicationRecord {
        let artifact = LibraryFixtures.acceptedArtifact(
            identity: LibraryFixtures.identity(
                bundleIdentifier: bundleIdentifier,
                displayName: displayName
            )
        )
        artifacts.stage(Data("package-\(bundleIdentifier)".utf8), as: artifact.id)
        let admission = try await library.admit(artifact)
        return admission.record
    }

    /// Records one successful signing run and one held export for `record`.
    @discardableResult
    private func signApplication(
        _ record: ApplicationRecord,
        shortVersion: String? = "1.2",
        exportID: ExportIdentifier = ExportIdentifier()
    ) async throws -> (SigningRecord, ExportRecord) {
        let export = InstallationFixtures.exportRecord(
            id: exportID,
            recordID: record.id.rawValue,
            bundleIdentifier: record.bundleIdentifier.rawValue,
            displayName: record.identity.displayName,
            shortVersion: shortVersion,
            buildVersion: record.identity.buildVersion
        )
        try holdArtifact(fileName: export.fileName, byteCount: export.byteCount)
        try await exports.write(export)
        let signing = InstallationFixtures.signingRecord(
            recordID: record.id.rawValue,
            bundleIdentifier: record.bundleIdentifier.rawValue,
            exportIdentifier: export.id.rawValue
        )
        try await history.append(signing)
        return (signing, export)
    }

    // MARK: - Candidates

    func testCandidateJoinsLibrarySigningAndExportFacts() async throws {
        let record = try await importApplication()
        let (signing, export) = try await signApplication(record)

        let candidates = try await workspace.candidates()

        XCTAssertEqual(candidates.count, 1)
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidate.entry.record.id, record.id)
        XCTAssertEqual(candidate.signingRecord?.id, signing.id)
        XCTAssertEqual(candidate.exportEntry?.record.id, export.id)
        XCTAssertEqual(candidate.displayName, "Example")
        XCTAssertEqual(candidate.bundleIdentifier, "com.example.synthetic")
        XCTAssertTrue(candidate.isLibraryArtifactAvailable)
    }

    func testCandidateWithoutJournalOrExportStillAssembles() async throws {
        _ = try await importApplication()

        let candidates = try await workspace.candidates()

        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertNil(candidate.signingRecord)
        XCTAssertNil(candidate.exportEntry)
        XCTAssertEqual(candidate.displayName, "Example", "The name falls back to the library record's declaration.")
    }

    func testBundleIdentifierFallbackJoinsLegacyJournalEntries() async throws {
        let record = try await importApplication()
        // A signing record written before the journal learned record
        // identifiers: bundle identifier only.
        let legacy = SigningRecord(
            presetID: nil,
            certificateFingerprint: nil,
            sourceBundleIdentifier: record.bundleIdentifier.rawValue,
            sourceDisplayName: "Example",
            stoppingStage: nil,
            errorCode: nil,
            outputFileName: "Example_signed.ipa",
            outputByteCount: 1_024,
            startedAt: InstallationFixtures.lastWeek,
            duration: 1,
            result: .succeeded
        )
        try await history.append(legacy)

        let candidates = try await workspace.candidates()

        XCTAssertEqual(candidates.first?.signingRecord?.id, legacy.id)
    }

    // MARK: - Readiness

    func testReadinessForFullyEstablishedCandidateIsReady() async throws {
        let record = try await importApplication()
        _ = try await signApplication(record)

        let report = try await workspace.readinessReport(forRecordID: record.id)

        let readiness = try XCTUnwrap(report)
        XCTAssertTrue(readiness.isReady)
        XCTAssertEqual(readiness.state(of: .signedArtifact), .passed)
        XCTAssertEqual(readiness.state(of: .artifactVerification), .passed)
        XCTAssertEqual(readiness.state(of: .packageReadable), .passed)
        XCTAssertEqual(readiness.state(of: .exportCompleted), .passed)
        XCTAssertEqual(readiness.state(of: .signingAssetsCurrent), .passed)
    }

    func testReadinessWithoutVerificationBlocks() async throws {
        let record = try await importApplication()
        // The unverified export is the newest one for the record, so the
        // join selects it and readiness must refuse on its evidence.
        let unverified = InstallationFixtures.exportRecord(
            recordID: record.id.rawValue,
            createdAt: InstallationFixtures.now,
            verificationStatus: .unsupported,
            verificationRecordedAt: nil
        )
        try holdArtifact(fileName: unverified.fileName, byteCount: unverified.byteCount)
        try await exports.write(unverified)
        _ = try await signApplication(record)

        let report = try await workspace.readinessReport(forRecordID: record.id)

        let readiness = try XCTUnwrap(report)
        XCTAssertFalse(readiness.isReady, "Never verified is not ready: ZynSign verifies before presenting ready.")
        XCTAssertEqual(readiness.blockedChecks, [.artifactVerification])
    }

    func testReadinessForMissingExportLosesVerificationAndPackageChecks() async throws {
        let record = try await importApplication()

        let report = try await workspace.readinessReport(forRecordID: record.id)

        let readiness = try XCTUnwrap(report)
        XCTAssertFalse(readiness.isReady)
        XCTAssertTrue(readiness.state(of: .artifactVerification)?.isBlocking ?? false)
        XCTAssertEqual(readiness.state(of: .packageReadable)?.isNotPerformed, true)
        XCTAssertEqual(readiness.state(of: .exportCompleted)?.isNotPerformed, true)
    }

    func testReadinessForMissingEntryIsNil() async throws {
        let report = try await workspace.readinessReport(forRecordID: ApplicationRecordIdentifier())
        XCTAssertNil(report)
    }

    // MARK: - Recording installations

    func testFirstConfirmationCreatesRecordAndSecondAppends() async throws {
        try await workspace.recordInstallation(
            intent: .installed,
            bundleIdentifier: "com.example.synthetic",
            displayName: "Example",
            libraryRecordIdentifier: nil,
            export: InstallationFixtures.exportRecord(),
            signingRecord: nil,
            channel: .otaLink,
            now: InstallationFixtures.lastWeek
        )
        try await workspace.recordInstallation(
            intent: .updated,
            bundleIdentifier: "com.example.synthetic",
            displayName: "Example",
            libraryRecordIdentifier: nil,
            export: InstallationFixtures.exportRecord(shortVersion: "1.3", buildVersion: "40"),
            signingRecord: nil,
            channel: .otaLink,
            now: InstallationFixtures.now
        )

        let records = try await workspace.installedRecords()

        XCTAssertEqual(records.count, 1, "One application, one record.")
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.events.count, 2)
        XCTAssertEqual(record.events.map(\.kind), [.installed, .updated])
        XCTAssertEqual(record.installedVersionDisplay, "1.3 (40)")
    }

    func testRemovingARecordLeavesExportsAndHistoryOfOthersIntact() async throws {
        let first = try await workspace.recordInstallation(
            intent: .installed,
            bundleIdentifier: "com.example.first",
            displayName: "First",
            libraryRecordIdentifier: nil,
            export: nil,
            signingRecord: nil,
            channel: .reportedAfterTheFact,
            now: InstallationFixtures.lastWeek
        )
        _ = try await workspace.recordInstallation(
            intent: .installed,
            bundleIdentifier: "com.example.second",
            displayName: "Second",
            libraryRecordIdentifier: nil,
            export: nil,
            signingRecord: nil,
            channel: .reportedAfterTheFact,
            now: InstallationFixtures.lastWeek
        )

        try await workspace.removeInstalledRecord(first.id)
        let remaining = try await workspace.installedRecords()

        XCTAssertEqual(remaining.map(\.bundleIdentifier), ["com.example.second"])
    }

    // MARK: - Attempts

    func testStartAttemptRecordsPendingStateOnly() async throws {
        let record = try await importApplication()
        _ = try await signApplication(record)
        let candidate = try await workspace.candidate(for: record.id)

        let attempt = try await workspace.startAttempt(
            intent: .installed,
            candidate: try XCTUnwrap(candidate),
            channel: .otaLink,
            now: InstallationFixtures.now
        )

        let pending = try await workspace.pendingAttempts()
        XCTAssertEqual(pending.map(\.id), [attempt.id])
        XCTAssertEqual(pending.first?.exportIdentifier, candidate?.exportEntry?.record.id.rawValue)
        XCTAssertTrue(try await workspace.installedRecords().isEmpty,
                      "Starting an attempt records no installation.")
    }

    func testConfirmAttemptAppendsEventAndResolvesTheAttempt() async throws {
        let record = try await importApplication()
        let (_, export) = try await signApplication(record)
        let candidate = try await workspace.candidate(for: record.id)
        let attempt = try await workspace.startAttempt(
            intent: .installed,
            candidate: try XCTUnwrap(candidate),
            channel: .otaLink,
            now: InstallationFixtures.lastWeek
        )

        let confirmed = try await workspace.confirmAttempt(withID: attempt.id, now: InstallationFixtures.now)

        XCTAssertEqual(confirmed.bundleIdentifier, record.bundleIdentifier.rawValue)
        XCTAssertEqual(confirmed.events.count, 1)
        XCTAssertEqual(confirmed.events.first?.exportIdentifier, export.id.rawValue)
        let pending = try await workspace.pendingAttempts()
        XCTAssertTrue(pending.isEmpty, "Confirmation resolves the attempt.")
    }

    func testAbandonAttemptResolvesWithoutRecordingAnything() async throws {
        let record = try await importApplication()
        _ = try await signApplication(record)
        let candidate = try await workspace.candidate(for: record.id)
        let attempt = try await workspace.startAttempt(
            intent: .installed,
            candidate: try XCTUnwrap(candidate),
            channel: .hostTool,
            now: InstallationFixtures.now
        )

        try await workspace.abandonAttempt(withID: attempt.id)

        XCTAssertTrue(try await workspace.pendingAttempts().isEmpty)
        XCTAssertTrue(try await workspace.installedRecords().isEmpty,
                      "An abandoned delivery is never in the history.")
        // The artifact stays held: abandonment never touches exports.
        let entries = try await exports.entries()
        XCTAssertTrue(entries.first?.isAvailable ?? false)
    }

    func testConfirmingAnUnknownAttemptThrows() async throws {
        do {
            _ = try await workspace.confirmAttempt(withID: InstallationEventIdentifier())
            XCTFail("Confirming an unknown attempt must throw.")
        } catch let error as ZynSignError {
            XCTAssertFalse(error.userMessage.isEmpty)
        }
    }

    // MARK: - Update states

    func testUpdateStatesResolveInOnePass() async throws {
        let olderRecord = InstallationFixtures.installedRecord(
            bundleIdentifier: "com.example.synthetic",
            shortVersion: "1.2",
            buildVersion: "34",
            exportIdentifier: "installed-export"
        )
        await installed.seed(olderRecord)
        let libraryRecord = try await importApplication()
        _ = try await signApplication(libraryRecord, shortVersion: "1.10")

        let states = await workspace.updateStates(for: [olderRecord])

        guard case .updateAvailable(let candidate)? = states[olderRecord.id] else {
            return XCTFail("Expected an update offer, got \(states)")
        }
        XCTAssertEqual(candidate.shortVersion, "1.10", "The offer carries the newer export's declared version.")
    }

    // MARK: - History

    func testHistoryFlattensEventsNewestFirstAndHonoursTheLimit() async throws {
        try await workspace.recordInstallation(
            intent: .installed,
            bundleIdentifier: "com.example.one",
            displayName: "One",
            libraryRecordIdentifier: nil,
            export: nil,
            signingRecord: nil,
            channel: .reportedAfterTheFact,
            now: InstallationFixtures.lastMonth
        )
        try await workspace.recordInstallation(
            intent: .updated,
            bundleIdentifier: "com.example.one",
            displayName: "One",
            libraryRecordIdentifier: nil,
            export: nil,
            signingRecord: nil,
            channel: .reportedAfterTheFact,
            now: InstallationFixtures.lastWeek
        )
        try await workspace.recordInstallation(
            intent: .installed,
            bundleIdentifier: "com.example.two",
            displayName: "Two",
            libraryRecordIdentifier: nil,
            export: nil,
            signingRecord: nil,
            channel: .hostTool,
            now: InstallationFixtures.now
        )

        let all = try await workspace.history()
        let limited = try await workspace.history(limit: 2)

        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.first?.event.at, InstallationFixtures.now)
        XCTAssertEqual(all.first?.appName, "Two")
        XCTAssertEqual(limited.count, 2)
        XCTAssertTrue(limited.contains { $0.appName == "Two" })
    }

    // MARK: - Verification on demand

    func testVerifyWithoutComposedVerifierThrowsATypedError() async throws {
        let id = ExportIdentifier()
        let export = InstallationFixtures.exportRecord(id: id)
        try holdArtifact(fileName: export.fileName, byteCount: export.byteCount)
        try await exports.write(export)

        do {
            _ = try await workspace.verifyExport(id)
            XCTFail("Verification without a composed verifier must throw.")
        } catch let error as ZynSignError {
            XCTAssertFalse(error.userMessage.isEmpty)
        }
    }

    func testVerifyOfMissingExportThrows() async throws {
        do {
            _ = try await workspace.verifyExport(ExportIdentifier())
            XCTFail("Verifying an unknown export must throw.")
        } catch { }
    }
}
