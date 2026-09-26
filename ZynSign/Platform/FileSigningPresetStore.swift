import Foundation

/// The file-backed implementation of `SigningPresetStore`: a versioned
/// catalog document in the user's container, replaced atomically on every
/// change.
///
/// Behaviour mirrors `FileApplicationRecordStore`:
/// - **Lazy, cached load.** The catalog is read on the first operation
///   and kept in memory; every mutation writes the whole catalog and
///   updates the cache only after the write succeeded.
/// - **Atomic replacement.** The catalog is written to a temporary file
///   and renamed into place.
/// - **Fail closed on damage.** A catalog that cannot be decoded is
///   refused as unreadable; the file is never reset or partially loaded.
///
/// Preset contents are pure domain values — identity fingerprints,
/// profile names, signing-option preferences — and hold no secrets.
actor FileSigningPresetStore: SigningPresetStore {

    /// The schema version this build reads and writes.
    ///
    /// Version 2 adds kind, team, verification, export, usage, and
    /// distribution fields on each preset. Version 1 catalogs remain
    /// readable: missing keys decode as the defaults a new preset uses.
    /// This build still refuses a catalog newer than `currentSchemaVersion`.
    static let currentSchemaVersion = 2

    /// The location of the catalog file.
    let catalogLocation: URL

    /// The presets as last read from or written to the catalog, keyed by
    /// identifier, once the catalog has been loaded.
    private var loadedPresets: [PresetIdentifier: SigningPreset]?

    init(catalogLocation: URL) {
        self.catalogLocation = catalogLocation
    }

    func allPresets() async throws -> [SigningPreset] {
        let presets = try loadedPresetsOrRead()
        return presets.values
            .sorted(by: SigningPreset.sortByRecencyThenName)
    }

    func preset(withID id: PresetIdentifier) async throws -> SigningPreset? {
        try loadedPresetsOrRead()[id]
    }

    func upsert(_ preset: SigningPreset) async throws {
        var presets = try loadedPresetsOrRead()
        presets[preset.id] = preset
        try persist(presets)
    }

    func remove(presetWithID id: PresetIdentifier) async throws {
        var presets = try loadedPresetsOrRead()
        guard presets.removeValue(forKey: id) != nil else { return }
        try persist(presets)
    }

    func count() async throws -> Int {
        try loadedPresetsOrRead().count
    }

    // MARK: - Storage helpers

    private func loadedPresetsOrRead() throws -> [PresetIdentifier: SigningPreset] {
        if let loadedPresets { return loadedPresets }
        let presets = try Self.readCatalog(at: catalogLocation)
        loadedPresets = presets
        return presets
    }

    private func persist(_ presets: [PresetIdentifier: SigningPreset]) throws {
        try Self.writeCatalog(presets, to: catalogLocation)
        loadedPresets = presets
    }

    private struct Envelope: Codable {
        var schemaVersion: Int
        var presets: [SigningPreset]
    }

    static func readCatalog(at location: URL) throws -> [PresetIdentifier: SigningPreset] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: location.path, isDirectory: &isDirectory) else {
            return [:]
        }
        guard !isDirectory.boolValue else {
            throw ZynSignError.presetCatalogUnreadable(
                diagnosticDetail: "The preset catalog location is a directory rather than a file."
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: location)
        } catch {
            throw ZynSignError.presetStorageFailure(
                diagnosticDetail: "The preset catalog could not be read.",
                underlyingError: error
            )
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw ZynSignError.presetCatalogUnreadable(
                diagnosticDetail: "The preset catalog is not a catalog document this build recognises.",
                underlyingError: error
            )
        }
        guard envelope.schemaVersion <= currentSchemaVersion else {
            throw ZynSignError.presetCatalogUnreadable(
                diagnosticDetail: "The preset catalog declares schema version \(envelope.schemaVersion); this build reads up to version \(currentSchemaVersion)."
            )
        }
        var presets: [PresetIdentifier: SigningPreset] = [:]
        for preset in envelope.presets {
            guard presets[preset.id] == nil else {
                throw ZynSignError.presetCatalogUnreadable(
                    diagnosticDetail: "The preset catalog records id '\(preset.id)' more than once."
                )
            }
            presets[preset.id] = preset
        }
        return presets
    }

    static func writeCatalog(
        _ presets: [PresetIdentifier: SigningPreset],
        to location: URL
    ) throws {
        let envelope = Envelope(
            schemaVersion: currentSchemaVersion,
            presets: presets.values
                .sorted(by: SigningPreset.sortByRecencyThenName)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(envelope)
        } catch {
            throw ZynSignError.presetStorageFailure(
                diagnosticDetail: "The preset catalog could not be encoded.",
                underlyingError: error
            )
        }
        do {
            try FileManager.default.createDirectory(
                at: location.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw ZynSignError.presetStorageFailure(
                diagnosticDetail: "The preset catalog directory could not be created.",
                underlyingError: error
            )
        }
        do {
            try data.write(to: location, options: [.atomic])
        } catch {
            throw ZynSignError.presetStorageFailure(
                diagnosticDetail: "The preset catalog could not be written.",
                underlyingError: error
            )
        }
    }
}
