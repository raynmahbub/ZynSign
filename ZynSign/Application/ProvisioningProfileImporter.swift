import Foundation

/// Imports a `.mobileprovision` file into the provisioning profile library.
///
/// The importer reads the file's container, parses the embedded
/// provisioning profile, validates it structurally, and reduces the
/// parsed `ProvisioningProfile` into a `ProvisioningProfileSummary`
/// suitable for the profile manager: name, UUID, team, actual expiration,
/// distribution type, device count, App ID scope and certificate fingerprints.
/// Only authenticated, structurally valid profiles are imported or refreshed.
/// The original bytes are copied once under an opaque name; a summary is
/// presentation metadata and never grants signing authority. Signing re-reads
/// and validates the stored bytes for the selected app and identity.
struct ProvisioningProfileImporter {

    /// The inspection use case that performs container decoding and
    /// payload parsing.
    private let inspection: ProvisioningProfileInspectionUseCase

    /// The location of the provisioning profile directory; the importer
    /// records the file name relative to this directory.
    private let storageDirectory: URL

    /// The clock used to record import time and check expiry windows.
    private let now: @Sendable () -> Date

    init(
        inspection: ProvisioningProfileInspectionUseCase,
        storageDirectory: URL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.inspection = inspection
        self.storageDirectory = storageDirectory
        self.now = now
    }

