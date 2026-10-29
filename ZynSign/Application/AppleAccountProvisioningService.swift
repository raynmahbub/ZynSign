import Foundation

/// Authenticated Apple Developer Portal session descriptor (never stores the
/// user's Apple ID password).
struct ApplePortalSessionToken: Codable, Equatable, Sendable {
    let appleIDEmail: String
    let dsid: String
    let myacinfoToken: String
    let anisetteServerURL: URL
    let authenticatedAt: Date
}

/// Keychain-backed RSA-2048 CSR generator and issued-certificate registrar.
///
/// Private keys never leave the platform Keychain; only the public PKCS#10 PEM
/// CSR and the Apple-issued X.509 DER certificate cross this port.
protocol CSRKeypairProvisioning: Sendable {
    func generateKeypairAndBuildCSR(commonName: String) throws -> (keyTag: String, csrPEM: String)
    func registerIssuedCertificate(certificateDER: Data, keyTag: String) throws -> SigningIdentityIdentifier
}

/// Network port for Apple Developer Services (`QH65B2`) and Anisette v3 headers.
protocol AppleDeveloperPortalClient: Sendable {
    func fetchAnisetteHeaders(from serverURL: URL) async throws -> AnisetteHeaderBundle
    func authenticate(
        appleID: String,
        password: String,
        twoFactorCode: String?,
        anisette: AnisetteHeaderBundle,
        anisetteURL: URL
    ) async throws -> ApplePortalSessionToken
    func listTeams(session: ApplePortalSessionToken, anisette: AnisetteHeaderBundle) async throws -> [AppleDeveloperTeam]
    func listDevices(session: ApplePortalSessionToken, anisette: AnisetteHeaderBundle, teamID: String) async throws -> [ApplePortalDevice]
    func registerDevice(
        session: ApplePortalSessionToken,
        anisette: AnisetteHeaderBundle,
        teamID: String,
        name: String,
        udid: String
    ) async throws -> ApplePortalDevice
    func listDevelopmentCertificates(
        session: ApplePortalSessionToken,
        anisette: AnisetteHeaderBundle,
        teamID: String
    ) async throws -> [ApplePortalCertificate]
    func submitDevelopmentCSR(
        session: ApplePortalSessionToken,
        anisette: AnisetteHeaderBundle,
        teamID: String,
        csrPEM: String
    ) async throws -> ApplePortalCertificate
    func revokeDevelopmentCertificate(
        session: ApplePortalSessionToken,
        anisette: AnisetteHeaderBundle,
        teamID: String,
        serialNumber: String
    ) async throws
    func listAppIDs(session: ApplePortalSessionToken, anisette: AnisetteHeaderBundle, teamID: String) async throws -> [ApplePortalAppID]
    func registerAppID(
        session: ApplePortalSessionToken,
        anisette: AnisetteHeaderBundle,
        teamID: String,
        name: String,
        bundleIdentifier: String
    ) async throws -> ApplePortalAppID
    func ensureAppGroupAssigned(
        session: ApplePortalSessionToken,
        anisette: AnisetteHeaderBundle,
        teamID: String,
        appIDRecordID: String,
        groupIdentifier: String
    ) async throws
    func downloadTeamProvisioningProfile(
        session: ApplePortalSessionToken,
        anisette: AnisetteHeaderBundle,
        teamID: String,
        appIDRecordID: String
    ) async throws -> Data
}

/// Orchestrates Free Personal Team (7-day) and Paid Developer Program (365-day)
/// certificate, device UDID, App ID, App Group, and `.mobileprovision`
/// provisioning directly into ZynSign's `IdentityStore` and `ProvisioningProfileLibrary`.
@MainActor
final class AppleAccountProvisioningService: ObservableObject {

    struct ProvisionedSigningBundle: Equatable, Sendable {
        let team: AppleDeveloperTeam
        let identityID: SigningIdentityIdentifier
        let profileSummary: ProvisioningProfileSummary
        let effectiveBundleIdentifier: String
        let appID: ApplePortalAppID
    }

    enum ServiceError: Error, LocalizedError {
        case invalidAnisetteURL
        case notSignedIn
        case noTeamSelected
        case missingCertificateBytes
        case missingProfileServices

