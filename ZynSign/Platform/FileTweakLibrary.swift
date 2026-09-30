import Foundation

/// The file-backed tweak library: a versioned record catalog plus one file
/// per payload, all under a single library directory.
///
/// Behaviour mirrors the other file-backed stores: lazy cached load, atomic
/// catalog replacement, and fail-closed reads — a damaged catalog is
/// reported as unreadable rather than reset. Payload bytes are named by the
/// record identifier, so a record and its bytes can never be confused with
/// another pair.
final class FileTweakLibrary: TweakLibraryStore, TweakPayloadStorage, @unchecked Sendable {

    /// The schema version this build reads and writes.
    static let currentSchemaVersion = 1

    private struct CatalogDocument: Codable {
        let schemaVersion: Int
        var records: [TweakDescriptor]
    }

    private let directory: URL
    private var cached: [TweakDescriptor]?
    private let access = NSLock()

    /// Creates the library rooted at `directory`, which holds `catalog.json`
    /// and a `Payloads` subdirectory.
    init(directory: URL) {
        self.directory = directory
    }

    private var catalogURL: URL { directory.appendingPathComponent("catalog.json") }
    private var payloadsDirectory: URL { directory.appendingPathComponent("Payloads", isDirectory: true) }

    private func ensureDirectories() throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if !manager.fileExists(atPath: payloadsDirectory.path) {
            try manager.createDirectory(at: payloadsDirectory, withIntermediateDirectories: true)
        }
    }

    private func loadedOrRead() throws -> [TweakDescriptor] {
        if let cached { return cached }
        let manager = FileManager.default
        guard manager.fileExists(atPath: catalogURL.path) else {
            cached = []
            return []
        }
        do {
            let data = try Data(contentsOf: catalogURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let document = try decoder.decode(CatalogDocument.self, from: data)
            guard document.schemaVersion == Self.currentSchemaVersion else {
                throw ZynSignError.tweakLibraryCatalogUnsupported(
                    diagnosticDetail: "The tweak library catalog declares schema version \(document.schemaVersion)."
                )
            }
            let sorted = document.records.sorted { $0.addedAt > $1.addedAt }
            cached = sorted
            return sorted
        } catch let error as ZynSignError {
            throw error
        } catch {
            throw ZynSignError.tweakLibraryCatalogUnreadable(
                diagnosticDetail: "The tweak library catalog could not be read.",
                underlyingError: error
            )
        }
    }

    private func persist(_ records: [TweakDescriptor]) throws {
        try ensureDirectories()
        let document = CatalogDocument(schemaVersion: Self.currentSchemaVersion, records: records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)
        let temporary = directory.appendingPathComponent(".catalog-\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        _ = try? FileManager.default.replaceItemAt(catalogURL, withItemAt: temporary)
        if FileManager.default.fileExists(atPath: catalogURL.path) == false {
            try FileManager.default.moveItem(at: temporary, to: catalogURL)
        } else {
            try? FileManager.default.removeItem(at: temporary)
        }
        cached = records
    }

    // MARK: - TweakLibraryStore

    func all() throws -> [TweakDescriptor] {
        access.lock()
        defer { access.unlock() }
        return try loadedOrRead()
    }

    func upsert(_ descriptor: TweakDescriptor) throws {
        access.lock()
        defer { access.unlock() }
        var records = try loadedOrRead()
        records.removeAll { $0.id == descriptor.id }
        records.append(descriptor)
        records.sort { $0.addedAt > $1.addedAt }
        try persist(records)
    }

    func remove(id: UUID) throws {
        access.lock()
        defer { access.unlock() }
        var records = try loadedOrRead()
        let before = records.count
        records.removeAll { $0.id == id }
        guard records.count != before else { return }
        try persist(records)
    }

    func findByFingerprint(sha256Hex: String) throws -> [TweakDescriptor] {
        try all().filter { $0.sha256Hex == sha256Hex }
    }

    // MARK: - TweakPayloadStorage

    func store(_ data: Data, id: UUID) throws {
        try ensureDirectories()
        try data.write(to: payloadURL(for: id), options: .atomic)
    }

    func payload(for id: UUID) throws -> Data? {
        let url = payloadURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func removePayload(id: UUID) throws {
        let url = payloadURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func payloadURL(for id: UUID) -> URL {
        payloadsDirectory.appendingPathComponent(id.uuidString + ".payload")
    }
}
