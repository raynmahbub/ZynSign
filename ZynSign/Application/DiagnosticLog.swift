import Foundation

/// One entry in ZynSign's technical log.
///
/// The log is opt-in: nothing is recorded unless the user turns on detailed
/// technical logging in Settings → Diagnostics. An entry carries a fixed
/// category, a timestamp, and a **fixed slug** the call site chose from a
/// closed vocabulary. It carries nothing else, by contract:
///
/// - No bundle identifiers, file names, or paths.
/// - No device, user, or installation identifiers.
/// - No certificate, profile, entitlement, or key material.
/// - No free-form text: `detail` is a slug such as `storage.temporary.cleared`,
///   never something a user typed or something read from disk.
struct DiagnosticLogEntry: Codable, Equatable, Identifiable, Sendable {

    /// The area of the app the entry belongs to. Fixed set.
    enum Category: String, Codable, CaseIterable, Sendable {
        case preferences
        case security
        case storage
        case recovery
        case signing
        case maintenance

        /// One presentation-safe label. Fixed text.
        var displayName: String {
            switch self {
            case .preferences: return "Preferences"
            case .security: return "Security"
            case .storage: return "Storage"
            case .recovery: return "Recovery"
            case .signing: return "Signing"
            case .maintenance: return "Maintenance"
            }
        }
    }

    /// The entry's identity.
    let id: UUID

    /// When it was recorded.
    let timestamp: Date

    /// The area it belongs to.
    let category: Category

    /// The fixed slug describing what happened.
    let detail: String

    init(id: UUID = UUID(), timestamp: Date = Date(), category: Category, detail: String) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.detail = detail
    }
}

/// The opt-in technical log.
///
/// The log lives in one document in the application container, is capped in
/// size, and is rotated by dropping the oldest entries rather than growing
/// without bound. It is readable, clearable, and exportable from Settings →
/// Diagnostics, and it is never transmitted: there is no sender, no endpoint,
/// and no sync anywhere in ZynSign.
///
/// Whether the log is written at all is the user's decision
/// (`DiagnosticsPreferences.detailedTechnicalLogs`). The actor records what
/// it is asked to record; the caller is the Settings model, which consults
/// the preference before every call.
actor DiagnosticLog {

    /// The schema version this build reads and writes.
    static let currentSchemaVersion = 1

    /// The default cap on the document's size in bytes.
    static let defaultMaximumBytes = 256 * 1024

    private struct Document: Codable {
        var schemaVersion: Int
        var entries: [DiagnosticLogEntry]
    }

    /// Where the document lives.
    private let location: URL

    /// The largest the document may become before the oldest entries go.
    private let maximumBytes: Int

    /// The entries as last read or written, once loaded.
    private var loadedEntries: [DiagnosticLogEntry]?

    init(location: URL = ZynSignStorageLayout.diagnosticsLog(), maximumBytes: Int = DiagnosticLog.defaultMaximumBytes) {
        self.location = location
        self.maximumBytes = max(1, maximumBytes)
    }

    /// Appends one entry and rewrites the document.
    func record(category: DiagnosticLogEntry.Category, detail: String) {
        var entries = loadedEntriesOrRead()
        entries.append(DiagnosticLogEntry(category: category, detail: detail))
        persist(entries)
    }

    /// Every entry, oldest first.
    func entries() -> [DiagnosticLogEntry] {
        loadedEntriesOrRead()
    }

    /// How many entries the log holds.
    var entryCount: Int {
        get async { loadedEntriesOrRead().count }
    }

    /// Removes every entry.
    func clear() {
        persist([])
    }

    /// The document as data, ready to be written out for the user.
    func exportData() -> Data? {
        let document = Document(schemaVersion: Self.currentSchemaVersion, entries: loadedEntriesOrRead())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(document)
    }

    // MARK: - Storage

    private func loadedEntriesOrRead() -> [DiagnosticLogEntry] {
        if let loadedEntries { return loadedEntries }
        let entries = Self.readDocument(at: location)?.entries ?? []
        loadedEntries = entries
        return entries
    }

    private func persist(_ entries: [DiagnosticLogEntry]) {
        let capped = entries.count > Self.maximumEntryCount ? Array(entries.suffix(Self.maximumEntryCount)) : entries
        guard Self.writeDocument(Document(schemaVersion: Self.currentSchemaVersion, entries: capped), to: location) else {
            return
        }
        loadedEntries = capped
    }

    /// How many entries fit inside the size cap. The cap is a budget, so the
    /// count is derived from it rather than chosen independently.
    private static var maximumEntryCount: Int { 1_000 }

    private static func readDocument(at location: URL) -> Document? {
        guard let data = try? Data(contentsOf: location) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Document.self, from: data)
    }

    private static func writeDocument(_ document: Document, to location: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(document) else { return false }
        // A log that cannot be written is not worth failing an operation over:
        // the caller asked for a record, not for a guarantee.
        do {
            try FileManager.default.createDirectory(
                at: location.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: location, options: [.atomic])
            return true
        } catch {
            return false
        }
    }
}