        var errorDescription: String? {
            switch self {
            case .invalidAnisetteURL:
                return "Enter a valid HTTPS Anisette v3 server URL before signing in."
            case .notSignedIn:
                return "Sign in with an Apple ID (Free or Paid Developer) first."
            case .noTeamSelected:
                return "No Apple Developer team is available or selected."
            case .missingCertificateBytes:
                return "Apple Developer Portal did not return X.509 certificate bytes for the submitted CSR."
            case .missingProfileServices:
                return "Provisioning profile library is not configured in this environment."
            }
        }
    }

    @Published private(set) var activeSession: ApplePortalSessionToken?
    @Published private(set) var teams: [AppleDeveloperTeam] = []
    @Published var selectedTeamID: String?
    @Published private(set) var registeredDevices: [ApplePortalDevice] = []
    @Published private(set) var portalCertificates: [ApplePortalCertificate] = []
    @Published private(set) var portalAppIDs: [ApplePortalAppID] = []
    @Published var anisetteServerURLString: String
    @Published private(set) var isBusy = false
    @Published var statusMessage: String?
    @Published var lastErrorMessage: String?

    private let portalClient: any AppleDeveloperPortalClient
    private let csrProvisioner: any CSRKeypairProvisioning
    private let profileImporter: ProvisioningProfileImporter?
    private let profileLibrary: (any ProvisioningProfileLibrary)?
    private let settingsURL: URL

    var selectedTeam: AppleDeveloperTeam? {
        if let selectedTeamID, let match = teams.first(where: { $0.teamID == selectedTeamID }) {
            return match
        }
        return teams.first
    }

    nonisolated init(
        portalClient: any AppleDeveloperPortalClient,
        csrProvisioner: any CSRKeypairProvisioning,
        profileImporter: ProvisioningProfileImporter?,
        profileLibrary: (any ProvisioningProfileLibrary)?,
        settingsURL: URL
    ) {
        self.portalClient = portalClient
        self.csrProvisioner = csrProvisioner
        self.profileImporter = profileImporter
        self.profileLibrary = profileLibrary
        self.settingsURL = settingsURL
        if let saved = try? Data(contentsOf: settingsURL),
           let dict = try? JSONSerialization.jsonObject(with: saved) as? [String: String],
           let urlStr = dict["anisetteServerURL"], !urlStr.isEmpty {
            self.anisetteServerURLString = urlStr
        } else {
            self.anisetteServerURLString = ""
        }
    }

    func saveAnisetteURL(_ rawURL: String) {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        anisetteServerURLString = trimmed
        let dict = ["anisetteServerURL": trimmed]
        if let bytes = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
            try? FileManager.default.createDirectory(
                at: settingsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? bytes.write(to: settingsURL, options: .atomic)
        }
    }

    func signOut() {
        activeSession = nil
        teams = []
        selectedTeamID = nil
        registeredDevices = []
        portalCertificates = []
        portalAppIDs = []
        statusMessage = "Signed out of Apple Developer session."
    }

