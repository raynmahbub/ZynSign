import Foundation
#if os(iOS)
import LocalAuthentication
import Security
#endif

/// `URLSession`-backed Apple Developer Services (`QH65B2`) and Anisette v3
/// client for both Free Personal Teams and Paid Developer Program memberships.
struct URLSessionAppleDeveloperPortalClient: AppleDeveloperPortalClient {

    typealias TransportLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private static let maximumResponseBytes = 4 * 1_024 * 1_024
    private static let gsaAuthEndpoint = "https://gsa.apple.com/grandslam/GsService2"
    private static let gsaTrustedDeviceVerifyURL = "https://gsa.apple.com/auth/verify/trusteddevice"
    private static let gsaValidateCodeURL = "https://gsa.apple.com/grandslam/GsService2/validate"
    private static let xcodeAuthAppName = "com.apple.gs.xcode.auth"

    private let loadData: TransportLoader

    init(loadData: @escaping TransportLoader = { try await URLSession.shared.data(for: $0) }) {
        self.loadData = loadData
    }

    func fetchAnisetteHeaders(from serverURL: URL) async throws -> AnisetteHeaderBundle {
        var req = URLRequest(url: serverURL)
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await loadData(req)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              data.count <= Self.maximumResponseBytes else {
            throw AppleProvisioningDomainError.invalidAnisettePayload
        }
        return try AnisetteHeaderBundle.decode(from: data)
    }

    func authenticate(
        appleID: String,
        password: String,
        twoFactorCode: String?,
        anisette: AnisetteHeaderBundle,
        anisetteURL: URL
    ) async throws -> ApplePortalSessionToken {
        let cleanCode = twoFactorCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return try await performGSASignIn(
            appleID: appleID,
            password: password,
            twoFactorCode: cleanCode.isEmpty ? nil : cleanCode,
            anisette: anisette,
            anisetteURL: anisetteURL,
            allowTwoFactorRetry: true
        )
    }

