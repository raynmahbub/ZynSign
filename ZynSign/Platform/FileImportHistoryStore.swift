import Foundation

/// The platform implementation of `ImportHistoryStore`: one JSON document in
/// ZynSign's Application Support directory, newest entry first, bounded to
/// `capacity` entries.
///
/// The document is versioned like the signing history. A document written
/// by a newer build, or one that cannot be decoded, is reported as
/// unreadable rather than silently replaced; clearing the history is the
/// deliberate way to start over. Writes are atomic.
actor FileImportHistoryStore: ImportHistoryStore {

    /// The schema version this build writes and the newest it reads.
    static let currentSchemaVersion = 1

    let location: URL
    let capacity: Int
    private var loadedEntries: [ImportHistoryEntry]?

    init(location: URL, capacity: Int = 100) {
        self.location = location
        self.capacity = max(1, capacity)
    }

    func allEntries() throws -> [ImportHistoryEntry] {
        try loadedOrRead()
    }

    func record(_ entry: ImportHistoryEntry) throws {
        var entries = try loadedOrRead()
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        try persist(entries)
    }

    func remove(entryWithID id: ImportBatchIdentifier) throws {
        var entries = try loadedOrRead()
        guard entries.contains(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        try persist(entries)
    }

    func clear() throws {
        try persist([])
    }

    // MARK: - Storage

    private struct Envelope: Codable {
        var schemaVersion: Int
        var entries: [ImportHistoryEntry]
    }

    private func loadedOrRead() throws -> [ImportHistoryEntry] {
        if let loadedEntries { return loadedEntries }
        let entries = try Self.read(at: location)
        loadedEntries = entries
        return entries
    }

    private func persist(_ entries: [ImportHistoryEntry]) throws {
        let ordered = Array(Self.newestFirst(entries).prefix(capacity))
        try Self.write(ordered, to: location)
        loadedEntries = ordered
    }

    private static func newestFirst(_ entries: [ImportHistoryEntry]) -> [ImportHistoryEntry] {
        entries.sorted { lhs, rhs in
            if lhs.finishedAt != rhs.finishedAt {
                return lhs.finishedAt > rhs.finishedAt
            }
            return lhs.id.rawValue < rhs.id.rawValue
        }
    }

    static func read(at location: URL) throws -> [ImportHistoryEntry] {
        guard FileManager.default.fileExists(atPath: location.path) else {
            return []
        }
        let data: Data
        do {
            data = try Data(contentsOf: location)
        } catch {
            throw unreadable("The import history could not be read.", error)
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw unreadable("The import history is not a document this build recognises.", error)
        }
        guard envelope.schemaVersion <= currentSchemaVersion else {
            throw unreadable("The import history declares schema version \(envelope.schemaVersion).", nil)
        }
        return newestFirst(envelope.entries)
    }

    static func write(_ entries: [ImportHistoryEntry], to location: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(Envelope(schemaVersion: currentSchemaVersion, entries: entries))
            try FileManager.default.createDirectory(
                at: location.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: location, options: .atomic)
        } catch {
            throw ZynSignError(
                category: .storageFailure,
                userMessage: "The import history could not be saved.",
                diagnosticDetail: "Writing the import history failed.",
                underlyingError: error
            )
        }
    }

    private static func unreadable(_ detail: String, _ error: (any Error)?) -> ZynSignError {
        ZynSignError(
            category: .storageFailure,
            userMessage: "The import history could not be read.",
            diagnosticDetail: detail,
            underlyingError: error
        )
    }
}