    func signIn(appleID: String, password: String, twoFactorCode: String? = nil) async throws {
        let cleanURLStr = anisetteServerURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let anisetteURL = URL(string: cleanURLStr),
              anisetteURL.scheme?.lowercased() == "https" else {
            throw ServiceError.invalidAnisetteURL
        }
        saveAnisetteURL(cleanURLStr)
        isBusy = true
        lastErrorMessage = nil
        defer { isBusy = false }

        do {
            let anisette = try await portalClient.fetchAnisetteHeaders(from: anisetteURL)
            let token = try await portalClient.authenticate(
                appleID: appleID.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password,
                twoFactorCode: twoFactorCode?.trimmingCharacters(in: .whitespacesAndNewlines),
                anisette: anisette,
                anisetteURL: anisetteURL
            )
            activeSession = token
            let fetchedTeams = try await portalClient.listTeams(session: token, anisette: anisette)
            teams = fetchedTeams
            selectedTeamID = fetchedTeams.first?.teamID
            if let team = fetchedTeams.first {
                try await refreshPortalInventory(for: team.teamID, anisette: anisette)
                statusMessage = "Connected to \(team.name) (\(team.accountKind.displayName))."
            } else {
                statusMessage = "Authenticated as \(token.appleIDEmail)."
            }
        } catch {
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    func refreshPortalInventory(for teamID: String? = nil, anisette cachedAnisette: AnisetteHeaderBundle? = nil) async throws {
        guard let session = activeSession else { throw ServiceError.notSignedIn }
        guard let resolvedTeamID = teamID ?? selectedTeam?.teamID else { throw ServiceError.noTeamSelected }
        let anisette: AnisetteHeaderBundle
        if let cachedAnisette {
            anisette = cachedAnisette
        } else {
            anisette = try await portalClient.fetchAnisetteHeaders(from: session.anisetteServerURL)
        }
        registeredDevices = try await portalClient.listDevices(session: session, anisette: anisette, teamID: resolvedTeamID)
        portalCertificates = try await portalClient.listDevelopmentCertificates(session: session, anisette: anisette, teamID: resolvedTeamID)
        portalAppIDs = try await portalClient.listAppIDs(session: session, anisette: anisette, teamID: resolvedTeamID)
    }

    /// End-to-end provisioning for either a Free Apple ID (7-day personal team)
    /// or a Paid Apple Developer team (365-day): registers UDID, mints CSR &
    /// development certificate in Keychain, registers App ID, downloads
    /// `.mobileprovision`, and stores both in ZynSign's signing libraries.
    func provisionSigningMaterials(
        originalBundleID: String,
        appDisplayName: String,
        deviceUDID: String?,
        deviceName: String = "ZynSign iOS Device",
        assignSharedAppGroup: Bool = false,
        revokeOldestOnCertificateLimit: Bool = true
    ) async throws -> ProvisionedSigningBundle {
        guard let session = activeSession else { throw ServiceError.notSignedIn }
        guard let team = selectedTeam else { throw ServiceError.noTeamSelected }
        guard let profileImporter, let profileLibrary else { throw ServiceError.missingProfileServices }

        isBusy = true
        lastErrorMessage = nil
        defer { isBusy = false }

        do {
            let anisette = try await portalClient.fetchAnisetteHeaders(from: session.anisetteServerURL)
            try await ensureDeviceRegistered(session: session, anisette: anisette, teamID: team.teamID, udid: deviceUDID, deviceName: deviceName)
            let identityID = try await mintAndRegisterIdentity(session: session, anisette: anisette, teamID: team.teamID, revokeOldest: revokeOldestOnCertificateLimit)
            let effectiveBundleID = PersonalTeamBundleIDPlanner.scopedBundleIdentifier(originalBundleID: originalBundleID, team: team)
            let appID = try await resolveOrRegisterAppID(
                session: session,
                anisette: anisette,
                team: team,
                effectiveBundleID: effectiveBundleID,
                appDisplayName: appDisplayName,
                assignSharedAppGroup: assignSharedAppGroup
            )
            let profileBytes = try await portalClient.downloadTeamProvisioningProfile(
                session: session,
                anisette: anisette,
                teamID: team.teamID,
                appIDRecordID: appID.appIDRecordID
            )
            let summary = try await importProvisionedProfile(
                profileBytes,
                effectiveBundleID: effectiveBundleID,
                importer: profileImporter,
                library: profileLibrary
            )
            try await refreshPortalInventory(for: team.teamID, anisette: anisette)
            statusMessage = "Provisioned \(team.accountKind.shortLabel) certificate & profile for \(effectiveBundleID)."
            return ProvisionedSigningBundle(
                team: team,
                identityID: identityID,
                profileSummary: summary,
                effectiveBundleIdentifier: effectiveBundleID,
                appID: appID
            )
        } catch {
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    private func ensureDeviceRegistered(
        session: ApplePortalSessionToken,
        anisette: AnisetteHeaderBundle,
        teamID: String,
        udid: String?,
        deviceName: String
    ) async throws {
        guard let cleanUDID = udid?.trimmingCharacters(in: .whitespacesAndNewlines), !cleanUDID.isEmpty else { return }
        let currentDevices = try await portalClient.listDevices(session: session, anisette: anisette, teamID: teamID)
        if !currentDevices.contains(where: { $0.udid.caseInsensitiveCompare(cleanUDID) == .orderedSame }) {
            _ = try await portalClient.registerDevice(session: session, anisette: anisette, teamID: teamID, name: deviceName, udid: cleanUDID)
        }
    }

    private func mintAndRegisterIdentity(
        session: ApplePortalSessionToken,
        anisette: AnisetteHeaderBundle,
        teamID: String,
        revokeOldest: Bool
    ) async throws -> SigningIdentityIdentifier {
        let (keyTag, csrPEM) = try csrProvisioner.generateKeypairAndBuildCSR(commonName: "ZynSign Development")
        let issuedCert = try await submitCSRHandlingLimit(
            session: session,
            anisette: anisette,
            teamID: teamID,
            csrPEM: csrPEM,
            revokeOldestOnLimit: revokeOldest
        )
        guard let certDER = issuedCert.certificateDER, !certDER.isEmpty else {
            throw ServiceError.missingCertificateBytes
        }
        return try csrProvisioner.registerIssuedCertificate(certificateDER: certDER, keyTag: keyTag)
    }

    private func resolveOrRegisterAppID(
        session: ApplePortalSessionToken,
        anisette: AnisetteHeaderBundle,
        team: AppleDeveloperTeam,
        effectiveBundleID: String,
        appDisplayName: String,
        assignSharedAppGroup: Bool
    ) async throws -> ApplePortalAppID {
        let existingAppIDs = try await portalClient.listAppIDs(session: session, anisette: anisette, teamID: team.teamID)
        let appID: ApplePortalAppID
        if let existing = existingAppIDs.first(where: { $0.identifier == effectiveBundleID }) {
            appID = existing
        } else {
            let cleanAppName = appDisplayName.filter { $0.isLetter || $0.isNumber || $0 == " " }
            appID = try await portalClient.registerAppID(
                session: session,
                anisette: anisette,
                teamID: team.teamID,
                name: cleanAppName.isEmpty ? "ZynSign App" : cleanAppName,
                bundleIdentifier: effectiveBundleID
            )
        }
        if assignSharedAppGroup {
            let groupID = PersonalTeamBundleIDPlanner.scopedAppGroupIdentifier(team: team)
            try? await portalClient.ensureAppGroupAssigned(
                session: session,
                anisette: anisette,
                teamID: team.teamID,
                appIDRecordID: appID.appIDRecordID,
                groupIdentifier: groupID
            )
        }
        return appID
    }

    private func importProvisionedProfile(
        _ profileBytes: Data,
        effectiveBundleID: String,
        importer: ProvisioningProfileImporter,
        library: any ProvisioningProfileLibrary
    ) async throws -> ProvisioningProfileSummary {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zynsign-portal-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let tempProfileURL = tempDir.appendingPathComponent("\(effectiveBundleID).mobileprovision")
        try profileBytes.write(to: tempProfileURL, options: .atomic)
        let summary = try await importer.importProfile(at: tempProfileURL)
        try await library.upsert(summary)
        return summary
    }

    private func submitCSRHandlingLimit(
        session: ApplePortalSessionToken,
        anisette: AnisetteHeaderBundle,
        teamID: String,
        csrPEM: String,
        revokeOldestOnLimit: Bool
    ) async throws -> ApplePortalCertificate {
        do {
            return try await portalClient.submitDevelopmentCSR(
                session: session,
                anisette: anisette,
                teamID: teamID,
                csrPEM: csrPEM
            )
        } catch let AppleProvisioningDomainError.portalRejection(code, _) where revokeOldestOnLimit && (code == 7460 || code == 7252) {
            let current = try await portalClient.listDevelopmentCertificates(
                session: session,
                anisette: anisette,
                teamID: teamID
            )
            if let oldest = current.sorted(by: { ($0.expirationDate ?? .distantFuture) < ($1.expirationDate ?? .distantFuture) }).first {
                try await portalClient.revokeDevelopmentCertificate(
                    session: session,
                    anisette: anisette,
                    teamID: teamID,
                    serialNumber: oldest.serialNumber
                )
                return try await portalClient.submitDevelopmentCSR(
                    session: session,
                    anisette: anisette,
                    teamID: teamID,
                    csrPEM: csrPEM
                )
            }
            throw AppleProvisioningDomainError.portalRejection(code: code, message: "Maximum development certificates reached.")
        }
    }
}
