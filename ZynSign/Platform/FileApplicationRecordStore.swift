import Foundation

/// The platform implementation of `ApplicationRecordStore`: a versioned
/// catalog file in application-owned storage, replaced atomically on every
/// change.
///
/// This is the persistence technology selected for library records, and the
/// reasons are recorded with the architecture. In short: the record set is a
/// small collection of flat values with no relationships and no query
/// pattern beyond "list" and "by identifier", so a single catalog document
/// read once and rewritten whole on each change is sufficient, uses nothing
/// beyond Foundation, works on any deployment target the project may still
/// choose, is testable against a temporary directory, and keeps its schema
/// version explicit. Replacing it — with a database-backed store, should the
/// requirements change — is a change in the composition root and this type.
///
/// Behaviour:
///
/// - **Lazy, cached load.** The catalog is read on the first operation and
///   kept in memory; every mutation writes the whole catalog and updates the
///   cache only after the write succeeded, so a failed write leaves both the
///   file and the cache as they were.
/// - **Atomic replacement.** The catalog is written to a temporary file and
///   renamed into place, so an interrupted write cannot leave a truncated
///   catalog behind.
/// - **Fail closed on damage.** A catalog that cannot be decoded, records a
///   version this build does not know, or carries a value the domain rejects
///   makes every operation fail with a typed error. The file is never reset,
///   truncated, or partially loaded; a mutation never proceeds over a
///   catalog that could not be read.
/// - **Single writer.** Access is serialised by the actor. The catalog is
///   private to the application container, and no other process writes it.
///
/// Nothing sensitive is stored. The catalog holds declared package metadata,
/// artifact references, inspection summaries, and timestamps — data the
/// architecture classifies as suitable for ordinary persistence — and no
/// other class of data passes through this type.
actor FileApplicationRecordStore: ApplicationRecordStore {

    /// The location of the catalog file. Its directory is created on the
    /// first write; nothing is created at construction time.
    let catalogLocation: URL

    /// The records as last read from or written to the catalog, keyed by
    /// identifier, once the catalog has been loaded.
    private var loadedRecords: [ApplicationRecordIdentifier: ApplicationRecord]?

    /// Creates a store over the catalog at `catalogLocation`, which need not
    /// exist yet. A missing catalog is an empty library.
    init(catalogLocation: URL) {
        self.catalogLocation = catalogLocation
    }

    // MARK: - ApplicationRecordStore

    func insert(_ record: ApplicationRecord) async throws {
        var records = try loadRecords()
        guard records[record.id] == nil else {
            throw ZynSignError.libraryRecordConflict(
                diagnosticDetail: "A record already carries identifier '\(record.id.rawValue)'."
            )
        }
        records[record.id] = record
        try persist(records)
    }

    func update(_ record: ApplicationRecord) async throws {
        var records = try loadRecords()
        guard records[record.id] != nil else {
            throw ZynSignError.libraryRecordNotFound(
                diagnosticDetail: "No record carries identifier '\(record.id.rawValue)', so there is nothing to update."
            )
        }
        records[record.id] = record
        try persist(records)
    }

    func record(withID id: ApplicationRecordIdentifier) async throws -> ApplicationRecord? {
        try loadRecords()[id]
    }

    func allRecords() async throws -> [ApplicationRecord] {
        try loadRecords().values.sorted(by: ApplicationRecord.libraryOrder)
    }

    func delete(recordWithID id: ApplicationRecordIdentifier) async throws {
        var records = try loadRecords()
        guard records.removeValue(forKey: id) != nil else {
            return
        }
        try persist(records)
    }

    // MARK: - Catalog access

    private func loadRecords() throws -> [ApplicationRecordIdentifier: ApplicationRecord] {
        if let loadedRecords {
            return loadedRecords
        }
        let records = try Self.readCatalog(at: catalogLocation)
        loadedRecords = records
        return records
    }

    private func persist(_ records: [ApplicationRecordIdentifier: ApplicationRecord]) throws {
        try Self.writeCatalog(records, to: catalogLocation)
        loadedRecords = records
    }

    /// Reads and validates the catalog at `location`. A missing file is an
    /// empty catalog; anything present must be a complete, current-version
    /// catalog whose every record the domain accepts.
    static func readCatalog(at location: URL) throws -> [ApplicationRecordIdentifier: ApplicationRecord] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: location.path, isDirectory: &isDirectory) else {
            return [:]
        }
        guard !isDirectory.boolValue else {
            throw ZynSignError.libraryCatalogUnreadable(
                diagnosticDetail: "The library catalog location is a directory rather than a file."
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: location)
        } catch {
            throw ZynSignError.libraryStorageFailure(
                diagnosticDetail: "The library catalog could not be read.",
                underlyingError: error
            )
        }

        let decoder = JSONDecoder()
        let envelope: LibraryCatalogDocument.VersionEnvelope
        do {
            envelope = try decoder.decode(LibraryCatalogDocument.VersionEnvelope.self, from: data)
        } catch {
            throw ZynSignError.libraryCatalogUnreadable(
                diagnosticDetail: "The library catalog is not a catalog document this build recognises.",
                underlyingError: error
            )
        }
        guard envelope.schemaVersion <= LibraryCatalogDocument.currentSchemaVersion else {
            throw ZynSignError.libraryCatalogUnsupported(
                diagnosticDetail: "The library catalog declares schema version \(envelope.schemaVersion); this build reads up to version \(LibraryCatalogDocument.currentSchemaVersion)."
            )
        }
        guard envelope.schemaVersion >= 1 else {
            throw ZynSignError.libraryCatalogUnreadable(
                diagnosticDetail: "The library catalog declares schema version \(envelope.schemaVersion), which no build of ZynSign has written."
            )
        }
        // Versions before the current one are converted on read, in the one
        // way the schema history defines: a version 1 document carries no
        // favourite marks, so its records read as not-favourite. The catalog
        // is written back in the current schema at its next mutation; a read
        // never rewrites the file.

        let document: LibraryCatalogDocument
        do {
            document = try decoder.decode(LibraryCatalogDocument.self, from: data)
        } catch {
            throw ZynSignError.libraryCatalogUnreadable(
                diagnosticDetail: "The library catalog's records could not be decoded.",
                underlyingError: error
            )
        }

        var records: [ApplicationRecordIdentifier: ApplicationRecord] = [:]
        for stored in document.records {
            let record = try stored.applicationRecord()
            guard records[record.id] == nil else {
                throw ZynSignError.libraryCatalogUnreadable(
                    diagnosticDetail: "The library catalog records identifier '\(record.id.rawValue)' more than once."
                )
            }
            records[record.id] = record
        }
        return records
    }

    /// Writes `records` as a current-version catalog at `location`,
    /// replacing any existing catalog atomically.
    static func writeCatalog(
        _ records: [ApplicationRecordIdentifier: ApplicationRecord],
        to location: URL
    ) throws {
        let document = LibraryCatalogDocument(
            records: records.values
                .sorted(by: ApplicationRecord.libraryOrder)
                .map { StoredApplicationRecord($0) }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(document)
        } catch {
            throw ZynSignError.libraryStorageFailure(
                diagnosticDetail: "The library catalog could not be encoded.",
                underlyingError: error
            )
        }

        do {
            try FileManager.default.createDirectory(
                at: location.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw ZynSignError.libraryStorageFailure(
                diagnosticDetail: "The library directory could not be created.",
                underlyingError: error
            )
        }

        do {
            try data.write(to: location, options: [.atomic])
        } catch {
            throw ZynSignError.libraryStorageFailure(
                diagnosticDetail: "The library catalog could not be written.",
                underlyingError: error
            )
        }
    }
}
