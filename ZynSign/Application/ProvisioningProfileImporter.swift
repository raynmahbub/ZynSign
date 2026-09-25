import Foundation

/// Imports a `.mobileprovision` file into the provisioning profile library.
///
/// The importer reads the file's container, parses the embedded
/// provisioning profile, validates it structurally, and reduces the
/// parsed `ProvisioningProfile` into a `ProvisioningProfileSummary`
/// suitable for the picker UI. An authenticated, structurally valid input
/// is copied under an opaque name into app-owned storage. The summary is
/// presentation metadata, never a substitute for verifying those bytes
/// again when the user selects it for a signing operation.
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
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: sourceURL)
            defer { try? handle.close() }
            data = try handle.read(upToCount: ProvisioningProfileInput.maximumByteCount + 1) ?? Data()
            guard !data.isEmpty, data.count <= ProvisioningProfileInput.maximumByteCount else {
                throw ZynSignError.invalidProvisioningProfileFile(
                    diagnosticDetail: "The profile is empty or exceeds the bounded CMS input size."
                )
            }
        } catch let error as ZynSignError {
            throw error
        } catch {
            throw ZynSignError.invalidProvisioningProfileFile(
                diagnosticDetail: "The selected profile file could not be read.",
                underlyingError: error
            )
        }
        let inspectionResult = try self.inspection.inspect(ProvisioningProfileInput(bytes: data))
        guard inspectionResult.authenticity == .authenticated,
              inspectionResult.isStructurallyValid,
              let expirationDate = inspectionResult.profile.expirationDate else {
            throw ZynSignError.invalidProvisioningProfileFile(
                diagnosticDetail: "An authenticated, structurally valid profile with a declared expiration is required for import."
            )
        }
        let profile = inspectionResult.profile
        // Use an opaque generated name, never the user's original filename.
        let destinationName = "\(UUID().uuidString).mobileprovision"
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
            expirationDate: expirationDate,
            entitlementsKeys: derivedEntitlementsKeys(from: profile),
            allowsDebug: profile.getTaskAllow ?? false,
            sourceFileName: destinationName,
            importedAt: now()
        )
    }

    /// Presentation-only summary of the *actual* parsed scope. Never infer a
    /// wildcard from an exact App ID or split a Team ID at a convenient dot:
    /// the signing policy rechecks the original authenticated profile.
    private func derivedBundleIdentifierPatterns(from profile: ProvisioningProfile) -> [String] {
        switch profile.applicationIdentifier?.bundleIdentifierComponent {
        case .some(.exact(let identifier)): return [identifier.rawValue]
        case .some(.wildcard(let prefix)): return [prefix + "*"]
        case .none: return []
        }
    }

    /// The entitlement keys the profile declares. Surfaced for the picker
    /// UI to warn when the user picks a profile that lacks an entitlement
    /// the application expects.
    private func derivedEntitlementsKeys(from profile: ProvisioningProfile) -> [String] {
        guard let entitlements = profile.entitlements else { return [] }
        return entitlements.keys
    }
}
