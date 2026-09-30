import Foundation

/// Persistence for per-application protection policies.
///
/// Policies are keyed by the library record identifier's string form, so the
/// boundary never needs to know the identifier type the library uses.
protocol AppProtectionStore: Sendable {

    /// Every recorded policy, keyed by record identifier.
    func all() throws -> [String: AppProtectionPolicy]

    /// Records the policy for one record, replacing the previous one.
    func set(_ policy: AppProtectionPolicy, recordID: String) throws

    /// Removes the policy for one record, when present.
    func remove(recordID: String) throws
}

/// The protection coordinator: reads policies, applies vault state, and
/// exposes the counts the interface shows.
struct AppProtectionService: Sendable {

    private let store: any AppProtectionStore

    /// The vault's session-scoped unlock flag: runtime state only, never
    /// persisted. Sharing one reference means every copy of this service
    /// observes the same session decision.
    final class VaultSession: @unchecked Sendable {
        private let lock = NSLock()
        private var openFlag = false

        /// Whether the vault is open for this run of the app.
        var isOpen: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return openFlag
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                openFlag = newValue
            }
        }
    }

    /// The shared session flag for this launch.
    let session: VaultSession

    init(store: any AppProtectionStore) {
        self.store = store
        self.session = VaultSession()
    }

    /// Every recorded policy, keyed by record identifier.
    func all() throws -> [String: AppProtectionPolicy] {
        try store.all()
    }

    /// The policy for one record, when one is recorded and active.
    func policy(recordID: String) throws -> AppProtectionPolicy? {
        let policy = try store.all()[recordID]
        guard let policy, policy.isActive else { return policy }
        return policy
    }

    /// Locks one record: it will demand authentication to open.
    func lock(recordID: String) throws {
        let existing = try store.all()[recordID]
        try store.set(
            AppProtectionPolicy(
                requiresUnlock: true,
                concealed: existing?.concealed ?? false
            ),
            recordID: recordID
        )
    }

    /// Conceals one record: it disappears from listings until the vault
    /// opens, and demands authentication when it does open.
    func conceal(recordID: String) throws {
        try store.set(
            AppProtectionPolicy(requiresUnlock: true, concealed: true),
            recordID: recordID
        )
    }

    /// Removes every guard from one record.
    func clear(recordID: String) throws {
        try store.remove(recordID: recordID)
    }

    /// Whether the vault is hiding anything right now.
    func hasConcealedRecords() throws -> Bool {
        try store.all().values.contains { $0.concealed }
    }

    /// The identifiers of records the vault conceals.
    func concealedRecordIDs() throws -> Set<String> {
        Set(try store.all().compactMap { entry in entry.value.concealed ? entry.key : nil })
    }

    /// The identifiers of records that demand unlock while the vault is
    /// closed.
    func lockedRecordIDs() throws -> Set<String> {
        Set(try store.all().compactMap { entry in entry.value.requiresUnlock ? entry.key : nil })
    }

    /// The visibility decision for one record under a vault state.
    func visibility(recordID: String, vault: ProtectionVaultState) throws -> AppProtectionVisibility {
        AppProtectionVisibility.visibility(for: try policy(recordID: recordID), vault: vault)
    }
}

/// File-backed per-record protection policies.
final class FileAppProtectionStore: AppProtectionStore, @unchecked Sendable {

    private struct Document: Codable {
        let schemaVersion: Int
        var policies: [String: AppProtectionPolicy]
    }

    static let currentSchemaVersion = 1

    private let location: URL
    private let access = NSLock()
    private var cached: [String: AppProtectionPolicy]?

    init(location: URL) {
        self.location = location
    }

    private func loadedOrRead() throws -> [String: AppProtectionPolicy] {
        if let cached { return cached }
        guard FileManager.default.fileExists(atPath: location.path) else {
            cached = [:]
            return [:]
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let document = try decoder.decode(Document.self, from: Data(contentsOf: location))
            cached = document.policies
            return document.policies
        } catch {
            throw ZynSignError.structuredCatalogUnreadable(
                area: "app-protection",
                diagnosticDetail: "The app protection catalog could not be read.",
                underlyingError: error
            )
        }
    }

    private func persist(_ policies: [String: AppProtectionPolicy]) throws {
        let document = Document(schemaVersion: Self.currentSchemaVersion, policies: policies)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)
        try FileManager.default.createDirectory(
            at: location.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: location, options: .atomic)
        cached = policies
    }

    func all() throws -> [String: AppProtectionPolicy] {
        access.lock()
        defer { access.unlock() }
        return try loadedOrRead()
    }

    func set(_ policy: AppProtectionPolicy, recordID: String) throws {
        access.lock()
        defer { access.unlock() }
        var policies = try loadedOrRead()
        policies[recordID] = policy
        try persist(policies)
    }

    func remove(recordID: String) throws {
        access.lock()
        defer { access.unlock() }
        var policies = try loadedOrRead()
        guard policies.removeValue(forKey: recordID) != nil else { return }
        try persist(policies)
    }
}
