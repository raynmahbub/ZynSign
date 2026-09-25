import Foundation

/// The file-backed implementation of `SigningHistoryStore`: a versioned
/// journal document in the user's container, replaced atomically on every
/// append.
///
/// Behaviour mirrors `FileApplicationRecordStore`. The journal is bounded:
/// when `capacity` records are stored and a new one arrives, the oldest
/// record is discarded. The journal is private to the application
/// container and never leaves the device.
actor FileSigningHistoryStore: SigningHistoryStore {

    /// The schema version this build reads and writes.
    static let currentSchemaVersion = 1

    /// The location of the journal file.
    let journalLocation: URL

    /// The maximum number of records the journal retains.
    let capacity: Int

    /// The records as last read from or written to the journal, in
    /// recency order (most recent first).
    private var loadedRecords: [SigningRecord]?

    init(journalLocation: URL, capacity: Int) {
        self.journalLocation = journalLocation
        self.capacity = capacity
    }

    func allRecords() async throws -> [SigningRecord] {
        try loadedRecordsOrRead()
    }

    func records(forPreset presetID: PresetIdentifier) async throws -> [SigningRecord] {
        try loadedRecordsOrRead().filter { $0.presetID == presetID }
    }

    func append(_ record: SigningRecord) async throws {
        var records = try loadedRecordsOrRead()
        records.insert(record, at: 0)
        if records.count > capacity {
            records = Array(records.prefix(capacity))
        }
        try persist(records)
    }

    func remove(recordWithID id: SigningRecordIdentifier) async throws {
        var records = try loadedRecordsOrRead()
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records.remove(at: index)
        try persist(records)
    }

    func clear() async throws {
        try persist([])
    }

    func count() async throws -> Int {
        try loadedRecordsOrRead().count
    }

    // MARK: - Storage helpers

    private func loadedRecordsOrRead() throws -> [SigningRecord] {
        if let loadedRecords { return loadedRecords }
        let records = try Self.readJournal(at: journalLocation)
        loadedRecords = records
        return records
    }

    private func persist(_ records: [SigningRecord]) throws {
        try Self.writeJournal(records, to: journalLocation)
        loadedRecords = records
    }

    private struct Envelope: Codable {
        var schemaVersion: Int
        var records: [SigningRecord]
    }

    static func readJournal(at location: URL) throws -> [SigningRecord] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: location.path, isDirectory: &isDirectory) else {
            return []
        }
        guard !isDirectory.boolValue else {
            throw ZynSignError.signingHistoryUnreadable(
                diagnosticDetail: "The signing history location is a directory rather than a file."
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: location)
        } catch {
            throw ZynSignError.signingHistoryStorageFailure(
                diagnosticDetail: "The signing history could not be read.",
                underlyingError: error
            )
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw ZynSignError.signingHistoryUnreadable(
                diagnosticDetail: "The signing history is not a journal document this build recognises.",
                underlyingError: error
            )
        }
        guard envelope.schemaVersion <= currentSchemaVersion else {
            throw ZynSignError.signingHistoryUnreadable(
                diagnosticDetail: "The signing history declares schema version \(envelope.schemaVersion); this build reads up to version \(currentSchemaVersion)."
            )
        }
        // Verify uniqueness of identifiers within the journal.
        var seen = Set<SigningRecordIdentifier>()
        for record in envelope.records {
            guard seen.insert(record.id).inserted else {
                throw ZynSignError.signingHistoryUnreadable(
                    diagnosticDetail: "The signing history records id '\(record.id)' more than once."
                )
            }
        }
        return envelope.records.sorted(by: SigningRecord.sortByRecency)
    }

    static func writeJournal(
        _ records: [SigningRecord],
        to location: URL
    ) throws {
        let envelope = Envelope(
            schemaVersion: currentSchemaVersion,
            records: records.sorted(by: SigningRecord.sortByRecency)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(envelope)
        } catch {
            throw ZynSignError.signingHistoryStorageFailure(
                diagnosticDetail: "The signing history could not be encoded.",
                underlyingError: error
            )
        }
        do {
            try FileManager.default.createDirectory(
                at: location.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw ZynSignError.signingHistoryStorageFailure(
                diagnosticDetail: "The signing history directory could not be created.",
                underlyingError: error
            )
        }
        do {
            try data.write(to: location, options: [.atomic])
        } catch {
            throw ZynSignError.signingHistoryStorageFailure(
                diagnosticDetail: "The signing history could not be written.",
                underlyingError: error
            )
        }
    }
}
