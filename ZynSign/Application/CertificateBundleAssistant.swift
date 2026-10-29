import Foundation

/// Application-layer helper for `.zcert` identity archives, `.p12` passphrase
/// recovery, and provisioning profile UDID / entitlements inspection.
enum CertificateBundleAssistant {

    struct ImportedIdentityArchiveOutcome: Equatable, Sendable {
        let packageName: String
        let identityID: SigningIdentityIdentifier
        let profileSummary: ProvisioningProfileSummary
    }

    struct PasswordRecoveryOutcome: Equatable, Sendable {
        let matchedPassword: String
        let identityID: SigningIdentityIdentifier
        let testedCount: Int
    }

    enum AssistantError: Error, LocalizedError {
        case missingProfileServices
        case passwordNotRecovered(testedCount: Int)

        var errorDescription: String? {
            switch self {
            case .missingProfileServices:
                return "Provisioning profile storage is not available in this environment."
            case .passwordNotRecovered(let count):
                return "Tested \(count) candidate password(s) without finding a match."
            }
        }
    }

    /// Imports both the PKCS#12 identity and `.mobileprovision` from a `.zcert` archive.
    static func importIdentityArchive(
        data: Data,
        passwordOverride: String? = nil,
        pkcs12Importer: any SigningIdentityImporter,
        profileImporter: ProvisioningProfileImporter?,
        profileLibrary: (any ProvisioningProfileLibrary)?
    ) async throws -> ImportedIdentityArchiveOutcome {
        guard let profileImporter, let profileLibrary else {
            throw AssistantError.missingProfileServices
        }
        let package = try ZynCertificateBundleCodec.decode(data)
        let effectivePassword: String
        if let override = passwordOverride, !override.isEmpty {
            effectivePassword = override
        } else {
            effectivePassword = package.password
        }

        let identityID = try pkcs12Importer.importPKCS12(data: package.p12Data, password: effectivePassword)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zynsign-zcert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tempProfileURL = tempDir.appendingPathComponent("\(package.name).mobileprovision")
        try package.mobileProvisionData.write(to: tempProfileURL, options: .atomic)
        let summary = try await profileImporter.importProfile(at: tempProfileURL)
        try await profileLibrary.upsert(summary)

        return ImportedIdentityArchiveOutcome(
            packageName: package.name,
            identityID: identityID,
            profileSummary: summary
        )
    }

    /// Tests a bounded candidate passphrase list against `pkcs12Importer`,
    /// importing the identity into Keychain as soon as a password matches.
    static func recoverAndImportPKCS12(
        data: Data,
        fileName: String,
        customWordlist: String,
        importer: any SigningIdentityImporter
    ) async throws -> PasswordRecoveryOutcome {
        let customLines = customWordlist
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let candidates = ZynCertificateBundleCodec.generatePassphraseCandidates(
            fileName: fileName,
            customCandidates: customLines
        )
        var tested = 0
        for candidate in candidates {
            try Task.checkCancellation()
            tested += 1
            do {
                let id = try importer.importPKCS12(data: data, password: candidate)
                return PasswordRecoveryOutcome(
                    matchedPassword: candidate,
                    identityID: id,
                    testedCount: tested
                )
            } catch let zErr as ZynSignError {
                // If already registered, surface immediately rather than masking it.
                if zErr.userMessage.localizedCaseInsensitiveContains("already") {
                    throw zErr
                }
                continue
            } catch {
                continue
            }
        }
        throw AssistantError.passwordNotRecovered(testedCount: tested)
    }

    /// Reads provisioned device UDIDs and canonical entitlements XML from stored profile bytes.
    static func inspectStoredProfileDetails(profileBytes: Data) -> (udids: [String], entitlementsXML: String?) {
        let payload: Data
        if let cms = try? CMSStructureReader.read(profileBytes), let content = cms.encapsulatedContent {
            payload = content
        } else if let range = profileBytes.range(of: Data("<?xml".utf8)) {
            payload = profileBytes.subdata(in: range.lowerBound..<profileBytes.endIndex)
        } else if let range = profileBytes.range(of: Data("bplist00".utf8)) {
            payload = profileBytes.subdata(in: range.lowerBound..<profileBytes.endIndex)
        } else {
            payload = profileBytes
        }

        let udids = (try? PropertyListProvisioningProfileParser()
            .parse(ProvisioningProfilePayload(plistData: payload))
            .provisionedDevices) ?? []
        let xml: String?
        if let derived = try? ProfileEntitlementDerivation.entitlements(fromProvisioningProfile: profileBytes),
           let xmlData = try? derived.canonicalXMLData() {
            xml = String(data: xmlData, encoding: .utf8)
        } else {
            xml = nil
        }
        return (udids.map(\.rawValue), xml)
    }
}
