import Foundation
import XCTest
@testable import ZynSign

/// Fixtures and doubles for the Smart Import Hub.
///
/// Everything here is synthetic: packages are built in memory by the ZIP
/// fixture builder, identities come from `LibraryFixtures`, and the doubles
/// script the hub's collaborators per file name so each test states exactly
/// what every item will do.
enum ImportHubFixtures {

    // MARK: - Packages

    /// The entries of a valid application package declaring the given
    /// identity, with optional extra entries inside the bundle.
    static func packageEntries(
        identifier: String = "com.example.synthetic",
        displayName: String = "Example",
        version: String? = "1.2",
        build: String? = "34",
        bundleName: String = "Example.app",
        extraBundleEntries: [ZipFixtureBuilder.Entry] = []
    ) -> [ZipFixtureBuilder.Entry] {
        let plist = ImportFixtures.infoPlistData(
            identifier: identifier,
            displayName: displayName,
            shortVersion: version,
            buildVersion: build,
            executableName: "Example"
        )
        return [
            .directory("Payload"),
            .directory("Payload/\(bundleName)"),
            ZipFixtureBuilder.Entry(name: "Payload/\(bundleName)/Info.plist", content: Array(plist)),
            ZipFixtureBuilder.Entry(name: "Payload/\(bundleName)/Example", content: Array(repeating: 0x90, count: 256), deflate: true),
        ] + extraBundleEntries
    }

    /// The bytes of a valid application package.
    static func package(
        identifier: String = "com.example.synthetic",
        displayName: String = "Example",
        version: String? = "1.2",
        build: String? = "34",
        extraBundleEntries: [ZipFixtureBuilder.Entry] = []
    ) -> Data {
        Data(ZipFixtureBuilder.archive(packageEntries(
            identifier: identifier,
            displayName: displayName,
            version: version,
            build: build,
            extraBundleEntries: extraBundleEntries
        )))
    }

    // MARK: - Prepared imports

    /// A prepared import for a staged item, declaring `identity`, with a
    /// conflict against `existing` records when any share its bundle ID.
    static func prepared(
        for staged: StagedImport,
        identity: ApplicationIdentity = LibraryFixtures.identity(),
        byteCount: Int = 2_048,
        fingerprintSeed: UInt8 = 0x11,
        against existing: [ApplicationRecord] = [],
        analysis: ApplicationAnalysis = ImportHubFixtures.analysis
    ) -> PreparedImport {
        let artifact = LibraryFixtures.acceptedArtifact(
            id: staged.artifactID,
            sourceFileName: staged.fileName,
            identity: identity
        )
        let reference = LibraryFixtures.reference(
            artifactID: staged.artifactID,
            byteCount: byteCount,
            fingerprintSeed: fingerprintSeed
        )
        let report = DuplicateDetection.report(identity: identity, reference: reference, against: existing)
        return PreparedImport(
            artifact: artifact,
            identity: identity,
            reference: reference,
            analysis: analysis,
            iconData: nil,
            conflict: ImportRules.conflict(for: report, incoming: identity)
        )
    }

    static let analysis = ApplicationAnalysis(
        signingState: .signaturePresent,
        includesProvisioningProfile: true,
        frameworkCount: 3,
        extensionCount: 1,
        fileCount: 42,
        unpackedByteCount: 9_000
    )

    static func candidate(_ path: String, byteCount: Int = 4_096) -> NestedPackageCandidate {
        NestedPackageCandidate(path: makePath(path), byteCount: byteCount, compressedByteCount: byteCount / 2)
    }

    static func sourceURL(_ name: String) -> URL {
        ImportFixtures.sourceURL(name: name)
    }
}

// MARK: - Waiting

extension XCTestCase {

