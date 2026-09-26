import Foundation

/// The file-backed implementation of `ExportRecordStore`: a versioned catalog
/// document in the user's container, replaced atomically on every change.
///
/// Behaviour mirrors `FileSigningHistoryStore`. The catalog is bounded by the
/// number of artifacts a person exports, so it keeps every record it is
/// given; nothing is discarded silently, and removal only happens when the
/// Export Center or the storage screen asks for it.
///
/// The catalog holds metadata only. The artifacts themselves live in export
/// storage, and the catalog records their file names rather than their
/// locations, so a catalog can never point outside the directory it is bound
/// to.
actor FileExportRecordStore: ExportRecordStore {

    /// The schema version this build reads and writes.
    static let currentSchemaVersion = 1

    /// The location of the catalog file.
    let catalogLocation: URL

    /// The records as last read from or written to the catalog, newest first.
    private var loadedRecords: [ExportRecord]?

    init(catalogLocation: URL) {
        self.catalogLocation = catalogLocation
    }

    func allRecords() async throws -> [ExportRecord] {
        try loadedRecordsOrRead()
    }

    func write(_ record: ExportRecord) async throws {
        var records = try loadedRecordsOrRead()
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        try persist(records)
    }

    func remove(recordWithID id: ExportIdentifier) async throws {
        var records = try loadedRecordsOrRead()
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records.remove(at: index)
        try persist(records)
    }

    func clear() async throws {
        try persist([])
    }

    // MARK: - Storage

    private func loadedRecordsOrRead() throws -> [ExportRecord] {
        if let loadedRecords { return loadedRecords }
        let records = try Self.readCatalog(at: catalogLocation)
        loadedRecords = records
        return records
    }

    private func persist(_ records: [ExportRecord]) throws {
        try Self.writeCatalog(records, to: catalogLocation)
        loadedRecords = records
    }

    private struct Envelope: Codable {
        var schemaVersion: Int
        var records: [ExportRecord]
    }

    /// Reads a catalog document, returning its records most recent first.
    ///
    /// Every inconsistency is a typed refusal rather than a silent repair: a
    /// version this build does not read, a record whose identifier appears
    /// twice, and a malformed document are all reported, so a catalog that
    /// cannot be trusted is never presented as if it could be.
    static func readCatalog(at location: URL) throws -> [ExportRecord] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: location.path, isDirectory: &isDirectory) else {
            return []
        }
        guard !isDirectory.boolValue else {
            throw ZynSignError.exportCatalogUnreadable(
                diagnosticDetail: "The export catalog location is a directory rather than a file."
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: location)
        } catch {
            throw ZynSignError.exportCatalogUnreadable(
                diagnosticDetail: "The export catalog could not be read.",
                underlyingError: error
            )
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw ZynSignError.exportCatalogUnreadable(
                diagnosticDetail: "The export catalog is not a document this build recognises.",
                underlyingError: error
            )
        }
        guard envelope.schemaVersion <= currentSchemaVersion else {
            throw ZynSignError.exportCatalogUnsupported(
                diagnosticDetail: "The export catalog declares schema version \(envelope.schemaVersion); this build reads up to version \(currentSchemaVersion)."
            )
        }
        var seen = Set<ExportIdentifier>()
        for record in envelope.records {
            guard seen.insert(record.id).inserted else {
                throw ZynSignError.exportCatalogUnreadable(
                    diagnosticDetail: "The export catalog records identifier '\(record.id.rawValue)' more than once."
                )
            }
        }
        return envelope.records.sorted(by: Self.sortByRecency)
    }

    /// Writes a catalog document, most recent first.
    static func writeCatalog(_ records: [ExportRecord], to location: URL) throws {
        let envelope = Envelope(
            schemaVersion: currentSchemaVersion,
            records: records.sorted(by: Self.sortByRecency)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(envelope)
        } catch {
            throw ZynSignError.exportStorageFailure(
                diagnosticDetail: "The export catalog could not be encoded.",
                underlyingError: error
            )
        }
        do {
            try FileManager.default.createDirectory(
                at: location.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw ZynSignError.exportStorageFailure(
                diagnosticDetail: "The export catalog directory could not be created.",
                underlyingError: error
            )
        }
        do {
            try data.write(to: location, options: [.atomic])
        } catch {
            throw ZynSignError.exportStorageFailure(
                diagnosticDetail: "The export catalog could not be written.",
                underlyingError: error
            )
        }
    }

    /// Most recent first, with the identifier as a deterministic tie-break so
    /// two listings of the same catalog always agree.
    static func sortByRecency(_ lhs: ExportRecord, _ rhs: ExportRecord) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id.rawValue < rhs.id.rawValue
    }
}
