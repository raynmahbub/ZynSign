import Foundation

/// Persistence for the tweak library's records.
///
/// The store holds metadata only; the payload bytes live behind
/// `TweakPayloadStorage`. A record without payload bytes is a broken
/// reference and is reported as such, never silently kept.
protocol TweakLibraryStore: Sendable {

    /// Every recorded tweak, newest first.
    func all() throws -> [TweakDescriptor]

    /// Records one tweak. Replaces any record with the same identifier.
    func upsert(_ descriptor: TweakDescriptor) throws

    /// Removes the record with `id`, when present.
    func remove(id: UUID) throws

    /// The recorded tweaks whose SHA-256 fingerprints match, used for
    /// duplicate detection at import time.
    func findByFingerprint(sha256Hex: String) throws -> [TweakDescriptor]
}

/// Storage for tweak payload bytes.
protocol TweakPayloadStorage: Sendable {

    /// Stores `data` under `id`, replacing anything stored there before.
    func store(_ data: Data, id: UUID) throws

    /// Reads the payload recorded under `id`.
    func payload(for id: UUID) throws -> Data?

    /// Removes the payload recorded under `id`, when present. The method is
    /// distinct from the record store's removal so one type can implement
    /// both boundaries without one requirement hiding the other.
    func removePayload(id: UUID) throws
}

/// Why a tweak import was refused.
enum TweakImportRefusal: Error, Equatable, Hashable, Sendable {
    case unreadableFile
    case emptyFile
    case fileTooLarge(bytes: Int, limit: Int)
    case libraryFull(limit: Int)
    case duplicate(existingName: String)

    var message: String {
        switch self {
        case .unreadableFile:
            return "The file could not be read."
        case .emptyFile:
            return "The file is empty."
        case .fileTooLarge(let bytes, let limit):
            return "The file is \(bytes) bytes; the tweak library accepts at most \(limit / (1024 * 1024)) MiB per file."
        case .libraryFull(let limit):
            return "The tweak library already holds \(limit) tweaks; remove one before importing another."
        case .duplicate(let existingName):
            return "An identical payload is already in the library as “\(existingName)”."
        }
    }
}

/// The outcome of one import.
struct TweakImportOutcome: Equatable, Hashable, Sendable {
    /// The recorded descriptor.
    let descriptor: TweakDescriptor
    /// The location the payload bytes were copied from.
    let sourceFileName: String
}

/// The tweak library coordinator: imports payloads, keeps the records, and
/// prepares staging plans.
///
/// The coordinator never interprets payload content — a dylib is stored as
/// bytes, a .deb as bytes, everything else the same. The only interpretation
/// is the kind inferred from the file name, and the only guarantee is the
/// SHA-256 fingerprint recorded at import time.
struct TweakLibraryService: Sendable {

    /// The most bytes one imported payload may carry (128 MiB).
    static let maximumPayloadBytes = 128 * 1024 * 1024

    /// The most tweaks the library records.
    static let maximumRecordCount = 200

    private let store: any TweakLibraryStore
    private let payloads: any TweakPayloadStorage
    private let digest: any MessageDigest

    init(store: any TweakLibraryStore, payloads: any TweakPayloadStorage, digest: any MessageDigest) {
        self.store = store
        self.payloads = payloads
        self.digest = digest
    }

    /// Every recorded tweak, newest first.
    func all() throws -> [TweakDescriptor] {
        try store.all()
    }

    /// The recorded groups, in deterministic order.
    func groups() throws -> [String] {
        Set(try store.all().compactMap(\.group)).sorted()
    }

    /// Imports one payload.
    ///
    /// - Parameters:
    ///   - data: The exact payload bytes.
    ///   - fileName: The name the user's file carried. Drives the kind
    ///     inference and the default display name.
    ///   - group: The organizational group, when the caller established one.
    /// - Returns: The import outcome.
    /// - Throws: A typed `ZynSignError` on storage failure; a
    ///   `TweakImportRefusal` when the import itself is refused.
    @discardableResult
    func importPayload(_ data: Data, fileName: String, group: String? = nil) throws -> Result<TweakImportOutcome, TweakImportRefusal> {
        guard !data.isEmpty else { return .failure(.emptyFile) }
        guard data.count <= Self.maximumPayloadBytes else {
            return .failure(.fileTooLarge(bytes: data.count, limit: Self.maximumPayloadBytes))
        }
        let recorded = (try? store.all()) ?? []
        guard recorded.count < Self.maximumRecordCount else {
            return .failure(.libraryFull(limit: Self.maximumRecordCount))
        }
        let fingerprint = try digest.digest(data, algorithm: .sha256).hexString
        if let existing = try store.findByFingerprint(sha256Hex: fingerprint).first {
            return .failure(.duplicate(existingName: existing.name))
        }
        let descriptor = TweakDescriptor(
            name: Self.displayName(forFileName: fileName),
            fileName: fileName,
            kind: TweakKind.infer(fromFileName: fileName),
            byteSize: data.count,
            sha256Hex: fingerprint,
            group: group
        )
        try payloads.store(data, id: descriptor.id)
        do {
            try store.upsert(descriptor)
        } catch {
            try? payloads.removePayload(id: descriptor.id)
            throw error
        }
        return .success(TweakImportOutcome(descriptor: descriptor, sourceFileName: fileName))
    }

    /// Renames one tweak. Empty names are refused by leaving the record
    /// untouched and returning `false`.
    @discardableResult
    func rename(id: UUID, to newName: String) throws -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { return false }
        guard var descriptor = try record(id: id) else { return false }
        descriptor.name = trimmed
        try store.upsert(descriptor)
        return true
    }

    /// Moves one tweak into a group, or out of every group with `nil`.
    func setGroup(id: UUID, group: String?) throws {
        guard var descriptor = try record(id: id) else { return }
        descriptor.group = group?.isEmpty == true ? nil : group
        try store.upsert(descriptor)
    }

    /// Toggles whether the tweak joins signing selections by default.
    func setEnabled(id: UUID, enabled: Bool) throws {
        guard var descriptor = try record(id: id) else { return }
        descriptor.enabledByDefault = enabled
        try store.upsert(descriptor)
    }

    /// Removes one tweak: record first, then payload bytes. A payload whose
    /// record is already gone is still reclaimed.
    func remove(id: UUID) throws {
        try store.remove(id: id)
        try payloads.removePayload(id: id)
    }

    /// The payload bytes one tweak carries, when still present.
    func payload(for id: UUID) throws -> Data? {
        try payloads.payload(for: id)
    }

    /// Builds a staging plan from the enabled selection.
    func makePlan(selectionIDs: Set<UUID>) throws -> Result<TweakInjectionPlan, TweakInjectionPlan.Refusal> {
        let selected = try store.all().filter { selectionIDs.contains($0.id) }
        return TweakInjectionPlan.makePlan(selection: selected)
    }

    /// Writes the plan's manifest as JSON the caller can attach to a signing
    /// session's output. Returns the serialized bytes.
    func manifestData(for plan: TweakInjectionPlan) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(plan.manifestEntries)
    }

    /// The record with `id`, when recorded.
    func record(id: UUID) throws -> TweakDescriptor? {
        try store.all().first { $0.id == id }
    }

    /// The display name a file name defaults to: its last path component
    /// without the final extension, or the whole name when there is none.
    static func displayName(forFileName fileName: String) -> String {
        let last = (fileName as NSString).lastPathComponent
        let withoutExtension = (last as NSString).deletingPathExtension
        let candidate = withoutExtension.isEmpty ? last : withoutExtension
        return candidate.isEmpty ? "Tweak" : candidate
    }
}
