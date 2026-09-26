import Foundation
import XCTest
@testable import ZynSign

// MARK: - Organization store double

/// A `LibraryOrganizationStore` that keeps the organization in memory and
/// can be driven into deterministic load and save failures.
///
/// It exists so the organizer and the library screen model can be
/// exercised without a filesystem, and so a failed save — the case that
/// must leave the organizer unchanged — can be produced on demand.
final class InMemoryLibraryOrganizationStore: LibraryOrganizationStore, @unchecked Sendable {

    private let lock = NSLock()
    private var stored: LibraryOrganization
    private var loadError: (any Error)?
    private var saveError: (any Error)?
    private var loads = 0
    private var saves = 0

    init(organization: LibraryOrganization = .empty) {
        self.stored = organization
    }

    /// Makes every subsequent load throw `error`, or stops failing when
    /// `error` is `nil`.
    func failLoading(with error: (any Error)?) {
        lock.withLock { loadError = error }
    }

    /// Makes every subsequent save throw `error`, or stops failing when
    /// `error` is `nil`.
    func failSaving(with error: (any Error)?) {
        lock.withLock { saveError = error }
    }

    /// The organization last saved (or the initial one).
    var organization: LibraryOrganization {
        lock.withLock { stored }
    }

    /// How many loads were attempted.
    var loadCount: Int {
        lock.withLock { loads }
    }

    /// How many saves succeeded.
    var saveCount: Int {
        lock.withLock { saves }
    }

    func loadOrganization() throws -> LibraryOrganization {
        try lock.withLock { () throws -> LibraryOrganization in
            loads += 1
            if let loadError {
                throw loadError
            }
            return stored
        }
    }

    func saveOrganization(_ organization: LibraryOrganization) throws {
        try lock.withLock {
            if let saveError {
                throw saveError
            }
            stored = organization
            saves += 1
        }
    }
}

// MARK: - Signing journal double

/// A `SigningHistoryStore` holding records in memory, most recent first,
/// that can be made to fail reads.
actor InMemorySigningHistoryStore: SigningHistoryStore {

    private var stored: [SigningRecord]
    private var readError: (any Error)?

    init(records: [SigningRecord] = []) {
        self.stored = records.sorted(by: SigningRecord.sortByRecency)
    }

    nonisolated var capacity: Int { 500 }

    func failReads(with error: (any Error)?) {
        readError = error
    }

    func allRecords() async throws -> [SigningRecord] {
        if let readError {
            throw readError
        }
        return stored
    }

    func records(forPreset presetID: PresetIdentifier) async throws -> [SigningRecord] {
        stored.filter { $0.presetID == presetID }
    }

    func append(_ record: SigningRecord) async throws {
        stored.insert(record, at: 0)
        stored.sort(by: SigningRecord.sortByRecency)
    }

    func remove(recordWithID id: SigningRecordIdentifier) async throws {
        stored.removeAll { $0.id == id }
    }

    func clear() async throws {
        stored.removeAll()
    }

    func count() async throws -> Int {
        stored.count
    }
}

// MARK: - Archive reader provider double

/// An `ArtifactArchiveReaderProvider` that hands out a prepared reader per
/// artifact and counts how often each archive was opened, so caching can
/// be observed. An artifact without a prepared reader fails to open.
final class PerArtifactArchiveReaderProvider: ArtifactArchiveReaderProvider, @unchecked Sendable {

    private let lock = NSLock()
    private var readers: [ArtifactIdentifier: SyntheticArchiveReader]
    private var opens: [ArtifactIdentifier: Int] = [:]

    init(readers: [ArtifactIdentifier: SyntheticArchiveReader] = [:]) {
        self.readers = readers
    }

    /// How many times the archive for `artifact` was opened.
    func openCount(for artifact: ArtifactIdentifier) -> Int {
        lock.withLock { opens[artifact] ?? 0 }
    }

    func archiveReader(for artifact: ArtifactIdentifier) throws -> any ArchiveReader {
        try lock.withLock { () throws -> any ArchiveReader in
            opens[artifact, default: 0] += 1
            guard let reader = readers[artifact] else {
                throw ZynSignError.artifactNotAvailable(diagnosticDetail: "synthetic: no archive for the artifact")
            }
            return reader
        }
    }
}

// MARK: - Fixtures

/// Builds library organization, signing, and provenance values for the
/// advanced-library tests. Every value is synthetic.
enum LibraryOrganizationFixtures {

    /// A fixed "now" for window tests: one day after the fixtures' import
    /// date.
    static let now = LibraryFixtures.importDate.addingTimeInterval(86_400)