    /// Waits on the main actor until `condition` holds, failing the test
    /// (rather than hanging it) after `timeout` seconds.
    @MainActor
    func waitUntil(
        _ message: String = "The condition was never met.",
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail(message, file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}

// MARK: - Processing double

/// A scripted `ImportProcessing`: each file name is given what staging,
/// examination, and admission will do, and the double records every call.
final class SyntheticImportProcessing: ImportProcessing, @unchecked Sendable {

    enum StageScript {
        /// Stages at once, reporting the given progress first.
        case succeeds(progress: [ImportProgress])
        /// Throws `error`.
        case fails(any Error)
        /// Waits until `release(_:)` is called for the file, or the task is
        /// cancelled.
        case waitsForRelease
    }

    enum ExamineScript {
        /// A package declaring `identity`, conflicting with `existing`.
        case package(identity: ApplicationIdentity, fingerprintSeed: UInt8, existing: [ApplicationRecord])
        /// An archive offering `candidates`.
        case archive([NestedPackageCandidate])
        /// Throws `error`.
        case fails(any Error)
    }

    private let lock = NSLock()
    private var stageScripts: [String: StageScript] = [:]
    private var examineScripts: [String: ExamineScript] = [:]
    private var admissionFailures: [String: any Error] = [:]
    private var releasedNames: Set<String> = []
    private var runningStages = 0

    private var stagedNamesStorage: [String] = []
    private var stagedSourcesStorage: [ImportStagingSource] = []
    private var examinedNamesStorage: [String] = []
    private var admittedStorage: [(fileName: String, resolution: ConflictResolution?)] = []
    private var discardedStorage: [ArtifactIdentifier] = []
    private var workingCopies: [ArtifactIdentifier: Int] = [:]
    private var sweptKeepingStorage: Set<ArtifactIdentifier>?
    private var peakConcurrentStages = 0

    /// Unscripted packages each get their own content fingerprint, so two
    /// of them are never mistaken for identical copies.
    private var nextFingerprintSeed: UInt8 = 0x80

    /// What `availableCapacity()` reports.
    var capacity: Int?

    // MARK: Scripting

    func script(_ name: String, stage: StageScript = .succeeds(progress: []), examine: ExamineScript) {
        lock.withLock {
            stageScripts[name] = stage
            examineScripts[name] = examine
        }
    }

    func scriptStage(_ name: String, _ stage: StageScript) {
        lock.withLock { stageScripts[name] = stage }
    }

    func scriptExamine(_ name: String, _ examine: ExamineScript) {
        lock.withLock { examineScripts[name] = examine }
    }

    func failAdmission(of name: String, with error: any Error) {
        lock.withLock { admissionFailures[name] = error }
    }

    func release(_ name: String) {
        lock.withLock { _ = releasedNames.insert(name) }
    }

    /// Declares that a working copy survived an interruption.
    func keepWorkingCopy(_ artifact: ArtifactIdentifier, byteCount: Int) {
        lock.withLock { workingCopies[artifact] = byteCount }
    }

    // MARK: Observations

    var stagedNames: [String] { lock.withLock { stagedNamesStorage } }
    var stagedSources: [ImportStagingSource] { lock.withLock { stagedSourcesStorage } }
    var examinedNames: [String] { lock.withLock { examinedNamesStorage } }
    var admitted: [(fileName: String, resolution: ConflictResolution?)] { lock.withLock { admittedStorage } }
    var discarded: [ArtifactIdentifier] { lock.withLock { discardedStorage } }
    var sweptKeeping: Set<ArtifactIdentifier>? { lock.withLock { sweptKeepingStorage } }
    var maximumConcurrentStages: Int { lock.withLock { peakConcurrentStages } }

    // MARK: ImportProcessing

    func stage(
        _ source: ImportStagingSource,
        fileName: String,
        as artifact: ArtifactIdentifier,
        reporting progress: (any ImportProgressReporting)?
    ) async throws -> StagedImport {
        let script: StageScript = lock.withLock {
            stagedNamesStorage.append(fileName)
            stagedSourcesStorage.append(source)
            runningStages += 1
            peakConcurrentStages = max(peakConcurrentStages, runningStages)
            return stageScripts[fileName] ?? .succeeds(progress: [])
        }
        defer { lock.withLock { runningStages -= 1 } }

        switch script {
        case .succeeds(let reports):
            reports.forEach { progress?.report($0) }
        case .fails(let error):
            throw error
        case .waitsForRelease:
            while !lock.withLock({ releasedNames.contains(fileName) }) {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        try Task.checkCancellation()
        lock.withLock { workingCopies[artifact] = 2_048 }
        return StagedImport(artifactID: artifact, fileName: fileName, byteCount: 2_048)
    }

    func examine(
        _ staged: StagedImport,
        reporting progress: (any ImportProgressReporting)?
    ) async throws -> ImportExamination {
        let script: ExamineScript? = lock.withLock {
            examinedNamesStorage.append(staged.fileName)
            return examineScripts[staged.fileName]
        }
        progress?.report(ImportProgress(stage: .examiningStructure))
        progress?.report(ImportProgress(stage: .examiningMetadata))
        switch script {
        case .some(.package(let identity, let seed, let existing)):
            return .package(ImportHubFixtures.prepared(for: staged, identity: identity, fingerprintSeed: seed, against: existing))
        case .some(.archive(let candidates)):
            return .archive(candidates)
        case .some(.fails(let error)):
            throw error
        case .none:
            let seed: UInt8 = lock.withLock {
                defer { nextFingerprintSeed &+= 1 }
                return nextFingerprintSeed
            }
            return .package(ImportHubFixtures.prepared(for: staged, fingerprintSeed: seed))
        }
    }

    func admit(
        _ prepared: PreparedImport,
        resolution: ConflictResolution?,
        reporting progress: (any ImportProgressReporting)?
    ) async throws -> ImportSettlement {
        let fileName = prepared.artifact.sourceFileName ?? ""
        let failure: (any Error)? = lock.withLock {
            admittedStorage.append((fileName, resolution))
            workingCopies[prepared.artifactID] = nil
            return admissionFailures[fileName]
        }
        if let failure {
            throw failure
        }
        progress?.report(ImportProgress(stage: .storing))
        let record = LibraryFixtures.record(
            identity: prepared.identity,
            sourceFileName: fileName,
            artifact: prepared.reference
        )
        switch resolution {
        case .none:
            return ImportSettlement(kind: .imported, record: record)
        case .some(.keepBoth):
            return ImportSettlement(kind: .keptBoth, record: record)
        case .some(.replaceExisting):
            return ImportSettlement(kind: .replaced, record: record, replacedRecords: prepared.conflict?.existingRecords ?? [])
        case .some(.skip):
            return .skipped()
        }
    }

    func discardWorkingCopy(_ artifact: ArtifactIdentifier) {
        lock.withLock {
            discardedStorage.append(artifact)
            workingCopies[artifact] = nil
        }
    }

    func workingCopyByteCount(_ artifact: ArtifactIdentifier) -> Int? {
        lock.withLock { workingCopies[artifact] }
    }

    func sweepWorkingCopies(keeping artifacts: Set<ArtifactIdentifier>) {
        lock.withLock {
            sweptKeepingStorage = artifacts
            workingCopies = workingCopies.filter { artifacts.contains($0.key) }
        }
    }

    func availableCapacity() -> Int? {
        lock.withLock { capacity }
    }
}

// MARK: - Store doubles

/// An in-memory import history.
actor InMemoryImportHistoryStore: ImportHistoryStore {

    private(set) var entries: [ImportHistoryEntry] = []

    init(entries: [ImportHistoryEntry] = []) {
        self.entries = entries
    }

    func allEntries() throws -> [ImportHistoryEntry] {
        entries
    }

    func record(_ entry: ImportHistoryEntry) throws {
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
    }

    func remove(entryWithID id: ImportBatchIdentifier) throws {
        entries.removeAll { $0.id == id }
    }

    func clear() throws {
        entries = []
    }
}

/// An in-memory interrupted-import journal.
actor InMemoryImportRecoveryJournal: ImportRecoveryJournal {

    private(set) var records: [ImportRecoveryRecord]

    init(records: [ImportRecoveryRecord] = []) {
        self.records = records
    }

    func pendingRecords() throws -> [ImportRecoveryRecord] {
        records
    }

    func replace(with records: [ImportRecoveryRecord]) throws {
        self.records = records
    }
}

/// A background-execution double that hands out activities and keeps the
/// expiration handler so a test can end the background time.
@MainActor
final class SyntheticBackgroundExecution: ImportBackgroundExecution {

    private(set) var begun = 0
    private(set) var ended: [ImportBackgroundActivity] = []
    private var expiration: (@MainActor () -> Void)?

    nonisolated init() {}

    func beginBackgroundWork(expiration: @escaping @MainActor () -> Void) -> ImportBackgroundActivity? {
        begun += 1
        self.expiration = expiration
        return ImportBackgroundActivity(rawValue: begun)
    }

    func endBackgroundWork(_ activity: ImportBackgroundActivity) {
        ended.append(activity)
    }

    /// Simulates the system ending the background time.
    func expire() {
        expiration?()
    }
}

/// A capacity probe that reports a fixed figure.
struct FixedStorageCapacityProbe: StorageCapacityProbe {
    let capacity: Int?

    func availableCapacity() -> Int? {
        capacity
    }
}

/// A staging area for the workflow over `SyntheticIntake`: documents are
/// staged by the intake double, and archive entries are not supported.
final class SyntheticImportStagingArea: ImportStagingArea {

    private(set) var sweptKeeping: Set<ArtifactIdentifier>?

    func stageArchiveEntry(
        _ candidate: NestedPackageCandidate,
        from container: ArtifactIdentifier,
        as artifact: ArtifactIdentifier,
        reporting progress: (any ImportProgressReporting)?
    ) throws {
        throw ZynSignError.unsupportedArchiveFeature(diagnosticDetail: "The synthetic staging area extracts nothing.")
    }

    func stagedByteCount(for artifact: ArtifactIdentifier) -> Int? {
        nil
    }

    func sweepStagedDocuments(keeping artifacts: Set<ArtifactIdentifier>) {
        sweptKeeping = artifacts
    }
}
