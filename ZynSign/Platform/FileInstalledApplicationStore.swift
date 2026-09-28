import Foundation

/// The file-backed implementation of `InstalledApplicationStore`: one
/// versioned catalog document in the user's container, replaced atomically
/// on every change.
///
/// Behaviour mirrors `FileSigningHistoryStore`. The catalog is bounded: when
/// `capacity` records are stored and a new one arrives, the least recently
/// updated record is discarded — after the new record is written, so a full
/// catalog can never refuse the user's newest confirmation. Pending
/// attempts are capped separately and are never trimmed implicitly; they
/// resolve only when the user resolves them. The catalog is private to the
/// application container and never leaves the device.
actor FileInstalledApplicationStore: InstalledApplicationStore {

    /// The schema version this build reads and writes.
    static let currentSchemaVersion = 1

    /// The location of the catalog file.
    let catalogLocation: URL

    /// The maximum number of records the catalog retains.
    let capacity: Int

    /// The maximum number of pending attempts retained. Deliberately small:
    /// attempts are a short-lived state, and a long list of them means the
    /// user has confirmations waiting.
    static let maximumAttempts = 20

    /// The state as last read from or written to disk.
    private var loadedState: LoadedState?

    /// What one catalog file holds.
    private struct LoadedState {
        var records: [InstalledApplicationRecord]
        var attempts: [PendingInstallationAttempt]
    }

    init(catalogLocation: URL, capacity: Int) {
        self.catalogLocation = catalogLocation
        self.capacity = capacity
    }

    // MARK: - Records

    func allRecords() async throws -> [InstalledApplicationRecord] {
        try loadedStateOrRead().records
    }

    func write(_ record: InstalledApplicationRecord) async throws {
        var state = try loadedStateOrRead()
        if let index = state.records.firstIndex(where: { $0.id == record.id }) {
            state.records[index] = record
        } else {
            state.records.insert(record, at: 0)
        }
        state.records.sort { $0.updatedAt > $1.updatedAt }
        if state.records.count > capacity {
            state.records.removeLast(state.records.count - capacity)
        }
        try persist(state)
    }

    func remove(recordWithID id: InstalledApplicationIdentifier) async throws {
        var state = try loadedStateOrRead()
        guard let index = state.records.firstIndex(where: { $0.id == id }) else { return }
        state.records.remove(at: index)
        try persist(state)
    }

    func removeAllRecords() async throws {
        var state = try loadedStateOrRead()
        state.records = []
        try persist(state)
    }

    // MARK: - Attempts

    func allAttempts() async throws -> [PendingInstallationAttempt] {
        try loadedStateOrRead().attempts
    }

    func write(_ attempt: PendingInstallationAttempt) async throws {
        var state = try loadedStateOrRead()
        if let index = state.attempts.firstIndex(where: { $0.id == attempt.id }) {
            state.attempts[index] = attempt
        } else {
            state.attempts.append(attempt)
        }
        state.attempts.sort { $0.startedAt < $1.startedAt }
        if state.attempts.count > Self.maximumAttempts {
            state.attempts.removeFirst(state.attempts.count - Self.maximumAttempts)
        }
        try persist(state)
    }

    func removeAttempt(withID id: InstallationEventIdentifier) async throws {
        var state = try loadedStateOrRead()
        guard let index = state.attempts.firstIndex(where: { $0.id == id }) else { return }
        state.attempts.remove(at: index)
        try persist(state)
    }

    // MARK: - Measurement

    func storedByteCount() async -> Int? {
        guard let values = try? catalogLocation.resourceValues(forKeys: [.fileSizeKey]) else { return nil }
        return values.fileSize
    }

    // MARK: - Storage helpers

    private func loadedStateOrRead() throws -> LoadedState {
        if let loadedState { return loadedState }
        let state = try Self.readCatalog(at: catalogLocation)
        loadedState = state
        return state
    }

    private func persist(_ state: LoadedState) throws {
        try Self.writeCatalog(state, to: catalogLocation)
        loadedState = state
    }

    private struct Envelope: Codable {
        var schemaVersion: Int
        var records: [InstalledApplicationRecord]
        var attempts: [PendingInstallationAttempt]
    }

    private static func readCatalog(at location: URL) throws -> LoadedState {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: location.path, isDirectory: &isDirectory) else {
            return LoadedState(records: [], attempts: [])
        }
        guard !isDirectory.boolValue else {
            throw ZynSignError.installedApplicationCatalogUnreadable(
                diagnosticDetail: "The installed-applications location is a directory rather than a file."
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: location)
        } catch {
            throw ZynSignError.installedApplicationStorageFailure(
                diagnosticDetail: "The installed-applications records could not be read.",
                underlyingError: error
            )
        }
        let envelope: Envelope
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch {
            throw ZynSignError.installedApplicationCatalogUnreadable(
                diagnosticDetail: "The installed-applications records are not a catalog this build recognises.",
                underlyingError: error
            )
        }
        guard envelope.schemaVersion <= currentSchemaVersion else {
            throw ZynSignError.installedApplicationCatalogUnreadable(
                diagnosticDetail: "The installed-applications records declare schema version \(envelope.schemaVersion); this build reads up to version \(currentSchemaVersion)."
            )
        }
        var seenRecords = Set<InstalledApplicationIdentifier>()
        for record in envelope.records {
            guard seenRecords.insert(record.id).inserted else {
                throw ZynSignError.installedApplicationCatalogUnreadable(
                    diagnosticDetail: "The installed-applications records contain record id '\(record.id)' more than once."
                )
            }
        }
        var seenAttempts = Set<InstallationEventIdentifier>()
        for attempt in envelope.attempts {
            guard seenAttempts.insert(attempt.id).inserted else {
                throw ZynSignError.installedApplicationCatalogUnreadable(
                    diagnosticDetail: "The installed-applications records contain attempt id '\(attempt.id)' more than once."
                )
            }
        }
        // Records come back most recently updated first; attempts oldest
        // first, matching the ports' documented orders.
        let records = envelope.records.sorted { $0.updatedAt > $1.updatedAt }
        let attempts = envelope.attempts.sorted { $0.startedAt < $1.startedAt }
        return LoadedState(records: records, attempts: attempts)
    }

    private static func writeCatalog(_ state: LoadedState, to location: URL) throws {
        let envelope = Envelope(
            schemaVersion: currentSchemaVersion,
            records: state.records.sorted { $0.updatedAt > $1.updatedAt },
            attempts: state.attempts.sorted { $0.startedAt < $1.startedAt }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(envelope)
        } catch {
            throw ZynSignError.installedApplicationStorageFailure(
                diagnosticDetail: "The installed-applications records could not be encoded.",
                underlyingError: error
            )
        }
        do {
            try FileManager.default.createDirectory(
                at: location.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw ZynSignError.installedApplicationStorageFailure(
                diagnosticDetail: "The installed-applications directory could not be created.",
                underlyingError: error
            )
        }
        do {
            try data.write(to: location, options: [.atomic])
        } catch {
            throw ZynSignError.installedApplicationStorageFailure(
                diagnosticDetail: "The installed-applications records could not be written.",
                underlyingError: error
            )
        }
    }
}