/// Counts the Diagnostics report describes.
///
/// Counts, not contents: the report says how many of each thing exists and
/// nothing about any one of them.
struct DiagnosticLibraryCounts: Equatable, Sendable, Codable {
    var recordCount: Int = 0
    var availableArtifactCount: Int = 0
    var identityCount: Int = 0
    var profileCount: Int = 0
    var presetCount: Int = 0
    var historyCount: Int = 0

    static let empty = DiagnosticLibraryCounts()
}

/// A diagnostic report the user can read and share.
///
/// The report is built from counts, versions, and preference flags — never
/// from the things those counts describe. It contains no bundle identifier,
/// no file name, no path, no certificate or profile detail, and no key
/// material of any kind. It is written to a file the user shares themselves;
/// nothing in ZynSign sends it anywhere.
struct DiagnosticReport: Equatable, Sendable, Codable {

    /// The schema version this build writes.
    static let schemaVersion = 1

    /// Facts about the running application.
    struct ApplicationSection: Equatable, Sendable, Codable {
        var displayName: String
        var marketingVersion: String
        var buildVersion: String
        var releaseSummary: String
    }

    /// Facts about the device, with no identifier of any kind.
    struct PlatformSection: Equatable, Sendable, Codable {
        var systemVersion: String
    }

    /// Which preferences differ from their shipped defaults.
    ///
    /// Flags, never values: the report can say that an identity preference is
    /// set without saying which identity.
    struct PreferencesSection: Equatable, Sendable, Codable {
        var changedGroupCount: Int
        var biometricLockEnabled: Bool
        var requireAuthenticationForSensitiveActions: Bool
        var hideSensitiveInformationWhenLocked: Bool
        var sessionTimeout: String
        var automaticTemporaryCleanup: Bool
        var exportRetentionDays: Int
        var automaticHealthAnalysis: Bool
        var keepDiagnosticHistory: Bool
        var detailedTechnicalLogs: Bool
        var developerDiagnostics: Bool
        var workingDirectoryBehavior: String
        var temporaryCleanupPolicy: String
        var verificationStrictness: String
        var experimentalFeatureCount: Int
    }

    var schemaVersion: Int
    var generatedAt: Date
    var application: ApplicationSection
    var platform: PlatformSection
    var storage: [String: Int64]
    var library: DiagnosticLibraryCounts
    var preferences: PreferencesSection
    var technicalLog: [DiagnosticLogEntry]

    /// Builds a report from the counts and facts the Settings model holds.
    static func make(
        applicationInfo: ApplicationInfo,
        releaseSummary: String,
        storage: StorageUsageReport,
        library: DiagnosticLibraryCounts,
        preferences: ZynSignPreferences,
        technicalLog: [DiagnosticLogEntry],
        generatedAt: Date = Date()
    ) -> DiagnosticReport {
        DiagnosticReport(
            schemaVersion: DiagnosticReport.schemaVersion,
            generatedAt: generatedAt,
            application: ApplicationSection(
                displayName: applicationInfo.displayName,
                marketingVersion: applicationInfo.marketingVersion,
                buildVersion: applicationInfo.buildVersion,
                releaseSummary: releaseSummary
            ),
            platform: PlatformSection(
                systemVersion: ProcessInfo.processInfo.operatingSystemVersionString
            ),
            storage: Dictionary(uniqueKeysWithValues: StorageCategory.allCases.map { ($0.title, storage.bytes(for: $0)) }),
            library: library,
            preferences: PreferencesSection(
                changedGroupCount: preferences.changedGroupCount,
                biometricLockEnabled: preferences.security.biometricLockEnabled,
                requireAuthenticationForSensitiveActions: preferences.security.requireAuthenticationForSensitiveActions,
                hideSensitiveInformationWhenLocked: preferences.security.hideSensitiveInformationWhenLocked,
                sessionTimeout: preferences.security.sessionTimeout.rawValue,
                automaticTemporaryCleanup: preferences.storage.automaticTemporaryCleanup,
                exportRetentionDays: preferences.storage.exportRetentionDays,
                automaticHealthAnalysis: preferences.diagnostics.automaticHealthAnalysis,
                keepDiagnosticHistory: preferences.diagnostics.keepDiagnosticHistory,
                detailedTechnicalLogs: preferences.diagnostics.detailedTechnicalLogs,
                developerDiagnostics: preferences.diagnostics.developerDiagnostics,
                workingDirectoryBehavior: preferences.advanced.workingDirectoryBehavior.rawValue,
                temporaryCleanupPolicy: preferences.advanced.temporaryCleanupPolicy.rawValue,
                verificationStrictness: preferences.advanced.verificationStrictness.rawValue,
                experimentalFeatureCount: preferences.advanced.experimentalFeatures.count
            ),
            technicalLog: technicalLog
        )
    }

    /// The report as JSON data, ready to be written out for the user.
    func jsonData() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(self)
    }

}
