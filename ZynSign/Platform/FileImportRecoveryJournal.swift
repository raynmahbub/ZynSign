import Foundation

/// The platform implementation of `ImportRecoveryJournal`: a small JSON
/// document in ZynSign's Application Support directory listing the Import
/// Hub's unfinished items.
///
/// The journal holds names and identifiers only — never a file location, a
/// bookmark, or a security scope — so an interrupted import can resume only
/// from ZynSign's own working copy. An empty journal is represented by no
/// file at all. A journal that cannot be read is treated as empty: losing it
/// costs the user an explanation of what was interrupted, never data, and
/// the working copies it named are swept like any other leftover.
actor FileImportRecoveryJournal: ImportRecoveryJournal {

    /// The schema version this build writes and the newest it reads.
    static let currentSchemaVersion = 1

    let location: URL

    init(location: URL) {
        self.location = location
    }

    private struct Envelope: Codable {
        var schemaVersion: Int
        var records: [ImportRecoveryRecord]
    }

    func pendingRecords() throws -> [ImportRecoveryRecord] {
        guard let data = try? Data(contentsOf: location),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.schemaVersion <= Self.currentSchemaVersion else {
            return []
        }
        return envelope.records
    }

    func replace(with records: [ImportRecoveryRecord]) throws {
        guard !records.isEmpty else {
            if FileManager.default.fileExists(atPath: location.path) {
                try FileManager.default.removeItem(at: location)
            }
            return
        }
        let data = try JSONEncoder().encode(Envelope(schemaVersion: Self.currentSchemaVersion, records: records))
        try FileManager.default.createDirectory(
            at: location.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: location, options: .atomic)
    }
}
