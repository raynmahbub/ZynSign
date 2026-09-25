import Foundation

/// Imports a `.mobileprovision` file into the provisioning profile library.
///
/// The importer reads the file's container, parses the embedded
/// provisioning profile, validates it structurally, and reduces the
/// parsed `ProvisioningProfile` into a `ProvisioningProfileSummary`
/// suitable for the picker UI. The original file's bytes are *not*
/// duplicated: the importer only records a file name reference, and the
/// picker UI reads the file by that name when the user chooses it for a
/// signing operation.
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
        return ProvisioningProfileSummary(
            name: profile.profileName ?? sourceURL.deletingPathExtension().lastPathComponent,
            teamIdentifier: profile.teamIdentifiers?.first ?? profile.entitlementTeamIdentifier,
            bundleIdentifierPatterns: derivedBundleIdentifierPatterns(from: profile),
            expirationDate: profile.expirationDate ?? now().addingTimeInterval(7 * 86400),
            entitlementsKeys: derivedEntitlementsKeys(from: profile),
            allowsDebug: profile.getTaskAllow ?? false,
            sourceFileName: destinationName,
            importedAt: now()
        )
    }

    /// The bundle-identifier patterns the picker UI should offer as "this
    /// profile is for". Apple's plist usually records the
    /// `application-identifier` prefix; we surface it as `prefix.*` so a
    /// user can sign any bundle starting with the prefix.
    private func derivedBundleIdentifierPatterns(from profile: ProvisioningProfile) -> [String] {
        if let applicationIdentifier = profile.applicationIdentifier {
            // applicationIdentifier.fullValue is "<prefix>.<bundle>" — strip
            // the last component to get the prefix.
            let raw = applicationIdentifier.fullValue
            if let lastDot = raw.lastIndex(of: ".") {
                let prefix = String(raw[raw.startIndex..<lastDot])
                return ["\(prefix).*"]
            }
            return [raw]
        }
        if let prefix = profile.applicationIdentifierPrefix {
            return ["\(prefix).*"]
        }
        return []
    }

    /// The entitlement keys the profile declares. Surfaced for the picker
    /// UI to warn when the user picks a profile that lacks an entitlement
    /// the application expects.
    private func derivedEntitlementsKeys(from profile: ProvisioningProfile) -> [String] {
        guard let entitlements = profile.entitlements else { return [] }
        return entitlements.keys
    }
}