    /// Imports a profile from `sourceURL`, copying it into the profile
    /// library directory and returning the resulting summary. The source
    /// file is left untouched.
    func importProfile(at sourceURL: URL) async throws -> ProvisioningProfileSummary {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }
        let data = try readBoundedProfile(at: sourceURL)
        let (profile, expirationDate) = try authenticatedProfile(from: data)
        let destinationName = "\(UUID().uuidString).mobileprovision"
        let destination = storageDirectory.appendingPathComponent(destinationName, isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            try data.write(to: destination, options: [.atomic])
        } catch {
            throw ZynSignError.profileLibraryStorageFailure(
                diagnosticDetail: "The imported profile could not be staged.", underlyingError: error
            )
        }
        return makeSummary(
            for: profile, expirationDate: expirationDate,
            fallbackName: sourceURL.deletingPathExtension().lastPathComponent,
            sourceFileName: destinationName, importedAt: now()
        )
    }

    /// Refresh Validation must re-authenticate the bounded stored bytes. It
    /// cannot turn an altered/unverified file or a missing expiration into a
    /// validated summary, and it must not trust a catalog-supplied path.
    func refresh(_ summary: ProvisioningProfileSummary) async throws -> ProvisioningProfileSummary {
        let name = summary.sourceFileName
        guard !name.isEmpty,
              (name.lowercased().hasSuffix(".mobileprovision") ||
               name.lowercased().hasSuffix(".provisionprofile")),
              !name.contains("/"), !name.contains("\\"),
              !name.contains(where: { $0.isControl }) else {
            throw ZynSignError.profileLibraryUnreadable(
                diagnosticDetail: "The saved profile has an unsafe file reference."
            )
        }
        let source = storageDirectory.appendingPathComponent(name, isDirectory: false)
        let data: Data
        do {
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ZynSignError.invalidProvisioningProfileFile(
                    diagnosticDetail: "The stored profile is not a regular file."
                )
            }
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            data = try handle.read(upToCount: ProvisioningProfileInput.maximumByteCount + 1) ?? Data()
        } catch let error as ZynSignError {
            throw error
        } catch {
            throw ZynSignError.profileLibraryStorageFailure(
                diagnosticDetail: "The stored profile file could not be re-read for validation.",
                underlyingError: error
            )
        }
        let (profile, expirationDate) = try authenticatedProfile(from: data)
        return makeSummary(
            for: profile, expirationDate: expirationDate, fallbackName: summary.name,
            sourceFileName: name, importedAt: summary.importedAt, id: summary.id
        )
    }

    private func readBoundedProfile(at sourceURL: URL) throws -> Data {
        if let size = try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > ProvisioningProfileInput.maximumByteCount {
            throw ZynSignError.provisioningProfileInputTooLarge(
                diagnosticDetail: "The selected profile exceeds the bounded CMS input size."
            )
        }
        do {
            let handle = try FileHandle(forReadingFrom: sourceURL)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: ProvisioningProfileInput.maximumByteCount + 1) ?? Data()
            guard !data.isEmpty else {
                throw ZynSignError.invalidProvisioningProfileFile(
                    diagnosticDetail: "The selected profile is empty."
                )
            }
            guard data.count <= ProvisioningProfileInput.maximumByteCount else {
                throw ZynSignError.provisioningProfileInputTooLarge(
                    diagnosticDetail: "The selected profile exceeds the bounded CMS input size."
                )
            }
            return data
        } catch let error as ZynSignError {
            throw error
        } catch {
            throw ZynSignError.invalidProvisioningProfileFile(
                diagnosticDetail: "The selected profile file could not be read.",
                underlyingError: error
            )
        }
    }

    private func authenticatedProfile(from data: Data) throws -> (ProvisioningProfile, Date) {
        let inspected = try inspection.inspect(ProvisioningProfileInput(bytes: data))
        guard inspected.authenticity == .authenticated, inspected.isStructurallyValid,
              let expirationDate = inspected.profile.expirationDate else {
            throw ZynSignError.invalidProvisioningProfileFile(
                diagnosticDetail: "An authenticated, structurally valid profile with a declared expiration is required."
            )
        }
        return (inspected.profile, expirationDate)
    }

    // MARK: - Summary construction

    /// Builds the full summary the profile manager persists from a parsed
    /// profile. One place derives every fact, so import and refresh can
    /// never disagree.
    private func makeSummary(
        for profile: ProvisioningProfile,
        expirationDate: Date,
        fallbackName: String,
        sourceFileName: String,
        importedAt: Date,
        id: ProvisioningProfileIdentifier = ProvisioningProfileIdentifier()
    ) -> ProvisioningProfileSummary {
        ProvisioningProfileSummary(
            id: id,
            name: profile.profileName ?? fallbackName,
            teamIdentifier: profile.teamIdentifiers?.first ?? profile.entitlementTeamIdentifier,
            bundleIdentifierPatterns: derivedBundleIdentifierPatterns(from: profile),
            expirationDate: expirationDate,
            entitlementsKeys: derivedEntitlementsKeys(from: profile),
            allowsDebug: profile.getTaskAllow ?? false,
            sourceFileName: sourceFileName,
            importedAt: importedAt,
            uuid: profile.uuid?.uuidString,
            teamName: profile.teamName,
            creationDate: profile.creationDate,
            profileType: profile.classification,
            deviceCount: profile.provisionedDevices?.count,
            applicationIdentifier: profile.applicationIdentifier?.fullValue,
            bundleIdentifier: profile.bundleIdentifier?.rawValue,
            certificateFingerprints: profile.developerCertificates?
                .compactMap { $0.metadata?.sha256Fingerprint.hexDigest.lowercased() }
        )
    }

    /// The bundle-identifier patterns `covers(bundleIdentifier:)` matches
    /// against. The domain already split the App ID into its exact-or-
    /// wildcard component, so this mirrors that component instead of
    /// guessing: an exact App ID becomes the bundle identifier itself, a
    /// trailing wildcard becomes `prefix.*`, and the team-wide `*` App ID
    /// becomes `*`. A profile with no derivable component contributes no
    /// pattern rather than a wrong one — legacy summaries with incorrect
    /// patterns are repaired by Refresh Validation.
    private func derivedBundleIdentifierPatterns(from profile: ProvisioningProfile) -> [String] {
        guard let component = profile.applicationIdentifier?.bundleIdentifierComponent else {
            return []
        }
        switch component {
        case .exact(let identifier):
            return [identifier.rawValue]
        case .wildcard(let prefix):
            // The stored prefix keeps its trailing delimiter ("com.example."),
            // so appending "*" yields "com.example.*". A team-wide App ID
            // parses to an empty prefix and becomes "*".
            return [prefix.isEmpty ? "*" : prefix + "*"]
        }
    }

    /// The entitlement keys the profile declares. Surfaced for the detail
    /// screen to show what the profile grants.
    private func derivedEntitlementsKeys(from profile: ProvisioningProfile) -> [String] {
        guard let entitlements = profile.entitlements else { return [] }
        return entitlements.keys
    }
}
