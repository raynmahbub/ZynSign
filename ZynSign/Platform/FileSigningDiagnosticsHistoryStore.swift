import Foundation

/// A versioned, bounded, on-device journal of codes and counts only. Profile
/// bytes, paths, identifiers from packages, certificates and technical text
/// are not encoded. Writes replace the document atomically. No file is made
/// until the first scan is stored.
actor FileSigningDiagnosticsHistoryStore: SigningDiagnosticsHistoryStore {
    static let schemaVersion = 2
    static let maximumJournalBytes = 2 * 1_024 * 1_024

    let location: URL
    let capacityPerApp: Int
    let totalCapacity: Int
    private var loaded: [SigningDiagnosticSnapshot]?
    /// A scan already in flight when an app is deleted must not recreate its
    /// journal entries after library removal. Record UUIDs are never reused.
    private var removedRecordIDs: Set<String> = []

    init(location: URL, capacityPerApp: Int = 10, totalCapacity: Int = 1_000) {
        self.location = location
        self.capacityPerApp = max(1, min(capacityPerApp, 20))
        self.totalCapacity = max(1, min(totalCapacity, 1_000))
    }

    func recent(for recordID: ApplicationRecordIdentifier) async throws -> [SigningDiagnosticSnapshot] {
        try records().filter { $0.recordID == recordID.rawValue }
    }

    func append(_ snapshot: SigningDiagnosticSnapshot) async throws {
        guard !removedRecordIDs.contains(snapshot.recordID) else { return }
        var updated = try records()
        if let index = updated.firstIndex(where: { $0.recordID == snapshot.recordID }),
           updated[index].issueCodes == snapshot.issueCodes,
           updated[index].score == snapshot.score,
           updated[index].status == snapshot.status {
            // A repeated observation is still a scan: update its last seen
            // time, but retain room for earlier *different* results.
            updated.remove(at: index)
        }
        updated.insert(snapshot, at: 0)
        var perApp: [String: Int] = [:]
        updated = updated.filter { candidate in
            let count = perApp[candidate.recordID, default: 0]
            guard count < capacityPerApp else { return false }
            perApp[candidate.recordID] = count + 1
            return true
        }
        try persist(Array(updated.prefix(totalCapacity)))
    }

    func remove(for recordID: ApplicationRecordIdentifier) async throws {
        removedRecordIDs.insert(recordID.rawValue)
        let existing = try records()
        guard existing.contains(where: { $0.recordID == recordID.rawValue }) else { return }
        try persist(existing.filter { $0.recordID != recordID.rawValue })
    }

    private func records() throws -> [SigningDiagnosticSnapshot] {
        if let loaded { return loaded }
        let value = try Self.read(at: location)
        loaded = value
        return value
    }

    private func persist(_ values: [SigningDiagnosticSnapshot]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes: Data
        do { bytes = try encoder.encode(Envelope(version: Self.schemaVersion, records: values)) }
        catch { throw SigningDiagnosticHistoryError.unavailable }
        guard bytes.count <= Self.maximumJournalBytes else {
            throw SigningDiagnosticHistoryError.unavailable
        }
        do {
            try FileManager.default.createDirectory(
                at: location.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try bytes.write(to: location, options: [.atomic])
        } catch {
            throw SigningDiagnosticHistoryError.unavailable
        }
        loaded = values
    }

    private struct Envelope: Codable {
        let version: Int
        let records: [SigningDiagnosticSnapshot]
    }

    static func read(at location: URL) throws -> [SigningDiagnosticSnapshot] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: location.path, isDirectory: &isDirectory) else { return [] }
        guard !isDirectory.boolValue else { throw SigningDiagnosticHistoryError.unavailable }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
            guard let size = attributes[.size] as? NSNumber, size.intValue <= maximumJournalBytes else {
                throw SigningDiagnosticHistoryError.unavailable
            }
            let bytes = try Data(contentsOf: location)
            guard bytes.count <= maximumJournalBytes else { throw SigningDiagnosticHistoryError.unavailable }
            let document = try JSONDecoder().decode(Envelope.self, from: bytes)
            guard document.version == schemaVersion,
                  document.records.count <= 1_000,
                  document.records.allSatisfy({
                      UUID(uuidString: $0.recordID) != nil &&
                      $0.score >= 0 && $0.score <= 100 &&
                      $0.issueCodes.count <= SigningDiagnosticCode.allCases.count &&
                      $0.warningCount >= 0 && $0.errorCount >= 0 &&
                      $0.warningCount + $0.errorCount <= $0.issueCodes.count
                  }),
                  Set(document.records.map(\.scanID)).count == document.records.count else {
                throw SigningDiagnosticHistoryError.unavailable
            }
            // Persisted order is observation order, including equal dates or
            // a device whose clock moved backwards between scans.
            return document.records
        } catch {
            // Neither the path nor the decoder's input-specific error is
            // exposed to presentation or a diagnostic issue.
            throw SigningDiagnosticHistoryError.unavailable
        }
    }
}

enum SigningDiagnosticHistoryError: Error {
    case unavailable
}