    /// An entry with an available artifact and the supplied values.
    static func entry(
        name: String?,
        bundleIdentifier: String = "com.example.synthetic",
        version: String? = "1.0",
        build: String? = "1",
        sourceFileName: String? = nil,
        byteCount: Int = 1_024,
        importedAt: Date = LibraryFixtures.importDate,
        isFavorite: Bool = false,
        availability: ArtifactAvailability = .available
    ) -> LibraryEntry {
        let base = LibraryFixtures.record(
            identity: LibraryFixtures.identity(
                bundleIdentifier: bundleIdentifier,
                displayName: name,
                shortVersion: version,
                build: build
            ),
            sourceFileName: sourceFileName,
            artifact: LibraryFixtures.reference(byteCount: byteCount),
            importedAt: importedAt
        )
        let record = isFavorite ? base.with(isFavorite: true, updatedAt: importedAt) : base
        return LibraryEntry(record: record, artifactAvailability: availability)
    }

    /// A successful signing of `record`, attributed by record identifier.
    static func signing(
        of record: ApplicationRecord,
        at date: Date,
        profileExpiresAt: Date? = nil,
        certificateExpiresAt: Date? = nil
    ) -> SigningRecord {
        SigningRecord(
            presetID: nil,
            certificateFingerprint: nil,
            sourceBundleIdentifier: record.bundleIdentifier.rawValue,
            sourceDisplayName: record.displayName,
            stoppingStage: "verification",
            errorCode: nil,
            outputFileName: "\(record.id.rawValue).ipa",
            outputByteCount: 2_048,
            startedAt: date,
            duration: 1,
            sourceRecordID: record.id.rawValue,
            profileExpiresAt: profileExpiresAt,
            certificateExpiresAt: certificateExpiresAt
        )
    }

    /// A successful signing recorded the way journal entries were before
    /// they named the library record: by bundle identifier only.
    static func legacySigning(bundleIdentifier: String, at date: Date) -> SigningRecord {
        SigningRecord(
            presetID: nil,
            certificateFingerprint: nil,
            sourceBundleIdentifier: bundleIdentifier,
            sourceDisplayName: nil,
            stoppingStage: "verification",
            errorCode: nil,
            outputFileName: "legacy.ipa",
            outputByteCount: 2_048,
            startedAt: date,
            duration: 1
        )
    }

    /// A failed signing of `record`.
    static func failedSigning(of record: ApplicationRecord, at date: Date) -> SigningRecord {
        SigningRecord(
            presetID: nil,
            certificateFingerprint: nil,
            sourceBundleIdentifier: record.bundleIdentifier.rawValue,
            sourceDisplayName: record.displayName,
            stoppingStage: "profile",
            errorCode: "invalidInput",
            outputFileName: nil,
            outputByteCount: nil,
            startedAt: date,
            duration: 1,
            sourceRecordID: record.id.rawValue
        )
    }

    /// The XML property list of a provisioning profile declaring a team.
    static func profilePropertyList(teamIdentifier: String, teamName: String?) -> Data {
        var body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        <key>Name</key><string>Synthetic Profile</string>
        <key>TeamIdentifier</key><array><string>\(teamIdentifier)</string></array>
        """
        if let teamName {
            body += "<key>TeamName</key><string>\(teamName)</string>\n"
        }
        body += "</dict>\n</plist>\n"
        return Data(body.utf8)
    }

    /// Profile bytes shaped like a signed container: opaque bytes around the
    /// property list, so extraction has to locate it.
    static func signedProfileBytes(teamIdentifier: String, teamName: String?) -> Data {
        var bytes = Data([0x30, 0x82, 0x0F, 0xA0, 0x06, 0x09])
        bytes.append(profilePropertyList(teamIdentifier: teamIdentifier, teamName: teamName))
        bytes.append(Data([0xA0, 0x82, 0x01, 0x00, 0x31, 0x00]))
        return bytes
    }

    /// Store metadata declaring a developer.
    static func storeMetadata(artistName: String) -> Data {
        let dictionary: [String: Any] = ["artistName": artistName, "itemName": "Synthetic"]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0) else {
            preconditionFailure("A literal dictionary must serialise as a property list.")
        }
        return data
    }

    /// A reader for a package carrying an embedded profile and/or store
    /// metadata.
    static func provenanceReader(profile: Data?, storeMetadata: Data?) -> SyntheticArchiveReader {
        var table = validPackageEntryTable()
        var content: [String: Data] = [:]
        if let profile {
            let path = "Payload/Example.app/embedded.mobileprovision"
            table.append(makeEntry(path, uncompressedSize: profile.count, compressedSize: profile.count))
            content[path] = profile
        }
        if let storeMetadata {
            table.append(makeEntry("iTunesMetadata.plist", uncompressedSize: storeMetadata.count, compressedSize: storeMetadata.count))
            content["iTunesMetadata.plist"] = storeMetadata
        }
        return SyntheticArchiveReader(entryTable: table, contentByPath: content)
    }
}
