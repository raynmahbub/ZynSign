import CryptoKit
import Foundation
import XCTest
@testable import ZynSign

// MARK: - Record fixtures

/// Builds domain values for library and persistence tests.
///
/// Every fixture is synthetic: identities, names, versions, byte content,
/// and timestamps are invented literals. Timestamps are fixed so that
/// ordering and round-trip assertions are deterministic.
enum LibraryFixtures {

    /// A fixed import instant, safely representable as a JSON number.
    static let importDate = Date(timeIntervalSinceReferenceDate: 750_000_000)

    /// The instant one second after `importDate`.
    static let laterDate = Date(timeIntervalSinceReferenceDate: 750_000_001)

    /// A declared identity with the supplied values.
    static func identity(
        bundleIdentifier: String = "com.example.synthetic",
        displayName: String? = "Example",
        shortVersion: String? = "1.2",
        build: String? = "34"
    ) -> ApplicationIdentity {
        guard let identifier = BundleIdentifier(rawValue: bundleIdentifier) else {
            preconditionFailure("Test fixture bundle identifier is not valid: \(bundleIdentifier)")
        }
        return ApplicationIdentity(
            bundleIdentifier: identifier,
            declaredDisplayName: displayName,
            shortVersionString: shortVersion,
            buildVersion: build
        )
    }

    /// An artifact that passed structural and metadata inspection, as the
    /// import use case would hand it to the library.
    static func acceptedArtifact(
        id: ArtifactIdentifier = ArtifactIdentifier(),
        sourceFileName: String? = "Example.ipa",
        identity: ApplicationIdentity = identity(),
        executableName: String? = "Example",
        validation: ValidationResult = .valid()
    ) -> IPAArtifact {
        IPAArtifact(id: id, sourceFileName: sourceFileName).metadataExamined(
            bundle: nil,
            metadata: ApplicationMetadata(identity: identity, executableName: executableName),
            validation: validation
        )
    }

    /// An artifact that inspection rejected.
    static func rejectedArtifact(id: ArtifactIdentifier = ArtifactIdentifier()) -> IPAArtifact {
        IPAArtifact(id: id, sourceFileName: "Broken.ipa").examined(
            bundle: nil,
            validation: .invalid(findings: [
                ValidationFinding(severity: .error, code: .missingApplicationBundle, detail: "synthetic detail"),
            ])
        )
    }

    /// The SHA-256 fingerprint of `content`, computed independently of the
    /// implementation under test.
    static func fingerprint(of content: Data) -> ArtifactFingerprint {
        let digest = Array(SHA256.hash(data: content))
        guard let fingerprint = ArtifactFingerprint(algorithm: .sha256, digestBytes: digest) else {
            preconditionFailure("A SHA-256 digest must always form a fingerprint.")
        }
        return fingerprint
    }

    /// A deterministic fingerprint made from a repeated byte, for tests
    /// that need distinct fingerprints without hashing anything.
    static func fingerprint(seed: UInt8) -> ArtifactFingerprint {
        guard let fingerprint = ArtifactFingerprint(
            algorithm: .sha256,
            digestBytes: Array(repeating: seed, count: 32)
        ) else {
            preconditionFailure("A 32-byte digest must always form a fingerprint.")
        }
        return fingerprint
    }

    /// A reference to synthetic content.
    static func reference(
        artifactID: ArtifactIdentifier = ArtifactIdentifier(),
        byteCount: Int = 1_024,
        fingerprintSeed: UInt8 = 0xAB
    ) -> ArtifactReference {
        ArtifactReference(
            artifactID: artifactID,
            byteCount: byteCount,
            fingerprint: fingerprint(seed: fingerprintSeed)
        )
    }

    /// A reference describing `content` exactly.
    static func reference(to content: Data, artifactID: ArtifactIdentifier = ArtifactIdentifier()) -> ArtifactReference {
        ArtifactReference(artifactID: artifactID, byteCount: content.count, fingerprint: fingerprint(of: content))
    }

