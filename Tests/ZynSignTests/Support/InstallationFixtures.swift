import Foundation
@testable import ZynSign

// MARK: - Installed-applications store double

/// An `InstalledApplicationStore` that keeps records and attempts in
/// memory, with orders matching the ports' contracts: records most
/// recently updated first, attempts oldest first.
actor InMemoryInstalledApplicationStore: InstalledApplicationStore {

    private var storedRecords: [InstalledApplicationRecord] = []
    private var storedAttempts: [PendingInstallationAttempt] = []

    /// When non-`nil`, every write and removal throws this without
    /// changing anything.
    var writeError: (any Error)?

    nonisolated var capacity: Int { 100 }

    func allRecords() async throws -> [InstalledApplicationRecord] {
        storedRecords.sorted { $0.updatedAt > $1.updatedAt }
    }

    func write(_ record: InstalledApplicationRecord) async throws {
        if let writeError { throw writeError }
        if let index = storedRecords.firstIndex(where: { $0.id == record.id }) {
            storedRecords[index] = record
        } else {
            storedRecords.append(record)
        }
    }

    func remove(recordWithID id: InstalledApplicationIdentifier) async throws {
        if let writeError { throw writeError }
        storedRecords.removeAll { $0.id == id }
    }

    func removeAllRecords() async throws {
        if let writeError { throw writeError }
        storedRecords.removeAll()
    }

    func allAttempts() async throws -> [PendingInstallationAttempt] {
        storedAttempts.sorted { $0.startedAt < $1.startedAt }
    }

    func write(_ attempt: PendingInstallationAttempt) async throws {
        if let writeError { throw writeError }
        if let index = storedAttempts.firstIndex(where: { $0.id == attempt.id }) {
            storedAttempts[index] = attempt
        } else {
            storedAttempts.append(attempt)
        }
    }

    func removeAttempt(withID id: InstallationEventIdentifier) async throws {
        if let writeError { throw writeError }
        storedAttempts.removeAll { $0.id == id }
    }

    /// Seeds a record directly, bypassing the port, for tests that arrange
    /// prior state.
    func seed(_ record: InstalledApplicationRecord) {
        storedRecords.append(record)
    }

    /// Seeds an attempt directly.
    func seed(_ attempt: PendingInstallationAttempt) {
        storedAttempts.append(attempt)
    }

    /// Whether the store holds any attempt with `id`.
    func containsAttempt(withID id: InstallationEventIdentifier) -> Bool {
        storedAttempts.contains { $0.id == id }
    }
}

// MARK: - Builders

/// Synthetic values for the Installation Workspace's tests. Timestamps are
/// fixed literals so ordering and expiry assertions are deterministic.
enum InstallationFixtures {

    /// A fixed "now" for evaluations: later than every fixture date below.
    // Anchored to the real clock: readiness evaluates asset expiry against
    // Date(), so a fixture frozen in the past would report every signing
    // asset expired. Whole seconds keep the ISO-8601 catalog roundtrip
    // exact, and the relative offsets below keep their shape.
    static let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

    /// A date one week before `now`.
    static let lastWeek = now.addingTimeInterval(-7 * 24 * 60 * 60)

    /// A date one month after `now`.
    static let nextMonth = now.addingTimeInterval(30 * 24 * 60 * 60)

    /// A date one month before `now`.
    static let lastMonth = now.addingTimeInterval(-30 * 24 * 60 * 60)

    /// A successful signing record for a source record, with optional
    /// expiry dates and an export link.
    static func signingRecord(
        recordID: String,
        bundleIdentifier: String = "com.example.synthetic",
        displayName: String = "Example",
        exportIdentifier: String? = nil,
        profileExpiresAt: Date? = nextMonth,
        certificateExpiresAt: Date? = nextMonth,
        startedAt: Date = lastWeek
    ) -> SigningRecord {
        SigningRecord(
            presetID: nil,
            certificateFingerprint: nil,
            sourceBundleIdentifier: bundleIdentifier,
            sourceDisplayName: displayName,
            stoppingStage: nil,
            errorCode: nil,
            outputFileName: exportIdentifier.map { _ in "Example_signed.ipa" },
            outputByteCount: exportIdentifier.map { _ in 1_024 },
            startedAt: startedAt,
            duration: 1.5,
            result: .succeeded,
            sourceRecordIdentifier: recordID,
            shortVersion: "1.2",
            buildVersion: "34",
            certificateDisplayName: "Apple Development: Example (AB12CD34)",
            teamIdentifier: "AB12CD34",
            provisioningProfileName: "Example Profile",
            configuration: nil,
            failure: nil,
            outputFingerprint: nil,
            exportIdentifier: exportIdentifier,
            verificationStatus: .valid,
            verificationRecordedAt: startedAt,
            verificationFindings: nil,
            timeline: nil,
            profileExpiresAt: profileExpiresAt,
            certificateExpiresAt: certificateExpiresAt
        )
    }