    private func performGSASignIn(
        appleID: String,
        password: String,
        twoFactorCode: String?,
        anisette: AnisetteHeaderBundle,
        anisetteURL: URL,
        allowTwoFactorRetry: Bool
    ) async throws -> ApplePortalSessionToken {
        let cpd = buildClientProvisioningDictionary(anisette: anisette)
        let handshake = AppleGSASRP6a.startAuthentication()

        // Step 1: SRP-6a `init`
        let initResponse = try await sendGSARequest(
            parameters: [
                "A2k": handshake.publicEphemeralA,
                "ps": ["s2k", "s2k_fo"],
                "cpd": cpd,
                "u": appleID,
                "o": "init"
            ],
            anisette: anisette
        )
        try throwIfGSAStatusFailed(initResponse)

        guard let contextCookie = initResponse["c"] as? String,
              let salt = initResponse["s"] as? Data,
              let iterations = (initResponse["i"] as? Int) ?? (initResponse["i"] as? NSNumber)?.intValue,
              let serverB = initResponse["B"] as? Data else {
            throw AppleProvisioningDomainError.portalRejection(
                code: -1,
                message: "Apple GSA server did not return a complete SRP-6a challenge."
            )
        }
        let sp = (initResponse["sp"] as? String) ?? "s2k"
        let srpProof = try AppleGSASRP6a.processChallenge(
            handshake: handshake,
            username: appleID,
            password: password,
            protocolVariant: sp,
            salt: salt,
            iterations: iterations,
            serverPublicB: serverB
        )

        // Step 2: SRP-6a `complete`
        let completeResponse = try await sendGSARequest(
            parameters: [
                "c": contextCookie,
                "M1": srpProof.clientProofM1,
                "cpd": cpd,
                "u": appleID,
                "o": "complete"
            ],
            anisette: anisette
        )
        try throwIfGSAStatusFailed(completeResponse)

        guard let spd = completeResponse["spd"] as? Data else {
            throw AppleProvisioningDomainError.portalRejection(
                code: -2,
                message: "Apple GSA server did not return an encrypted session payload."
            )
        }
        let decryptedSPD = try AppleGSASRP6a.decryptSessionPayloadCBC(
            spd: spd,
            sessionKeyK: srpProof.sessionKeyK
        )
        guard let spdPlist = try? PropertyListSerialization.propertyList(
            from: decryptedSPD, options: [], format: nil
        ) as? [String: Any],
              let adsid = spdPlist["adsid"] as? String,
              let idmsToken = spdPlist["GsIdmsToken"] as? String,
              !adsid.isEmpty, !idmsToken.isEmpty else {
            throw AppleProvisioningDomainError.portalRejection(
                code: -3,
                message: "Decrypted GSA session dictionary is missing identity tokens."
            )
        }

        let statusDict = (completeResponse["Status"] as? [String: Any]) ?? [:]
        let authAction = statusDict["au"] as? String
        if authAction == "trustedDeviceSecondaryAuth" || authAction == "secondaryAuth" {
            guard let code = twoFactorCode, !code.isEmpty, allowTwoFactorRetry else {
                await triggerTrustedDeviceVerificationPrompt(
                    dsid: adsid,
                    idmsToken: idmsToken,
                    anisette: anisette
                )
                throw AppleProvisioningDomainError.twoFactorRequired(trustedPhoneMask: authAction)
            }
            try await validateTwoFactorCode(
                code: code,
                dsid: adsid,
                idmsToken: idmsToken,
                anisette: anisette
            )
            return try await performGSASignIn(
                appleID: appleID,
                password: password,
                twoFactorCode: nil,
                anisette: anisette,
                anisetteURL: anisetteURL,
                allowTwoFactorRetry: false
            )
        }

        guard let sk = spdPlist["sk"] as? Data,
              let tokenCookie = spdPlist["c"] as? Data else {
            throw AppleProvisioningDomainError.portalRejection(
                code: -4,
                message: "GSA session response did not include apptoken session keys."
            )
        }

        // Step 3: Exchange `GsIdmsToken` for `com.apple.gs.xcode.auth` GS token
        let apps = [Self.xcodeAuthAppName]
        let checksum = AppleGSASRP6a.computeAppTokensChecksum(sk: sk, adsid: adsid, apps: apps)
        let appTokensResponse = try await sendGSARequest(
            parameters: [
                "u": adsid,
                "app": apps,
                "c": tokenCookie,
                "t": idmsToken,
                "checksum": checksum,
                "cpd": cpd,
                "o": "apptokens"
            ],
            anisette: anisette
        )
        try throwIfGSAStatusFailed(appTokensResponse)

        guard let encryptedToken = appTokensResponse["et"] as? Data else {
            throw AppleProvisioningDomainError.portalRejection(
                code: -5,
                message: "GSA apptokens response did not include an encrypted Xcode auth token."
            )
        }
        let decryptedTokenData = try AppleGSASRP6a.decryptAppTokensGCM(encryptedToken: encryptedToken, sk: sk)
        guard let tokenRoot = try? PropertyListSerialization.propertyList(
            from: decryptedTokenData, options: [], format: nil
        ) as? [String: Any],
              let tokensByApp = tokenRoot["t"] as? [String: Any],
              let xcodeTokenDict = tokensByApp[Self.xcodeAuthAppName] as? [String: Any],
              let gsToken = xcodeTokenDict["token"] as? String,
              !gsToken.isEmpty else {
            throw AppleProvisioningDomainError.portalRejection(
                code: -6,
                message: "Could not extract Xcode GrandSlam token from GSA envelope."
            )
        }

        return ApplePortalSessionToken(
            appleIDEmail: appleID,
            dsid: adsid,
            myacinfoToken: gsToken,
            anisetteServerURL: anisetteURL,
            authenticatedAt: Date()
        )
    }

    private func buildClientProvisioningDictionary(anisette: AnisetteHeaderBundle) -> [String: Any] {
        var cpd: [String: Any] = [
            "bootstrap": true,
            "icscrec": true,
            "loc": anisette.locale,
            "pbe": false,
            "prkgen": true,
            "svct": "iCloud"
        ]
        for (key, value) in anisette.httpHeaders() {
            cpd[key] = value
        }
        return cpd
    }

    private func sendGSARequest(
        parameters: [String: Any],
        anisette: AnisetteHeaderBundle
    ) async throws -> [String: Any] {
        guard let url = URL(string: Self.gsaAuthEndpoint) else {
            throw AppleProvisioningDomainError.invalidEndpointURL
        }
        let payload: [String: Any] = [
            "Header": ["Version": "1.0.1"],
            "Request": parameters
        ]
        let bodyData = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.httpBody = bodyData
        req.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        req.setValue("text/x-xml-plist", forHTTPHeaderField: "Accept")
        req.setValue("Xcode", forHTTPHeaderField: "User-Agent")
        req.setValue("en-us", forHTTPHeaderField: "Accept-Language")
        for (key, value) in anisette.httpHeaders() {
            req.setValue(value, forHTTPHeaderField: key)
        }
        let (respData, _) = try await loadData(req)
        guard respData.count <= Self.maximumResponseBytes,
              let plist = try? PropertyListSerialization.propertyList(
                from: respData, options: [], format: nil
              ) as? [String: Any] else {
            throw AppleProvisioningDomainError.portalRejection(
                code: -1,
                message: "Unreadable authentication response from Apple GSA."
            )
        }
        return (plist["Response"] as? [String: Any]) ?? plist
    }

