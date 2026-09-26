import Foundation

/// The file-backed implementation of `PreferencesStore`: one versioned
/// document in the application container, replaced atomically on every change.
///
/// Behaviour mirrors the other file-backed stores in the application:
///
/// - **Load once, keep in memory.** The document is read during construction,
///   so reading a preference is a property access rather than a file read —
///   the Settings area opens instantly, and nothing recomputes while the user
///   browses it.
/// - **Write whole, atomically.** A change writes the entire document to a
///   temporary file and renames it into place, so an interrupted write can
///   never leave half a preference behind.
/// - **Never fail on read.** A missing, unreadable, or damaged document
///   becomes shipped defaults, and the reason is kept for the Diagnostics
///   area. Preferences are configuration; they must not be able to stop the
///   application launching.
/// - **Migrate once.** Values an earlier version kept in `UserDefaults` are
///   seeded the first time no document exists, written out immediately, and
///   then removed from `UserDefaults` so there is never a second source of
///   truth for a setting this version owns.
@MainActor
final class FilePreferencesStore: PreferencesStore {

    /// The schema version this build reads and writes.
    static let currentSchemaVersion = ZynSignPreferences.schemaVersion

    /// The document envelope. The preferences live inside an envelope so the
    /// schema version travels with them.
    private struct Document: Codable {
        var schemaVersion: Int
        var preferences: ZynSignPreferences
    }

    /// The location of the document.
    let location: URL

    /// Where the legacy `UserDefaults` values are read from and cleared.
    /// `nil` disables migration, which is what tests and previews use.
    private let legacyDefaults: UserDefaults?

    /// The preferences as last read from or written to the document.
    private var cached: ZynSignPreferences

    /// Whether this construction seeded the document from legacy values.
    private(set) var didMigrateLegacyValues = false

    /// Why the stored document could not be read, when it could not. Kept for
    /// the Diagnostics area; never shown as a failure the user caused.
    private(set) var lastReadError: ZynSignError?

    /// Loads the stored document, migrating legacy values when there is no
    /// document to read.
    init(location: URL, legacyDefaults: UserDefaults? = .standard) {
        self.location = location
        self.legacyDefaults = legacyDefaults

        switch Self.readDocument(at: location) {
        case .success(let document):
            cached = document.preferences
        case .failure(let error):
            cached = ZynSignPreferences.shippedDefault
            lastReadError = error
        }

        // A document that could not be read is not evidence that the user has
        // no preferences, so legacy values are only consulted when the file is
        // genuinely absent.
        guard lastReadError == nil, !Self.documentExists(at: location) else { return }

        let legacy = legacyDefaults.map { LegacyPreferenceValues(defaults: $0) }
        guard let legacy, !legacy.isEmpty else { return }
        cached = ZynSignPreferences.migrated(from: legacy)
        didMigrateLegacyValues = true
        // Write the migrated document now, so the migration happens exactly
        // once and the legacy keys can be cleared without losing anything. If
        // it cannot be written, the legacy values are left where they are and
        // the next launch tries again.
        do {
            try save(cached)
            clearLegacyValues()
        } catch {
            didMigrateLegacyValues = false
        }
    }

    var snapshot: ZynSignPreferences { cached }

    func save(_ preferences: ZynSignPreferences) throws {
        try Self.writeDocument(
            Document(schemaVersion: Self.currentSchemaVersion, preferences: preferences),
            to: location
        )
        cached = preferences
    }

    func reset() throws {
        try save(ZynSignPreferences.shippedDefault)
    }

    /// Removes the legacy keys this version now owns. Called only after the
    /// migrated document has been written.
    private func clearLegacyValues() {
        guard let legacyDefaults else { return }
        legacyDefaults.removeObject(forKey: LegacyPreferenceValues.appearanceKey)
        legacyDefaults.removeObject(forKey: LegacyPreferenceValues.onboardingKey)
    }

    // MARK: - Document

    private static func documentExists(at location: URL) -> Bool {
        FileManager.default.fileExists(atPath: location.path)
    }

    private static func readDocument(at location: URL) -> Result<Document, ZynSignError> {
        guard documentExists(at: location) else {
            return .success(Document(schemaVersion: currentSchemaVersion, preferences: .shippedDefault))
        }
        let data: Data
        do {
            data = try Data(contentsOf: location)
        } catch {
            return .failure(.preferencesUnreadable(
                diagnosticDetail: "The preferences document could not be read.",
                underlyingError: error
            ))
        }
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            return .failure(.preferencesUnreadable(
                diagnosticDetail: "The preferences document is not a document this build recognises.",
                underlyingError: error
            ))
        }
        return .success(document)
    }

    private static func writeDocument(_ document: Document, to location: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(document)
        } catch {
            throw ZynSignError.preferencesStorageFailure(
                diagnosticDetail: "The preferences document could not be encoded.",
                underlyingError: error
            )
        }
        do {
            try FileManager.default.createDirectory(
                at: location.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw ZynSignError.preferencesStorageFailure(
                diagnosticDetail: "The preferences directory could not be created.",
                underlyingError: error
            )
        }
        do {
            try data.write(to: location, options: [.atomic])
        } catch {
            throw ZynSignError.preferencesStorageFailure(
                diagnosticDetail: "The preferences document could not be written.",
                underlyingError: error
            )
        }
    }
}