    /// An export record for an artifact held in export storage.
    static func exportRecord(
        id: ExportIdentifier = ExportIdentifier(),
        recordID: String? = nil,
        bundleIdentifier: String = "com.example.synthetic",
        displayName: String? = "Example",
        shortVersion: String? = "1.2",
        buildVersion: String? = "34",
        fileName: String = "Example_signed.ipa",
        byteCount: Int = 1_024,
        createdAt: Date = lastWeek,
        verificationStatus: ArtifactVerificationStatus = .valid,
        verificationRecordedAt: Date? = lastWeek
    ) -> ExportRecord {
        ExportRecord(
            id: id,
            sourceRecordIdentifier: recordID,
            sourceArtifactIdentifier: nil,
            applicationName: displayName,
            bundleIdentifier: bundleIdentifier,
            shortVersion: shortVersion,
            buildVersion: buildVersion,
            fileName: fileName,
            byteCount: byteCount,
            fingerprint: ExportFingerprint(LibraryFixtures.fingerprint(seed: 0x11)),
            createdAt: createdAt,
            signingOutcome: .succeeded,
            verificationStatus: verificationStatus,
            verificationRecordedAt: verificationRecordedAt,
            verificationFindings: nil,
            verificationChecksRun: verificationRecordedAt == nil ? nil : 12,
            deliveredAt: nil
        )
    }

    /// An installed-application record with one `installed` event.
    static func installedRecord(
        bundleIdentifier: String = "com.example.synthetic",
        displayName: String = "Example",
        shortVersion: String? = "1.2",
        buildVersion: String? = "34",
        exportIdentifier: String? = nil,
        exportedAt: Date = lastWeek,
        channel: InstallationChannel = .otaLink
    ) -> InstalledApplicationRecord {
        let event = InstalledApplicationEvent(
            kind: .installed,
            at: exportedAt,
            shortVersion: shortVersion,
            buildVersion: buildVersion,
            exportIdentifier: exportIdentifier,
            exportFileName: exportIdentifier.map { _ in "Example_signed.ipa" },
            signingRecordIdentifier: nil,
            verificationStatus: .valid,
            channel: channel
        )
        return InstalledApplicationRecord(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            events: [event],
            recordedAt: exportedAt,
            updatedAt: exportedAt
        )
    }

    /// A pending attempt for a candidate's facts.
    static func attempt(
        intent: InstallationEventKind = .installed,
        bundleIdentifier: String = "com.example.synthetic",
        exportIdentifier: String? = nil,
        channel: InstallationChannel = .otaLink,
        startedAt: Date = now
    ) -> PendingInstallationAttempt {
        PendingInstallationAttempt(
            intent: intent,
            bundleIdentifier: bundleIdentifier,
            displayName: "Example",
            libraryRecordIdentifier: nil,
            exportIdentifier: exportIdentifier,
            exportFileName: exportIdentifier.map { _ in "Example_signed.ipa" },
            shortVersion: "1.2",
            buildVersion: "34",
            signingRecordIdentifier: nil,
            verificationStatus: .valid,
            channel: channel,
            startedAt: startedAt
        )
    }

    /// Evidence whose every check passes.
    static func passingEvidence(now: Date = InstallationFixtures.now) -> InstallationReadinessEvidence {
        InstallationReadinessEvidence(
            signingOutcome: .succeeded,
            verificationStatus: .valid,
            fingerprintRecorded: true,
            artifactAvailable: true,
            profileExpiresAt: now.addingTimeInterval(30 * 24 * 60 * 60),
            certificateExpiresAt: now.addingTimeInterval(60 * 24 * 60 * 60),
            bundleIdentifier: "com.example.synthetic",
            displayName: "Example",
            shortVersion: "1.2",
            now: now
        )
    }
}
