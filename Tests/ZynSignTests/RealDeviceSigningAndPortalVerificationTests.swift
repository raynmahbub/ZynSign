import CommonCrypto
import CryptoKit
import Foundation
import XCTest
@testable import ZynSign

final class RealDeviceSigningAndPortalVerificationTests: XCTestCase {

    private static let insideValidity = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - 1. Wildcard Entitlement Concretization

    func testConcreteProfileEntitlementsExpandsWildcardAppIDAndKeychainGroups() throws {
        let profile = ProvisioningProfile(
            uuid: "00000000-1111-2222-3333-444444444444",
            name: "Wildcard Dev Profile",
            appIDName: "Wildcard",
            applicationIdentifierPrefix: ["TEAM998877"],
            teamIdentifier: ["TEAM998877"],
            teamName: "Zyn Team",
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            expirationDate: Date(timeIntervalSince1970: 1_900_000_000),
            entitlements: [
                "application-identifier": .string("TEAM998877.*"),
                "com.apple.developer.team-identifier": .string("TEAM998877"),
                "get-task-allow": .bool(true),
                "keychain-access-groups": .array([
                    .string("TEAM998877.*"),
                    .string("TEAM998877.com.zyn.shared.keychain")
                ]),
                "com.apple.security.application-groups": .array([
                    .string("group.com.zyn.shared")
                ])
            ],
            provisionedDevices: ["00008110-0011223344556677"],
            provisionsAllDevices: false,
            developerCertificates: [],
            platforms: ["iOS"],
            isXcodeManaged: false
        )
        let targetBundle = try BundleIdentifier(validating: "com.zyn.sideload.demo")
        let derived = try ProfileEntitlementDerivation.entitlements(
            fromProvisioningProfile: profile,
            forBundleIdentifier: targetBundle
        )

        XCTAssertEqual(
            derived.values["application-identifier"],
            .string("TEAM998877.com.zyn.sideload.demo")
        )
        XCTAssertEqual(
            derived.values["keychain-access-groups"],
            .array([
                .string("TEAM998877.com.zyn.sideload.demo"),
                .string("TEAM998877.com.zyn.shared.keychain")
            ])
        )
        XCTAssertEqual(
            derived.values["com.apple.security.application-groups"],
            .array([.string("group.com.zyn.shared")])
        )
    }

    // MARK: - 2. Pre-Sign Bundle Validator (Loose Dylib + Fat Arm64 + Replace Signature + Pruned AppEx)

    func testBundleValidatorAllowsLooseFrameworkDylibFatArm64AndRemovedExtensions() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zynsign-validator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let appDir = tempDir.appendingPathComponent("Sample.app", isDirectory: true)
        let frameworksDir = appDir.appendingPathComponent("Frameworks", isDirectory: true)
        let pluginsDir = appDir.appendingPathComponent("PlugIns/Widget.appex", isDirectory: true)
        try FileManager.default.createDirectory(at: frameworksDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)

