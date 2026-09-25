import Foundation

/// The file-backed implementation of `ProvisioningProfileLibrary`: a
/// versioned catalog document in the user's container, replaced atomically
/// on every change.
///
/// Behaviour mirrors `FileApplicationRecordStore`. The library holds
/// `ProvisioningProfileSummary` values; the original `.mobileprovision`
/// files live alongside the catalog in the same directory, referenced by
/// file name. No summary content is encrypted or otherwise sensitive:
/// profile name, team identifier, and expiration date are public metadata.
actor FileProvisioningProfileLibrary: ProvisioningProfileLibrary {

    /// The schema version this build reads and writes.
    static let currentSchemaVersion = 1

    /// The location of the catalog file.
    let catalogLocation: URL

    /// The profiles as last read from or written to the catalog, keyed by
    /// identifier.
    private var loadedProfiles: [ProvisioningProfileIdentifier: ProvisioningProfileSummary]?

    init(catalogLocation: URL) {
        self.catalogLocation = catalogLocation
    }

    func allProfiles() async throws -> [ProvisioningProfileSummary] {
        try loadedProfilesOrRead().values
            .sorted(by: ProvisioningProfileSummary.sortByExpiration)
    }

    func profile(withID id: ProvisioningProfileIdentifier) async throws -> ProvisioningProfileSummary? {
        try loadedProfilesOrRead()[id]
    }

    func upsert(_ summary: ProvisioningProfileSummary) async throws {
        var profiles = try loadedProfilesOrRead()
        profiles[summary.id] = summary
        try persist(profiles)
    }

    func remove(profileWithID id: ProvisioningProfileIdentifier) async throws {
        var profiles = try loadedProfilesOrRead()
        guard profiles.removeValue(forKey: id) != nil else { return }
        try persist(profiles)
    }

    func count() async throws -> Int {
        try loadedProfilesOrRead().count
    }

    // MARK: - Storage helpers

    private func loadedProfilesOrRead() throws -> [ProvisioningProfileIdentifier: ProvisioningProfileSummary] {
        if let loadedProfiles { return loadedProfiles }
        let profiles = try Self.readCatalog(at: catalogLocation)
        loadedProfiles = profiles
        return profiles
    }

    private func persist(_ profiles: [ProvisioningProfileIdentifier: ProvisioningProfileSummary]) throws {
        try Self.writeCatalog(profiles, to: catalogLocation)
        loadedProfiles = profiles
    }

    private struct Envelope: Codable {
        var schemaVersion: Int
        var profiles: [ProvisioningProfileSummary]
    }

    static func readCatalog(at location: URL) throws -> [ProvisioningProfileIdentifier: ProvisioningProfileSummary] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: location.path, isDirectory: &isDirectory) else {
            return [:]
        }
        guard !isDirectory.boolValue else {
            throw ZynSignError.profileLibraryUnreadable(
                diagnosticDetail: "The provisioning profile library location is a directory rather than a file."
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: location)
        } catch {
            throw ZynSignError.profileLibraryStorageFailure(
                diagnosticDetail: "The provisioning profile library could not be read.",
                underlyingError: error
            )
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw ZynSignError.profileLibraryUnreadable(
                diagnosticDetail: "The provisioning profile library is not a catalog this build recognises.",
                underlyingError: error
            )
        }
        guard envelope.schemaVersion <= currentSchemaVersion else {
            throw ZynSignError.profileLibraryUnreadable(
                diagnosticDetail: "The provisioning profile library declares schema version \(envelope.schemaVersion); this build reads up to version \(currentSchemaVersion)."
            )
        }
        var profiles: [ProvisioningProfileIdentifier: ProvisioningProfileSummary] = [:]
        for profile in envelope.profiles {
            guard profiles[profile.id] == nil else {
                throw ZynSignError.profileLibraryUnreadable(
                    diagnosticDetail: "The provisioning profile library records id '\(profile.id)' more than once."
                )
            }
            profiles[profile.id] = profile
        }
        return profiles
    }

    static func writeCatalog(
        _ profiles: [ProvisioningProfileIdentifier: ProvisioningProfileSummary],
        to location: URL
    ) throws {
        let envelope = Envelope(
            schemaVersion: currentSchemaVersion,
            profiles: profiles.values
                .sorted(by: ProvisioningProfileSummary.sortByExpiration)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(envelope)
        } catch {
            throw ZynSignError.profileLibraryStorageFailure(
                diagnosticDetail: "The provisioning profile library could not be encoded.",
                underlyingError: error
            )
        }
        do {
            try FileManager.default.createDirectory(
                at: location.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw ZynSignError.profileLibraryStorageFailure(
                diagnosticDetail: "The provisioning profile library directory could not be created.",
                underlyingError: error
            )
        }
        do {
            try data.write(to: location, options: [.atomic])
        } catch {
            throw ZynSignError.profileLibraryStorageFailure(
                diagnosticDetail: "The provisioning profile library could not be written.",
                underlyingError: error
            )
        }
    }
}
