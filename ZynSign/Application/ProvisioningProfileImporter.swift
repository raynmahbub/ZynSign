import Foundation

/// Imports a `.mobileprovision` file into the provisioning profile library.
///
/// The importer reads the file's container, parses the embedded
/// provisioning profile, validates it structurally, and reduces the
/// parsed `ProvisioningProfile` into a `ProvisioningProfileSummary`
/// suitable for the profile manager: name, UUID, team, creation and
/// expiration dates, distribution type, device count, App ID with its
/// exact-or-wildcard bundle identifier, embedded certificate fingerprints,
/// and the bundle-identifier patterns the compatibility engine matches
/// with. The original file's bytes are *not* duplicated: the importer
/// records a file name reference, and the stored copy is what signing and
/// Refresh Validation read later.
///
/// Every refusal is a typed `ZynSignError` whose `userMessage` the Profiles
/// tab shows verbatim — a corrupted or unsupported file never reaches the
/// library and never surfaces as a generic message.
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
        // A file already known to exceed the profile input ceiling is
        // refused before it is read into memory. A provider that cannot
        // report a size falls through to the same check inside inspection.
        if let size = try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > ProvisioningProfileInput.maximumByteCount {
            throw ZynSignError.provisioningProfileInputTooLarge(
                diagnosticDetail: "The selected profile file exceeds the \(ProvisioningProfileInput.maximumByteCount)-byte input bound."
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: sourceURL)
        } catch {
            throw ZynSignError.invalidProvisioningProfileFile(
                diagnosticDetail: "Could not read the profile file at \(sourceURL.lastPathComponent).",
                underlyingError: error
            )
        }
        let inspectionResult = try self.inspection.inspect(ProvisioningProfileInput(bytes: data))
        guard inspectionResult.isParsed else {
            throw ZynSignError.invalidProvisioningProfileFile(
                diagnosticDetail: "The profile bytes could not be decoded as a CMS container."
            )
        }
        let profile = inspectionResult.profile
        let destinationName = "\(UUID().uuidString)-\(sourceURL.lastPathComponent)"
        let destination = storageDirectory.appendingPathComponent(destinationName, isDirectory: false)
        do {
            try FileManager.default.createDirectory(
                at: storageDirectory,
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: [.atomic])
        } catch {
            throw ZynSignError.profileLibraryStorageFailure(
                diagnosticDetail: "The imported profile could not be staged.",
                underlyingError: error
            )
        }
        return makeSummary(
            for: profile,
            fallbackName: sourceURL.deletingPathExtension().lastPathComponent,
            sourceFileName: destinationName,
            importedAt: now()
        )
    }

    /// Re-reads the stored `.mobileprovision` file behind `summary` and
    /// returns an updated summary with freshly parsed facts: the same
    /// identifier and import date, but current expiration, patterns,
    /// certificate fingerprints, team name, type, and device count.
    ///
    /// This is "Refresh Validation" in the UI: it repairs legacy summaries
    /// (for example patterns derived before the manager knew the App ID's
    /// exact-or-wildcard component) and surfaces a typed failure when the
    /// stored file has gone missing or no longer parses.
    func refresh(_ summary: ProvisioningProfileSummary) async throws -> ProvisioningProfileSummary {
        let source = storageDirectory.appendingPathComponent(summary.sourceFileName, isDirectory: false)
        let data: Data
        do {
            data = try Data(contentsOf: source)
        } catch {
            throw ZynSignError.profileLibraryStorageFailure(
                diagnosticDetail: "The stored profile file could not be re-read for validation.",
                underlyingError: error
            )
        }
        let inspectionResult = try self.inspection.inspect(ProvisioningProfileInput(bytes: data))
        guard inspectionResult.isParsed else {
            throw ZynSignError.invalidProvisioningProfileFile(
                diagnosticDetail: "The stored profile could not be decoded on re-validation."
            )
        }
        return makeSummary(
            for: inspectionResult.profile,
            fallbackName: summary.name,
            sourceFileName: summary.sourceFileName,
            importedAt: summary.importedAt,
            id: summary.id
        )
    }

    // MARK: - Summary construction

    /// Builds the full summary the profile manager persists from a parsed
    /// profile. One place derives every fact, so import and refresh can
    /// never disagree.
    private func makeSummary(
        for profile: ProvisioningProfile,
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
            expirationDate: profile.expirationDate ?? now().addingTimeInterval(7 * 86400),
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