    private func throwIfGSAStatusFailed(_ responseSection: [String: Any]) throws {
        let statusSection = (responseSection["Status"] as? [String: Any]) ?? [:]
        if let ec = (statusSection["ec"] as? Int) ?? (statusSection["ec"] as? NSNumber)?.intValue,
           ec != 0 {
            let em = (statusSection["em"] as? String) ?? "Authentication refused."
            if ec == -22406 || em.localizedCaseInsensitiveContains("verification") {
                throw AppleProvisioningDomainError.twoFactorRequired(trustedPhoneMask: statusSection["au"] as? String)
            }
            throw AppleProvisioningDomainError.portalRejection(code: ec, message: em)
        }
    }

    private func triggerTrustedDeviceVerificationPrompt(
        dsid: String,
        idmsToken: String,
        anisette: AnisetteHeaderBundle
    ) async {
        guard let url = URL(string: Self.gsaTrustedDeviceVerifyURL) else { return }
        let encodedIdentity = Data("\(dsid):\(idmsToken)".utf8).base64EncodedString()
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        applyTwoFactorHeaders(&req, encodedIdentityToken: encodedIdentity, anisette: anisette)
        _ = try? await loadData(req)
    }

    private func validateTwoFactorCode(
        code: String,
        dsid: String,
        idmsToken: String,
        anisette: AnisetteHeaderBundle
    ) async throws {
        guard let url = URL(string: Self.gsaValidateCodeURL) else {
            throw AppleProvisioningDomainError.invalidEndpointURL
        }
        let encodedIdentity = Data("\(dsid):\(idmsToken)".utf8).base64EncodedString()
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 20
        applyTwoFactorHeaders(&req, encodedIdentityToken: encodedIdentity, anisette: anisette)
        req.setValue(code, forHTTPHeaderField: "security-code")
        let (data, _) = try await loadData(req)
        guard data.count <= Self.maximumResponseBytes,
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
              ) as? [String: Any] else {
            throw AppleProvisioningDomainError.portalRejection(
                code: -21669,
                message: "Could not verify the two-factor security code."
            )
        }
        let ec = (plist["ec"] as? Int) ?? (plist["ec"] as? NSNumber)?.intValue ?? 0
        if ec != 0 {
            let em = (plist["em"] as? String) ?? "Invalid two-factor verification code."
            throw AppleProvisioningDomainError.portalRejection(code: ec, message: em)
        }
    }

    private func applyTwoFactorHeaders(
        _ req: inout URLRequest,
        encodedIdentityToken: String,
        anisette: AnisetteHeaderBundle
    ) {
        req.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        req.setValue("text/x-xml-plist", forHTTPHeaderField: "Accept")
        req.setValue("Xcode", forHTTPHeaderField: "User-Agent")
        req.setValue("en-us", forHTTPHeaderField: "Accept-Language")
        req.setValue(Self.xcodeAuthAppName, forHTTPHeaderField: "X-Apple-App-Info")
        req.setValue("11.2 (11B41)", forHTTPHeaderField: "X-Xcode-Version")
        req.setValue(encodedIdentityToken, forHTTPHeaderField: "X-Apple-Identity-Token")
        for (key, value) in anisette.httpHeaders() {
            req.setValue(value, forHTTPHeaderField: key)
        }
    }

    func listTeams(session: ApplePortalSessionToken, anisette: AnisetteHeaderBundle) async throws -> [AppleDeveloperTeam] {
        let dict = try await postPortalAction(.listTeams, session: session, anisette: anisette, fields: [:])
        let rawTeams = (dict["teams"] as? [[String: Any]]) ?? []
        return rawTeams.compactMap { item in
            guard let id = item["teamId"] as? String,
                  let name = item["name"] as? String else { return nil }
            let rawType = (item["type"] as? String) ?? "Individual"
            let memberships = (item["memberships"] as? [[String: Any]]) ?? []
            let isFree = memberships.contains { ($0["name"] as? String)?.localizedCaseInsensitiveContains("free") == true }
                || (item["currentTeamMember"] as? [String: Any])?["privileges"] == nil && rawType == "Individual" && memberships.isEmpty
            let account: SideloadAccount
            if rawType.localizedCaseInsensitiveContains("In-House") {
                account = .enterpriseProgram
            } else if isFree {
                account = .personalTeam
            } else {
                account = .developerProgram
            }
            return AppleDeveloperTeam(teamID: id, name: name, accountKind: account, rawType: rawType)
        }
    }

    func listDevices(session: ApplePortalSessionToken, anisette: AnisetteHeaderBundle, teamID: String) async throws -> [ApplePortalDevice] {
        let dict = try await postPortalAction(.listDevices, session: session, anisette: anisette, fields: ["teamId": teamID])
        let raw = (dict["devices"] as? [[String: Any]]) ?? []
        return raw.compactMap { item in
            guard let devID = item["deviceId"] as? String,
                  let udid = item["deviceNumber"] as? String else { return nil }
            let name = (item["name"] as? String) ?? "iOS Device"
            let platform = (item["devicePlatform"] as? String) ?? "ios"
            return ApplePortalDevice(deviceID: devID, name: name, udid: udid, platform: platform)
        }
    }

    func registerDevice(
        session: ApplePortalSessionToken,
        anisette: AnisetteHeaderBundle,
        teamID: String,
        name: String,
        udid: String
    ) async throws -> ApplePortalDevice {
        let dict = try await postPortalAction(
            .addDevice,
            session: session,
            anisette: anisette,
            fields: ["teamId": teamID, "name": name, "deviceNumber": udid]
        )
        let dev = (dict["device"] as? [String: Any]) ?? [:]
        return ApplePortalDevice(
            deviceID: (dev["deviceId"] as? String) ?? UUID().uuidString,
            name: (dev["name"] as? String) ?? name,
            udid: (dev["deviceNumber"] as? String) ?? udid,
            platform: "ios"
        )
    }

    func listDevelopmentCertificates(
        session: ApplePortalSessionToken,
        anisette: AnisetteHeaderBundle,
        teamID: String
    ) async throws -> [ApplePortalCertificate] {
        let dict = try await postPortalAction(.listDevelopmentCerts, session: session, anisette: anisette, fields: ["teamId": teamID])
        let raw = (dict["certificates"] as? [[String: Any]]) ?? []
        return raw.compactMap(Self.parsePortalCertificate)
    }

    func submitDevelopmentCSR(
        session: ApplePortalSessionToken,
        anisette: AnisetteHeaderBundle,
        teamID: String,
        csrPEM: String
    ) async throws -> ApplePortalCertificate {
        let dict = try await postPortalAction(
            .submitDevelopmentCSR,
            session: session,
            anisette: anisette,
            fields: ["teamId": teamID, "csrContent": csrPEM]
        )
        if let certObj = dict["certRequest"] as? [String: Any],
           let parsed = Self.parsePortalCertificate(certObj) {
            return parsed
        }
        if let certObj = dict["certificate"] as? [String: Any],
           let parsed = Self.parsePortalCertificate(certObj) {
            return parsed
        }
        throw AppleProvisioningDomainError.portalRejection(code: -2, message: "Portal accepted CSR without returning certificate data.")
    }

    func revokeDevelopmentCertificate(
        session: ApplePortalSessionToken,
        anisette: AnisetteHeaderBundle,
        teamID: String,
        serialNumber: String
    ) async throws {
        _ = try await postPortalAction(
            .revokeDevelopmentCert,
            session: session,
            anisette: anisette,
            fields: ["teamId": teamID, "serialNumber": serialNumber]
        )
    }

    func listAppIDs(session: ApplePortalSessionToken, anisette: AnisetteHeaderBundle, teamID: String) async throws -> [ApplePortalAppID] {
        let dict = try await postPortalAction(.listAppIDs, session: session, anisette: anisette, fields: ["teamId": teamID])
        let raw = (dict["appIds"] as? [[String: Any]]) ?? []
        return raw.compactMap(Self.parsePortalAppID)
    }

    func registerAppID(
        session: ApplePortalSessionToken,
        anisette: AnisetteHeaderBundle,
        teamID: String,
        name: String,
        bundleIdentifier: String
    ) async throws -> ApplePortalAppID {
        let dict = try await postPortalAction(
            .addAppID,
            session: session,
            anisette: anisette,
            fields: [
                "teamId": teamID,
                "name": name,
                "identifier": bundleIdentifier,
                "entitlements": []
            ]
        )
        if let appObj = dict["appId"] as? [String: Any], let parsed = Self.parsePortalAppID(appObj) {
            return parsed
        }
        throw AppleProvisioningDomainError.portalRejection(code: -3, message: "Portal did not return the created App ID.")
    }

    func ensureAppGroupAssigned(
        session: ApplePortalSessionToken,
        anisette: AnisetteHeaderBundle,
        teamID: String,
        appIDRecordID: String,
        groupIdentifier: String
    ) async throws {
        var resolvedGroupRecordID: String?
        if let listResp = try? await postPortalAction(
            .listAppGroups,
            session: session,
            anisette: anisette,
            fields: ["teamId": teamID]
        ), let existingGroups = listResp["applicationGroupList"] as? [[String: Any]] {
            for group in existingGroups where (group["identifier"] as? String) == groupIdentifier {
                resolvedGroupRecordID = (group["applicationGroup"] as? String)
                    ?? (group["applicationGroupId"] as? String)
                if resolvedGroupRecordID != nil { break }
            }
        }
        if resolvedGroupRecordID == nil {
            let groupResp = try await postPortalAction(
                .addAppGroup,
                session: session,
                anisette: anisette,
                fields: ["teamId": teamID, "name": "ZynSign Shared Group", "identifier": groupIdentifier]
            )
            if let groupObj = groupResp["applicationGroup"] as? [String: Any] {
                resolvedGroupRecordID = (groupObj["applicationGroup"] as? String)
                    ?? (groupObj["applicationGroupId"] as? String)
            }
        }
        if let groupRecordID = resolvedGroupRecordID, !groupRecordID.isEmpty {
            _ = try await postPortalAction(
                .assignAppGroup,
                session: session,
                anisette: anisette,
                fields: ["teamId": teamID, "appIdId": appIDRecordID, "applicationGroups": [groupRecordID]]
            )
        }
    }

    func downloadTeamProvisioningProfile(
        session: ApplePortalSessionToken,
        anisette: AnisetteHeaderBundle,
        teamID: String,
        appIDRecordID: String
    ) async throws -> Data {
        let dict = try await postPortalAction(
            .downloadTeamProvisioningProfile,
            session: session,
            anisette: anisette,
            fields: ["teamId": teamID, "appIdId": appIDRecordID]
        )
        if let profileObj = dict["provisioningProfile"] as? [String: Any],
           let encoded = profileObj["encodedProfile"] as? Data,
           !encoded.isEmpty {
            return encoded
        }
        throw AppleProvisioningDomainError.portalRejection(code: -4, message: "Portal did not return provisioning profile bytes.")
    }

    // MARK: - Internal Portal Transport

    private func postPortalAction(
        _ action: ApplePortalEndpoints.Action,
        session: ApplePortalSessionToken,
        anisette: AnisetteHeaderBundle,
        fields: [String: Any]
    ) async throws -> [String: Any] {
        let url = try action.url()
        var body: [String: Any] = [
            "clientId": "XABBG36SBA",
            "protocolVersion": ApplePortalEndpoints.protocolVersion,
            "requestId": UUID().uuidString.uppercased()
        ]
        for (k, v) in fields {
            body[k] = v
        }
        let bodyBytes = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.httpBody = bodyBytes
        req.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        req.setValue("text/x-xml-plist", forHTTPHeaderField: "Accept")
        req.setValue("Xcode", forHTTPHeaderField: "User-Agent")
        req.setValue("en-us", forHTTPHeaderField: "Accept-Language")
        req.setValue(Self.xcodeAuthAppName, forHTTPHeaderField: "X-Apple-App-Info")
        req.setValue("11.2 (11B41)", forHTTPHeaderField: "X-Xcode-Version")
        req.setValue(session.dsid, forHTTPHeaderField: "X-Apple-I-Identity-Id")
        req.setValue(session.myacinfoToken, forHTTPHeaderField: "X-Apple-GS-Token")
        for (k, v) in anisette.httpHeaders() {
            req.setValue(v, forHTTPHeaderField: k)
        }

        let (data, _) = try await loadData(req)
        guard data.count <= Self.maximumResponseBytes,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw AppleProvisioningDomainError.portalRejection(code: -5, message: "Invalid XML plist returned by Apple Developer Services.")
        }
        if let resultCode = plist["resultCode"] as? Int, resultCode != 0 {
            let msg = (plist["userString"] as? String)
                ?? (plist["resultString"] as? String)
                ?? "Developer Portal error \(resultCode)"
            throw AppleProvisioningDomainError.portalRejection(code: resultCode, message: msg)
        }
        return plist
    }

    private static func parsePortalCertificate(_ item: [String: Any]) -> ApplePortalCertificate? {
        let certID = (item["certificateId"] as? String)
            ?? (item["certRequestId"] as? String)
            ?? ""
        guard !certID.isEmpty else { return nil }
        let name = (item["name"] as? String) ?? "Apple Development"
        let serial = (item["serialNumber"] as? String) ?? certID
        let exp = item["expirationDate"] as? Date
        let der = item["certContent"] as? Data
        return ApplePortalCertificate(
            certificateID: certID,
            name: name,
            serialNumber: serial,
            expirationDate: exp,
            certificateDER: der
        )
    }

    private static func parsePortalAppID(_ item: [String: Any]) -> ApplePortalAppID? {
        guard let recordID = item["appIdId"] as? String,
              let identifier = item["identifier"] as? String else {
            return nil
        }
        let prefix = (item["prefix"] as? String) ?? ""
        let name = (item["name"] as? String) ?? identifier
        let exp = item["expirationDate"] as? Date
        return ApplePortalAppID(
            appIDRecordID: recordID,
            identifier: identifier,
            prefix: prefix,
            name: name,
            expiresAt: exp
        )
    }
}