        let infoXML = Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
              <key>CFBundleIdentifier</key><string>com.example.sample</string>
              <key>CFBundleExecutable</key><string>Sample</string>
            </dict></plist>
            """.utf8
        )
        try infoXML.write(to: appDir.appendingPathComponent("Info.plist"))

        let preSignedThin = try AdHocMachOSigner().signMachO(
            MachOSigningFixtures.unsignedMachO,
            identifier: "com.example.sample"
        ).signedBytes
        let fatPreSigned = Self.wrapInUniversalFatHeader(arm64Slice: preSignedThin)
        try fatPreSigned.write(to: appDir.appendingPathComponent("Sample"))

        // Loose dylib in Frameworks/ has NO Info.plist by Apple design.
        let looseDylibSigned = try AdHocMachOSigner().signMachO(
            MachOSigningFixtures.unsignedMachO,
            identifier: "Helper"
        ).signedBytes
        try looseDylibSigned.write(to: frameworksDir.appendingPathComponent("Helper.dylib"))

        // Broken/unprovisioned extension without Info.plist that user asked to strip.
        try Data("placeholder".utf8).write(to: pluginsDir.appendingPathComponent("Widget"))

        var sideload = SideloadSigningOptions.none
        sideload.removesNestedExtensions = true

        XCTAssertNoThrow(
            try SigningEngineBundleValidator().validate(
                bundleDirectory: appDir,
                bundleArchivePath: try XCTUnwrap(ArchivePath(rawValue: "Payload/Sample.app")),
                replacesExistingSignatures: true,
                sideload: sideload
            )
        )
    }

    // MARK: - 3. Real-Device Deferred UDID + Fat Pre-Signed IPA + Loose Dylib + CodeDirectory TeamID

    func testPipelineReSignsFatPreSignedAppWithLooseDylibDeferredDeviceAndTeamID() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zynsign-resign-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let identities = try NestedSigningTestIdentityStore()
        let preSignedRoot = try AdHocMachOSigner().signMachO(
            MachOSigningFixtures.unsignedMachO,
            identifier: ProvisioningPolicyFixtures.bundleIdentifier
        ).signedBytes
        let fatRoot = Self.wrapInUniversalFatHeader(arm64Slice: preSignedRoot)
        let looseDylib = try AdHocMachOSigner().signMachO(
            MachOSigningFixtures.unsignedMachO,
            identifier: "HelperDylib"
        ).signedBytes

        let infoData = Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
              <key>CFBundleIdentifier</key><string>\(ProvisioningPolicyFixtures.bundleIdentifier)</string>
              <key>CFBundleExecutable</key><string>Synthetic</string>
              <key>CFBundleShortVersionString</key><string>1.0</string>
              <key>CFBundleVersion</key><string>1</string>
              <key>MinimumOSVersion</key><string>17.0</string>
              <key>UIDeviceFamily</key><array><integer>1</integer></array>
            </dict></plist>
            """.utf8
        )

        let sourceURL = tempDir.appendingPathComponent("FatPreSigned.ipa")
        let archiveBytes = ZipFixtureBuilder.archive([
            .directory("Payload"),
            .directory("Payload/Synthetic.app"),
            ZipFixtureBuilder.Entry(name: "Payload/Synthetic.app/Info.plist", content: Array(infoData)),
            ZipFixtureBuilder.Entry(
                name: "Payload/Synthetic.app/Synthetic",
                content: Array(fatRoot),
                unixMode: 0o100_755
            ),
            .directory("Payload/Synthetic.app/Frameworks"),
            ZipFixtureBuilder.Entry(
                name: "Payload/Synthetic.app/Frameworks/HelperDylib.dylib",
                content: Array(looseDylib),
                unixMode: 0o100_755
            )
        ])
        try Data(archiveBytes).write(to: sourceURL)

        let outputURL = tempDir.appendingPathComponent("ReSigned.ipa")
        let pipeline = Self.makePipeline(identities: identities)
        let teamID = try CodeDirectoryTeamIdentifier(validating: "TEAM123456")

        let result = try await pipeline.sign(SignApplicationRequest(
            sourceURL: sourceURL,
            profile: CMSFixtures.validRSASignedAttributes,
            identityID: identities.id,
            entitlements: try CodeSigningEntitlements(values: [:]),
            outputURL: outputURL,
            teamIdentifier: teamID,
            options: SignApplicationOptions(
                deviceContext: .unspecified,
                allowDeferredDeviceCoverage: true,
                replacesExistingSignatures: true
            )
        ))

        XCTAssertEqual(result.status, .signed, "Expected signing to succeed with deferred device coverage; got \(String(describing: result.failure))")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

        let extractDir = tempDir.appendingPathComponent("Extracted", isDirectory: true)
        let reader = ZipArchiveReader(url: outputURL)
        defer { reader.close() }
        _ = try await DirectoryArchiveExtractor(
            destination: extractDir,
            policy: ArchiveExtractionPolicy(
                maximumExtractedBytes: ArchiveLimits.default.maximumTotalUncompressedBytes,
                maximumLinkTargetBytes: ArchiveLimits.default.maximumEntryNameLength,
                symlinkPolicy: .recreateWithinRoot
            ),
            fileSystem: LocalArchiveExtractionFileSystem(),
            reader: reader
        ).extractAll()

        let signedMainBytes = try Data(
            contentsOf: extractDir.appendingPathComponent("Payload/Synthetic.app/Synthetic")
        )
        let parsedMain = try ReadOnlyMachOParser().parse(signedMainBytes)
        guard case .thin(let slice) = parsedMain.container,
              let embedded = slice.embeddedSignature,
              let cdEntry = embedded.superBlob.entries.first(where: { $0.slot == .codeDirectory }),
              let cd = cdEntry.codeDirectory else {
            return XCTFail("Expected thin arm64 signed Mach-O with CodeDirectory")
        }
        XCTAssertEqual(cd.identifier, ProvisioningPolicyFixtures.bundleIdentifier)
        XCTAssertEqual(cd.teamID, "TEAM123456")
        XCTAssertGreaterThanOrEqual(cd.version, 0x0002_0400)
    }

    // MARK: - 4. Apple GSA SRP-6a + 2FA + AppTokens GCM + QH65B2 Headers

    func testAppleGSASRP6aSessionEnvelopesAndPortalClient2FAFlow() async throws {
        // Test CBC `spd` round-trip and GCM `"XYZ"` `et` round-trip
        let sessionKeyK = Data((0..<32).map { UInt8($0 + 1) })
        let sk = Data((0..<32).map { UInt8(0xA0 + $0) })
        let tokenCookie = Data("cookie-token".utf8)
        let spdDict: [String: Any] = [
            "adsid": "001234-99-88776655",
            "GsIdmsToken": "idms-secret-token",
            "sk": sk,
            "c": tokenCookie
        ]
        let spdPlain = try PropertyListSerialization.data(fromPropertyList: spdDict, format: .xml, options: 0)
        let encryptedSPD = try Self.encryptCBC(
            plaintext: spdPlain,
            key: AppleGSASRP6a.deriveSessionSubkey(sessionKeyK: sessionKeyK, label: "extra data key:"),
            iv: Data(AppleGSASRP6a.deriveSessionSubkey(sessionKeyK: sessionKeyK, label: "extra data iv:").prefix(16))
        )
        let decryptedSPD = try AppleGSASRP6a.decryptSessionPayloadCBC(spd: encryptedSPD, sessionKeyK: sessionKeyK)
        XCTAssertEqual(decryptedSPD, spdPlain)

        let tokenPlist: [String: Any] = [
            "t": [
                "com.apple.gs.xcode.auth": [
                    "token": "gs-xcode-live-token"
                ]
            ]
        ]
        let tokenPlain = try PropertyListSerialization.data(fromPropertyList: tokenPlist, format: .xml, options: 0)
        let encryptedET = try Self.encryptXYZAppTokenGCM(plaintext: tokenPlain, sk: sk)
        let decryptedET = try AppleGSASRP6a.decryptAppTokensGCM(encryptedToken: encryptedET, sk: sk)
        XCTAssertEqual(decryptedET, tokenPlain)

        // End-to-end URLSessionAppleDeveloperPortalClient mock GSA + 2FA + QH65B2 test
        let password = "CorrectHorseBatteryStaple!"
        let salt = Data((0..<16).map { UInt8(0x30 + $0) })
        let iterations = 1_000
        let serverSecretB = Data(repeating: 0x07, count: 32)
        let serverChallengeB = try AppleGSASRP6a.makeServerPublicEphemeral(
            password: password,
            protocolVariant: "s2k",
            salt: salt,
            iterations: iterations,
            serverSecretB: serverSecretB
        )

        let recorder = GSAMockRecorder(
            password: password,
            salt: salt,
            iterations: iterations,
            serverSecretB: serverSecretB,
            serverPublicB: serverChallengeB,
            sk: sk,
            encryptedET: encryptedET
        )

        let client = URLSessionAppleDeveloperPortalClient { req in
            try await recorder.handle(req)
        }
        let anisette = AnisetteHeaderBundle(
            machineID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            oneTimePassword: "OTP123456",
            localUserID: "LOCALUSER",
            routingInfo: "17106176",
            deviceUniqueIdentifier: "00008110-0011223344556677",
            clientTime: "2026-10-30T12:00:00Z",
            locale: "en_US",
            timeZone: "UTC",
            clientInfo: "<iPhone16,2> <iPhone OS;18.0;22A3354> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>"
        )

        let sessionToken = try await client.authenticate(
            appleID: "user@example.com",
            password: password,
            twoFactorCode: "654321",
            anisette: anisette,
            anisetteURL: try XCTUnwrap(URL(string: "https://anisette.example.com/v3"))
        )
        XCTAssertEqual(sessionToken.dsid, "001234-99-88776655")
        XCTAssertEqual(sessionToken.myacinfoToken, "gs-xcode-live-token")
        let validatedCode = await recorder.validatedTwoFactorCode
        XCTAssertEqual(validatedCode, "654321")

        let teams = try await client.listTeams(session: sessionToken, anisette: anisette)
        XCTAssertEqual(teams.count, 1)
        XCTAssertEqual(teams.first?.teamID, "TEAMFREE01")

        try await client.ensureAppGroupAssigned(
            session: sessionToken,
            anisette: anisette,
            teamID: "TEAMFREE01",
            appIDRecordID: "APPIDREC01",
            groupIdentifier: "group.com.zyn.host"
        )
        let assignedGroups = await recorder.assignedApplicationGroups
        XCTAssertEqual(assignedGroups, ["GROUPREC99"])
        let portalHeaders = await recorder.lastPortalHeaders
        XCTAssertEqual(portalHeaders["Accept-Language"], "en-us")
        XCTAssertEqual(portalHeaders["X-Apple-I-Identity-Id"], "001234-99-88776655")
        XCTAssertEqual(portalHeaders["X-Apple-GS-Token"], "gs-xcode-live-token")
        XCTAssertEqual(portalHeaders["X-Apple-App-Info"], "com.apple.gs.xcode.auth")
    }

    // MARK: - 5. Pairing Record Canonical UUID HostID

    func testPairingRecordCodingAcceptsCanonicalUUIDHostIDAndRejectsInvalidString() throws {
        let hostCert = Data("synthetic-host-cert".utf8)
        let uuidHostID = "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"
        let plistDict: [String: Any] = [
            "DeviceCertificate": Data("dev-cert".utf8),
            "RootCertificate": Data("root-cert".utf8),
            "HostCertificate": hostCert,
            "HostPrivateKey": Data("host-key".utf8),
            "HostID": uuidHostID.lowercased(),
            "SystemBUID": "30142556-7788-99AA-BBCC-DDEEFF001122"
        ]
        let xml = try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
        let decoded = try PairingRecordCoding.decode(xml, digest: CryptoKitMessageDigest())
        XCTAssertEqual(decoded.hostIdentifier, uuidHostID)

        var badDict = plistDict
        badDict["HostID"] = "DEADBEEF"
        let badXML = try PropertyListSerialization.data(fromPropertyList: badDict, format: .xml, options: 0)
        XCTAssertThrowsError(try PairingRecordCoding.decode(badXML, digest: CryptoKitMessageDigest()))
    }

    // MARK: - 6. Community Feed Schema Normalization

    func testEncodedCatalogPayloadDecoderNormalizesCommunityFeedQuirks() throws {
        let quirkyFeed = """
        {
          "identifier": "io.community.sideload",
          "featuredApps": ["com.community.alpha", "com.missing.ghost"],
          "apps": [
            {
              "name": "Alpha Tool",
              "bundleID": "com.community.alpha",
              "version": "2.4.1",
              "versionDate": "",
              "size": "48234496",
              "down": "https://cdn.example.com/AlphaTool.ipa",
              "icon": "https://cdn.example.com/alpha.png",
              "screenshots": {
                "iphone": [
                  { "imageURL": "https://cdn.example.com/shot1.png" }
                ]
              }
            },
            {
              "name": "Alpha Tool Duplicate Variant",
              "bundleID": "com.community.alpha",
              "version": "2.4.0",
              "size": 0,
              "down": "https://cdn.example.com/AlphaToolOld.ipa"
            }
          ]
        }
        """
        let normalized = EncodedCatalogPayloadDecoder.normalizeManifestPayload(Data(quirkyFeed.utf8))
        let parsed = try StoreManifestValidator().parse(
            normalized,
            sourceID: UUID(),
            url: try XCTUnwrap(URL(string: "https://cdn.example.com/repo.json"))
        )
        XCTAssertEqual(parsed.name, "io.community.sideload")
        XCTAssertEqual(parsed.apps.count, 1)
        let alpha = try XCTUnwrap(parsed.apps.first)
        XCTAssertEqual(alpha.bundleID, "com.community.alpha")
        XCTAssertEqual(alpha.developer, "io.community.sideload")
        XCTAssertEqual(alpha.latest.size, 48_234_496)
        XCTAssertEqual(alpha.screenshots.count, 1)
        XCTAssertTrue(alpha.featured)
    }

    // MARK: - Helpers

    private static func makePipeline(identities: NestedSigningTestIdentityStore) -> SignApplicationPipeline {
        let validationIdentities = TestIdentityStore()
        let metadata = ProvisioningPolicyFixtures.identityMetadata(
            fingerprint: ProvisioningPolicyFixtures.fingerprint(CMSFixtures.signerCertificateFingerprint)
        )
        validationIdentities.identities = [
            SigningIdentity(
                id: identities.id,
                certificate: metadata.certificate,
                keyAvailability: metadata.keyAvailability,
                association: metadata.association,
                capabilityState: metadata.capabilityState
            )
        ]
        return SignApplicationPipeline(
            identities: identities,
            digest: CryptoKitMessageDigest(),
            signatureVerifier: NestedSigningTestVerifier(),
            profileValidation: ValidateProvisioningProfileUseCase(
                profileVerification: ProvisioningProfileVerificationUseCase(
                    cmsVerifier: ProvisioningProfileCMSVerifier(
                        certificateParser: AppleCertificateParser(),
                        signatureVerifier: RecordingCMSSignatureVerifier()
                    ),
                    inspection: ProvisioningProfileInspectionUseCase(
                        payloadDecoder: UnusedPayloadDecoder(),
                        parser: PropertyListProvisioningProfileParser(certificateParser: AppleCertificateParser()),
                        clock: FixedEvaluationClock(instant: insideValidity)
                    ),
                    identityStore: validationIdentities
                ),
                configurationValidation: ValidateProvisioningConfigurationUseCase(
                    policyValidator: ProvisioningPolicyValidator(clock: FixedEvaluationClock(instant: insideValidity)),
                    identityStore: validationIdentities
                )
            ),
            writer: ZipArchiveWriter()
        )
    }

    private static func wrapInUniversalFatHeader(arm64Slice: Data) -> Data {
        var fat = Data(count: 28)
        func put32BE(_ o: Int, _ v: UInt32) {
            fat[o] = UInt8((v >> 24) & 0xFF)
            fat[o + 1] = UInt8((v >> 16) & 0xFF)
            fat[o + 2] = UInt8((v >> 8) & 0xFF)
            fat[o + 3] = UInt8(v & 0xFF)
        }
        put32BE(0, 0xCAFE_BABE)
        put32BE(4, 1)
        put32BE(8, 0x0100_000C)
        put32BE(12, 0)
        put32BE(16, 16_384)
        put32BE(20, UInt32(arm64Slice.count))
        put32BE(24, 14)
        fat.append(Data(repeating: 0, count: 16_384 - 28))
        fat.append(arm64Slice)
        return fat
    }

    static func encryptCBC(plaintext: Data, key: Data, iv: Data) throws -> Data {
        var out = [UInt8](repeating: 0, count: plaintext.count + kCCBlockSizeAES128)
        var moved = 0
        let status: CCCryptorStatus = plaintext.withUnsafeBytes { inPtr in
            key.withUnsafeBytes { keyPtr in
                iv.withUnsafeBytes { ivPtr in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyPtr.baseAddress,
                        kCCKeySizeAES256,
                        ivPtr.baseAddress,
                        inPtr.baseAddress,
                        plaintext.count,
                        &out,
                        out.count,
                        &moved
                    )
                }
            }
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        return Data(out.prefix(moved))
    }

    private static func encryptXYZAppTokenGCM(plaintext: Data, sk: Data) throws -> Data {
        let header = Data("XYZ".utf8)
        let ivBytes = Data((0..<16).map { UInt8(0x50 + $0) })
        let nonce = try AES.GCM.Nonce(data: ivBytes)
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: sk), nonce: nonce, authenticating: header)
        var envelope = Data()
        envelope.append(header)
        envelope.append(ivBytes)
        envelope.append(sealed.ciphertext)
        envelope.append(sealed.tag)
        return envelope
    }
}