    /// A complete record with the supplied values.
    static func record(
        id: ApplicationRecordIdentifier = ApplicationRecordIdentifier(),
        identity: ApplicationIdentity = identity(),
        executableName: String? = "Example",
        sourceFileName: String? = "Example.ipa",
        artifact: ArtifactReference = reference(),
        warningCodes: [ValidationIssueCode] = [],
        importedAt: Date = importDate,
        updatedAt: Date? = nil
    ) -> ApplicationRecord {
        ApplicationRecord(
            id: id,
            identity: identity,
            executableName: executableName,
            sourceFileName: sourceFileName,
            artifact: artifact,
            inspection: ApplicationRecord.InspectionSummary(classification: .valid, warningCodes: warningCodes),
            importedAt: importedAt,
            updatedAt: updatedAt ?? importedAt
        )
    }

    /// Creates a fresh, empty temporary directory for one test.
    static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZynSignLibraryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

// MARK: - Clock double

/// A deterministic clock for record timestamps: each reading is one second
/// after the previous one, starting at `LibraryFixtures.importDate`, so
/// records created in sequence have a stable, distinct library order.
final class SyntheticClock: @unchecked Sendable {

    private let lock = NSLock()
    private let start: Date
    private var readings = 0

    init(start: Date = LibraryFixtures.importDate) {
        self.start = start
    }

    func now() -> Date {
        lock.withLock { () -> Date in
            defer { readings += 1 }
            return start.addingTimeInterval(TimeInterval(readings))
        }
    }
}

// MARK: - Record store double

/// An `ApplicationRecordStore` that keeps records in memory and can be
/// driven into deterministic failures.
///
/// It exists so the library use case can be exercised without a
/// filesystem, and so a failing insert — the case that must roll an
/// adopted artifact back — can be produced on demand.
actor InMemoryApplicationRecordStore: ApplicationRecordStore {

    private var records: [ApplicationRecordIdentifier: ApplicationRecord] = [:]
    private var insertError: (any Error)?
    private var listError: (any Error)?

    /// The identifiers of every record inserted, in order.
    private(set) var insertedIDs: [ApplicationRecordIdentifier] = []

    init(records: [ApplicationRecord] = []) {
        for record in records {
            self.records[record.id] = record
        }
    }

    /// Makes every subsequent insert throw `error`.
    func failInserts(with error: any Error) {
        insertError = error
    }

    /// Makes every subsequent listing throw `error`.
    func failListing(with error: any Error) {
        listError = error
    }

    /// How many records the store holds.
    var count: Int { records.count }

    func insert(_ record: ApplicationRecord) async throws {
        if let insertError {
            throw insertError
        }
        guard records[record.id] == nil else {
            throw ZynSignError.libraryRecordConflict(diagnosticDetail: "synthetic conflict")
        }
        records[record.id] = record
        insertedIDs.append(record.id)
    }

    func update(_ record: ApplicationRecord) async throws {
        guard records[record.id] != nil else {
            throw ZynSignError.libraryRecordNotFound(diagnosticDetail: "synthetic missing record")
        }
        records[record.id] = record
    }

    func record(withID id: ApplicationRecordIdentifier) async throws -> ApplicationRecord? {
        records[id]
    }

    func allRecords() async throws -> [ApplicationRecord] {
        if let listError {
            throw listError
        }
        return records.values.sorted(by: ApplicationRecord.libraryOrder)
    }

    func delete(recordWithID id: ApplicationRecordIdentifier) async throws {
        records.removeValue(forKey: id)
    }
}

// MARK: - Artifact store double

/// A `LibraryArtifactStore` that keeps staged and held content in memory.
///
/// Content is real bytes, so describing computes the same fingerprint the
/// platform store would, and the duplicate policy sees genuine byte
/// identity. The double records adoptions and removals, can be made to fail
/// each operation on demand, and exposes hooks that change held content
/// behind the library's back — the missing, truncated, and orphaned cases a
/// real directory can drift into.
final class SyntheticLibraryArtifactStore: LibraryArtifactStore, @unchecked Sendable {

    private let lock = NSLock()
    private var stagedContent: [ArtifactIdentifier: Data] = [:]
    private var heldContent: [ArtifactIdentifier: Data] = [:]
    private var adoptedIDs: [ArtifactIdentifier] = []
    private var removedIDs: [ArtifactIdentifier] = []
    private var describeError: (any Error)?
    private var adoptionError: (any Error)?
    private var removalError: (any Error)?