/// Keychain-backed RSA-2048 keypair generator and CSR signer that registers
/// Apple-issued development certificates directly into `SecureIdentityStore`
/// without ever exporting private-key bytes outside the Keychain.
struct KeychainCSRIdentityProvisioner: CSRKeypairProvisioning {

    private let identityStore: any IdentityStore

    init(identityStore: any IdentityStore) {
        self.identityStore = identityStore
    }

    func generateKeypairAndBuildCSR(commonName: String) throws -> (keyTag: String, csrPEM: String) {
        #if os(iOS)
        let tag = "io.zynsign.portal.csr.\(UUID().uuidString)"
        guard let tagData = tag.data(using: .utf8) else {
            throw ZynSignError.identity(.privateKeyUnavailable)
        }
        let privateKeyAttrs: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: tagData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: privateKeyAttrs
        ]
        var genError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &genError),
              let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw ZynSignError.identity(.privateKeyUnavailable)
        }
        var pubError: Unmanaged<CFError>?
        guard let publicKeyDER = SecKeyCopyExternalRepresentation(publicKey, &pubError) as Data? else {
            throw ZynSignError.identity(.certificateUnavailable)
        }
        let csrInfoDER = try PKCS10CertificateRequestBuilder.buildCertificationRequestInfoDER(
            rsaPublicKeyDER: publicKeyDER,
            commonName: commonName
        )
        var signError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            csrInfoDER as CFData,
            &signError
        ) as Data? else {
            throw ZynSignError.identity(.privateKeyUnavailable)
        }
        let assembled = PKCS10CertificateRequestBuilder.assembleSignedCSR(
            certificationRequestInfoDER: csrInfoDER,
            signatureBytes: signature
        )
        return (tag, assembled.pem)
        #else
        throw ZynSignError.identity(.platformRestriction)
        #endif
    }

    func registerIssuedCertificate(certificateDER: Data, keyTag: String) throws -> SigningIdentityIdentifier {
        #if os(iOS)
        guard let secureStore = identityStore as? SecureIdentityStore,
              let tagData = keyTag.data(using: .utf8) else {
            throw ZynSignError.identity(.platformRestriction)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrApplicationTag as String: tagData,
            kSecReturnPersistentRef as String: true,
            kSecUseAuthenticationContext as String: IdentityKeychainAccess.noninteractiveContext()
        ]
        var refResult: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &refResult)
        guard status == errSecSuccess,
              let persistentRef = refResult as? Data,
              !persistentRef.isEmpty else {
            throw ZynSignError.identity(.privateKeyUnavailable)
        }
        return try secureStore.register(certificateDER: certificateDER, keyReference: persistentRef)
        #else
        throw ZynSignError.identity(.platformRestriction)
        #endif
    }
}