private actor GSAMockRecorder {
    let password: String
    let salt: Data
    let iterations: Int
    let serverSecretB: Data
    let serverPublicB: Data
    let sk: Data
    let encryptedET: Data

    private var completedOnce = false
    private var lastClientA = Data()
    private(set) var validatedTwoFactorCode: String?
    private(set) var assignedApplicationGroups: [String] = []
    private(set) var lastPortalHeaders: [String: String] = [:]

    init(
        password: String,
        salt: Data,
        iterations: Int,
        serverSecretB: Data,
        serverPublicB: Data,
        sk: Data,
        encryptedET: Data
    ) {
        self.password = password
        self.salt = salt
        self.iterations = iterations
        self.serverSecretB = serverSecretB
        self.serverPublicB = serverPublicB
        self.sk = sk
        self.encryptedET = encryptedET
    }

    func handle(_ req: URLRequest) throws -> (Data, URLResponse) {
        let url = try XCTUnwrap(req.url)
        let ok = try XCTUnwrap(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
        )

        if url.absoluteString.contains("GsService2/validate") {
            validatedTwoFactorCode = req.value(forHTTPHeaderField: "security-code")
            let data = try PropertyListSerialization.data(fromPropertyList: ["ec": 0], format: .xml, options: 0)
            return (data, ok)
        }

        if url.absoluteString.contains("GsService2") {
            let body = try XCTUnwrap(req.httpBody)
            let root = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: body, options: [], format: nil) as? [String: Any]
            )
            let requestDict = try XCTUnwrap(root["Request"] as? [String: Any])
            let op = try XCTUnwrap(requestDict["o"] as? String)
            switch op {
            case "init":
                lastClientA = try XCTUnwrap(requestDict["A2k"] as? Data)
                let resp: [String: Any] = [
                    "Response": [
                        "Status": ["ec": 0],
                        "c": "gsa-ctx-cookie",
                        "s": salt,
                        "i": iterations,
                        "sp": "s2k",
                        "B": serverPublicB
                    ]
                ]
                return (try PropertyListSerialization.data(fromPropertyList: resp, format: .xml, options: 0), ok)

            case "complete":
                return try makeExactServerCompleteResponse(ok: ok)

            case "apptokens":
                let resp: [String: Any] = [
                    "Response": [
                        "Status": ["ec": 0],
                        "et": encryptedET
                    ]
                ]
                return (try PropertyListSerialization.data(fromPropertyList: resp, format: .xml, options: 0), ok)

            default:
                throw URLError(.badServerResponse)
            }
        }

        // QH65B2 Developer Portal actions
        lastPortalHeaders = req.allHTTPHeaderFields ?? [:]
        if url.absoluteString.contains("listTeams.action") {
            let resp: [String: Any] = [
                "resultCode": 0,
                "teams": [
                    [
                        "teamId": "TEAMFREE01",
                        "name": "Personal Team",
                        "type": "Individual",
                        "memberships": [["name": "Free Apple Developer"]]
                    ]
                ]
            ]
            return (try PropertyListSerialization.data(fromPropertyList: resp, format: .xml, options: 0), ok)
        }
        if url.absoluteString.contains("listApplicationGroups.action") {
            let resp: [String: Any] = [
                "resultCode": 0,
                "applicationGroupList": [
                    [
                        "identifier": "group.com.zyn.host",
                        "applicationGroup": "GROUPREC99"
                    ]
                ]
            ]
            return (try PropertyListSerialization.data(fromPropertyList: resp, format: .xml, options: 0), ok)
        }
        if url.absoluteString.contains("assignApplicationGroupToAppId.action") {
            let body = try XCTUnwrap(req.httpBody)
            let plist = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: body, options: [], format: nil) as? [String: Any]
            )
            assignedApplicationGroups = (plist["applicationGroups"] as? [String]) ?? []
            return (try PropertyListSerialization.data(fromPropertyList: ["resultCode": 0], format: .xml, options: 0), ok)
        }

        throw URLError(.unsupportedURL)
    }

    private func makeExactServerCompleteResponse(ok: HTTPURLResponse) throws -> (Data, URLResponse) {
        let sessionKeyK = try AppleGSASRP6a.deriveServerSessionKey(
            clientPublicA: lastClientA,
            serverSecretB: serverSecretB,
            serverPublicB: serverPublicB,
            password: password,
            protocolVariant: "s2k",
            salt: salt,
            iterations: iterations
        )
        let spdDict: [String: Any] = [
            "adsid": "001234-99-88776655",
            "GsIdmsToken": "idms-secret-token",
            "sk": sk,
            "c": Data("cookie-token".utf8)
        ]
        let spdPlain = try PropertyListSerialization.data(fromPropertyList: spdDict, format: .xml, options: 0)
        let encryptedSPD = try RealDeviceSigningAndPortalVerificationTests.encryptCBC(
            plaintext: spdPlain,
            key: AppleGSASRP6a.deriveSessionSubkey(sessionKeyK: sessionKeyK, label: "extra data key:"),
            iv: Data(AppleGSASRP6a.deriveSessionSubkey(sessionKeyK: sessionKeyK, label: "extra data iv:").prefix(16))
        )
        let status: [String: Any]
        if !completedOnce {
            completedOnce = true
            status = ["ec": 0, "au": "trustedDeviceSecondaryAuth"]
        } else {
            status = ["ec": 0]
        }
        let resp: [String: Any] = [
            "Response": [
                "Status": status,
                "spd": encryptedSPD
            ]
        ]
        return (try PropertyListSerialization.data(fromPropertyList: resp, format: .xml, options: 0), ok)
    }
}