    // MARK: Staging and storage hooks

    /// Places `content` in staging under `id`, as the intake would.
    func stage(_ content: Data, as id: ArtifactIdentifier) {
        lock.withLock { stagedContent[id] = content }
    }

    /// Removes `id` from staging, as the intake's discard would.
    func unstage(_ id: ArtifactIdentifier) {
        lock.withLock { _ = stagedContent.removeValue(forKey: id) }
    }

    /// Places `content` directly in library storage, bypassing adoption —
    /// the shape of an artifact left behind by an interrupted admission.
    func hold(_ content: Data, as id: ArtifactIdentifier) {
        lock.withLock { heldContent[id] = content }
    }

    /// Removes `id` from library storage behind the library's back.
    func drop(_ id: ArtifactIdentifier) {
        lock.withLock { _ = heldContent.removeValue(forKey: id) }
    }

    /// Truncates the held content for `id` to `byteCount` bytes.
    func truncate(_ id: ArtifactIdentifier, to byteCount: Int) {
        lock.withLock {
            if let content = heldContent[id] {
                heldContent[id] = content.prefix(byteCount)
            }
        }
    }

    /// Makes every subsequent describe throw `error`.
    func failDescribing(with error: any Error) {
        lock.withLock { describeError = error }
    }

    /// Makes every subsequent adoption throw `error`, moving nothing.
    func failAdoption(with error: any Error) {
        lock.withLock { adoptionError = error }
    }

    /// Makes every subsequent removal throw `error`, removing nothing.
    func failRemoval(with error: any Error) {
        lock.withLock { removalError = error }
    }

    // MARK: Observation

    /// The identifiers currently staged.
    var staged: Set<ArtifactIdentifier> {
        lock.withLock { Set(stagedContent.keys) }
    }

    /// The identifiers currently held in library storage.
    var held: Set<ArtifactIdentifier> {
        lock.withLock { Set(heldContent.keys) }
    }

    /// The content held for `id`, if any.
    func heldContent(for id: ArtifactIdentifier) -> Data? {
        lock.withLock { heldContent[id] }
    }

    /// Every adoption performed, in order.
    var adopted: [ArtifactIdentifier] {
        lock.withLock { adoptedIDs }
    }

    /// Every removal performed, in order.
    var removed: [ArtifactIdentifier] {
        lock.withLock { removedIDs }
    }

    // MARK: LibraryArtifactStore

    func describeStagedArtifact(_ artifact: ArtifactIdentifier) throws -> ArtifactReference {
        try lock.withLock { () throws -> ArtifactReference in
            if let describeError {
                throw describeError
            }
            guard let content = stagedContent[artifact] else {
                throw ZynSignError.artifactNotAvailable(diagnosticDetail: "synthetic: nothing staged")
            }
            return LibraryFixtures.reference(to: content, artifactID: artifact)
        }
    }

    func adoptStagedArtifact(_ artifact: ArtifactIdentifier) throws {
        try lock.withLock {
            if let adoptionError {
                throw adoptionError
            }
            guard let content = stagedContent[artifact] else {
                throw ZynSignError.artifactNotAvailable(diagnosticDetail: "synthetic: nothing staged")
            }
            guard heldContent[artifact] == nil else {
                throw ZynSignError.libraryStorageFailure(diagnosticDetail: "synthetic: already held")
            }
            stagedContent.removeValue(forKey: artifact)
            heldContent[artifact] = content
            adoptedIDs.append(artifact)
        }
    }

    func removeArtifact(_ artifact: ArtifactIdentifier) throws {
        try lock.withLock {
            if let removalError {
                throw removalError
            }
            if heldContent.removeValue(forKey: artifact) != nil {
                removedIDs.append(artifact)
            }
        }
    }

    func observeArtifact(_ artifact: ArtifactIdentifier) -> StoredArtifactObservation {
        lock.withLock { () -> StoredArtifactObservation in
            if let content = heldContent[artifact] {
                return .present(byteCount: content.count)
            }
            return .absent
        }
    }

    func heldArtifactIdentifiers() throws -> Set<ArtifactIdentifier> {
        lock.withLock { Set(heldContent.keys) }
    }
}
