import XCTest
@testable import ZynSign

/// Tests for the sideloading layer: package edits, the Mach-O injection plan,
/// the device wire protocols, and the guest-container assessment.
///
/// The byte-level expectations here are the same values the host suite in
/// `Tests/Host/zynsim` produces with an independent implementation. Where the
/// two agree, a mistake has to have been made twice, in two languages, in the
/// same direction.
final class SideloadSigningOptionTests: XCTestCase {

    func testValidOptionsPass() throws {
        let options = SideloadSigningOptions(
            bundleIdentifier: "com.example.demo",
            displayName: "Demo",
            shortVersion: "1.2.3",
            version: "42",
            minimumOSVersion: "15.0",
            removesPlugIns: true,
            injectedLibraries: [InjectedLibrary(installName: "@rpath/Tweak.dylib")])
        XCTAssertNoThrow(try options.validate(hasCertificate: true))
    }

    func testReverseDNSIdentifiers() {
        XCTAssertTrue(SideloadSigningOptions.isReverseDNS("com.example.demo"))
        XCTAssertTrue(SideloadSigningOptions.isReverseDNS("io.github.user-app.app"))
        XCTAssertFalse(SideloadSigningOptions.isReverseDNS("demo"))
        XCTAssertFalse(SideloadSigningOptions.isReverseDNS("com..demo"))
        XCTAssertFalse(SideloadSigningOptions.isReverseDNS("com.example.demo/"))
        XCTAssertFalse(SideloadSigningOptions.isReverseDNS("com.example.демо"))
    }

    func testVersionStrings() {
        XCTAssertTrue(SideloadSigningOptions.isVersionString("1"))
        XCTAssertTrue(SideloadSigningOptions.isVersionString("1.2"))
        XCTAssertTrue(SideloadSigningOptions.isVersionString("1.2.3"))
        XCTAssertFalse(SideloadSigningOptions.isVersionString("1.2.3.4"))
        XCTAssertFalse(SideloadSigningOptions.isVersionString("1."))
        XCTAssertFalse(SideloadSigningOptions.isVersionString("beta"))
    }

    func testInstallNames() {
        XCTAssertTrue(SideloadSigningOptions.isInstallName("@executable_path/Frameworks/T.dylib"))
        XCTAssertTrue(SideloadSigningOptions.isInstallName("@rpath/T.dylib"))
        XCTAssertTrue(SideloadSigningOptions.isInstallName("/usr/lib/libz.dylib"))
        XCTAssertFalse(SideloadSigningOptions.isInstallName("Tweak.dylib"))
        XCTAssertFalse(SideloadSigningOptions.isInstallName("/tmp/../etc/passwd"))
    }

    func testAdHocWithCertificateIsRefused() {
        let options = SideloadSigningOptions(adHoc: true)
        XCTAssertThrowsError(try options.validate(hasCertificate: true)) { error in
            XCTAssertEqual(error as? SideloadOptionError, .adHocWithCertificate)
        }
        XCTAssertNoThrow(try options.validate(hasCertificate: false))
    }

    func testDuplicateInjectionIsRefused() {
        let library = InjectedLibrary(installName: "@rpath/T.dylib")
        let options = SideloadSigningOptions(injectedLibraries: [library, library])
        XCTAssertThrowsError(try options.validate(hasCertificate: false)) { error in
            XCTAssertEqual(error as? SideloadOptionError, .duplicateInstallName("@rpath/T.dylib"))
        }
    }

    func testInjectionLimitIsEnforced() {
        let libraries = (0..<(SideloadSigningOptions.maximumInjectedLibraries + 1)).map {
            InjectedLibrary(installName: "@rpath/T\($0).dylib")
        }
        XCTAssertThrowsError(try SideloadSigningOptions(injectedLibraries: libraries)
            .validate(hasCertificate: false))
    }

    func testMainPlanRewritesOnlyWhatWasAsked() {
        let plan = InfoPlistOverrides.mainApplicationPlan(
            SideloadSigningOptions(bundleIdentifier: "com.example.new",
                                   removesURLSchemes: true))
        XCTAssertEqual(plan.values["CFBundleIdentifier"], .string("com.example.new"))
        XCTAssertNil(plan.values["CFBundleDisplayName"])
        XCTAssertEqual(plan.keysToRemove, ["CFBundleURLTypes", "LSApplicationQueriesSchemes"])
    }

    func testExtensionFollowsARenamedParent() {
        XCTAssertEqual(
            InfoPlistOverrides.extensionIdentifier(
                oldIdentifier: "com.old.app.widget",
                oldParentIdentifier: "com.old.app",
                newParentIdentifier: "com.new.app"),
            "com.new.app.widget")
        XCTAssertNil(InfoPlistOverrides.extensionIdentifier(
            oldIdentifier: "com.other.widget",
            oldParentIdentifier: "com.old.app",
            newParentIdentifier: "com.new.app"))
    }
}

final class DylibInjectionPlanTests: XCTestCase {

    private func layout(padding: Int, hasSignature: Bool = false) -> MachOHeaderLayout {
        MachOHeaderLayout(
            headerSize: 32,
            numberOfCommands: 2,
            sizeOfCommands: 224,
            firstSectionFileOffset: 256 + padding,
            firstSegmentFileOffset: 0,
            hasCodeSignatureCommand: hasSignature,
            hasLinkeditSegment: true)
    }

    func testLoadCommandMatchesTheHostSuiteBytes() throws {
        let command = try DylibInjectionPlanner.loadCommand(
            installName: "@executable_path/Frameworks/Tweak.dylib", isWeak: false)
        // length 64 = 24-byte dylib_command + 38-byte name + 2 bytes padding
        XCTAssertEqual(command.count, 64)
        XCTAssertEqual(Array(command.prefix(24)), [
            0x0C, 0x00, 0x00, 0x00,   // LC_LOAD_DYLIB
            0x40, 0x00, 0x00, 0x00,   // cmdsize 64
            0x18, 0x00, 0x00, 0x00,   // name offset 24
            0x00, 0x00, 0x00, 0x00,   // timestamp
            0x00, 0x00, 0x01, 0x00,   // current version 1.0
            0x00, 0x00, 0x01, 0x00,   // compatibility version 1.0
        ])
        XCTAssertEqual(command.suffix(2), Data([0x00, 0x00]))
    }

    func testWeakCommandUsesTheWeakConstant() throws {
        let command = try DylibInjectionPlanner.loadCommand(
            installName: "@rpath/Optional.dylib", isWeak: true)
        XCTAssertEqual(Array(command.prefix(4)), [0x18, 0x00, 0x00, 0x80])
    }

    func testPlanAccountsForTheSignatureCommand() throws {
        let plans = try DylibInjectionPlanner.plan(
            for: layout(padding: 512),
            injecting: [InjectedLibrary(installName: "@rpath/T.dylib")])
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].resultingSizeOfCommands,
                       224 + 16 + plans[0].loadCommand.count)
    }

    func testHeaderWithoutRoomIsRefused() {
        XCTAssertThrowsError(try DylibInjectionPlanner.plan(
            for: layout(padding: 8),
            injecting: [InjectedLibrary(installName: "@rpath/T.dylib")])) { error in
            guard case .insufficientHeaderSpace(let required, let available)? =
                    error as? DylibInjectionError else {
                return XCTFail("expected insufficientHeaderSpace, got \(error)")
            }
            XCTAssertGreaterThan(required, available)
        }
    }

    func testImageWithoutLinkeditIsRefused() {
        let value = MachOHeaderLayout(
            headerSize: 32, numberOfCommands: 1, sizeOfCommands: 72,
            firstSectionFileOffset: 512, firstSegmentFileOffset: 0,
            hasCodeSignatureCommand: true, hasLinkeditSegment: false)
        XCTAssertThrowsError(try DylibInjectionPlanner.plan(
            for: value, injecting: [InjectedLibrary(installName: "@rpath/T.dylib")]))
    }

    func testAdHocPolicySetsTheCodeDirectoryFlag() {
        XCTAssertEqual(AdHocSignaturePolicy(hardenedRuntime: false).codeDirectoryFlags,
                       AdHocSignaturePolicy.adHocFlag)
        XCTAssertEqual(AdHocSignaturePolicy(hardenedRuntime: true).codeDirectoryFlags,
                       AdHocSignaturePolicy.adHocFlag | AdHocSignaturePolicy.runtimeFlag)
        XCTAssertFalse(AdHocSignaturePolicy(hardenedRuntime: false).trustStatement.isEmpty)
    }
}

final class DeviceWireProtocolTests: XCTestCase {

    func testUSBMuxFrameRoundTrip() throws {
        let payload = try PropertyListSerialization.data(
            fromPropertyList: ["MessageType": "Connect", "PortNumber": 62_078],
            format: .xml, options: 0)
        let frame = USBMuxProtocol.Frame(type: .plist, tag: 7, payload: payload)
        let encoded = try frame.serialized()
        XCTAssertEqual(encoded.count, 16 + payload.count)
        let (decoded, length) = try USBMuxProtocol.decodeHeader(encoded)
        XCTAssertEqual(decoded.type, .plist)
        XCTAssertEqual(decoded.tag, 7)
        XCTAssertEqual(length, encoded.count)
        XCTAssertEqual(Int(encoded[0]), encoded.count & 0xFF)
        XCTAssertEqual(Array(encoded[4..<8]), [0x01, 0x00, 0x00, 0x00])
    }

    func testUnsupportedProtocolVersionIsRefused() {
        var frame = Data(repeating: 0, count: 16)
        frame[0] = 16
        frame[4] = 9  // version
        frame[8] = 8
        XCTAssertThrowsError(try USBMuxProtocol.decodeHeader(frame)) { error in
            XCTAssertEqual(error as? DeviceProtocolError, .unsupportedVersion(9))
        }
    }

    func testTruncatedFrameIsRefused() {
        XCTAssertThrowsError(try USBMuxProtocol.decodeHeader(Data([1, 2, 3]))) { error in
            XCTAssertEqual(error as? DeviceProtocolError,
                           .truncatedFrame(needed: 16, received: 3))
        }
    }

    func testLockdownFramingIsBigEndian() throws {
        let body = Data([0xAA, 0xBB])
        let framed = try PropertyListFraming.frame(body)
        XCTAssertEqual(Array(framed.prefix(4)), [0x00, 0x00, 0x00, 0x02])
        XCTAssertEqual(try PropertyListFraming.declaredLength(prefix: framed.prefix(4)), 2)
        XCTAssertEqual(framed.suffix(2), body)
    }

    func testDeclaredLengthIsBounded() {
        XCTAssertThrowsError(try PropertyListFraming.declaredLength(
            prefix: Data([0x00, 0x00, 0x00, 0x00])))
        XCTAssertThrowsError(try PropertyListFraming.declaredLength(
            prefix: Data([0xFF, 0xFF, 0xFF, 0xFF])))
    }

    func testLockdownRequestShapes() {
        let pair = LockdownProtocol.Request.pair(recordData: Data([1, 2, 3]))
            .message(label: "ZynSign")
        XCTAssertEqual(pair["Request"] as? String, "Pair")
        XCTAssertEqual(pair["ProtocolVersion"] as? String, "2")
        XCTAssertEqual(pair["PairRecordData"] as? Data, Data([1, 2, 3]))

        let session = LockdownProtocol.Request.startSession(hostID: "AB", systemBUID: "CD")
            .message(label: "ZynSign")
        XCTAssertEqual(session["HostID"] as? String, "AB")
        XCTAssertEqual(session["SystemBUID"] as? String, "CD")

        let service = LockdownProtocol.Request.startService(
            name: LockdownProtocol.installationProxyService).message(label: "ZynSign")
        XCTAssertEqual(service["Service"] as? String, "com.apple.mobile.installation_proxy")
    }

    func testLockdownResponseTreatsErrorAsFailure() {
        guard case .success = LockdownProtocol.Response.decode(["Result": "Success"]) else {
            return XCTFail("a Success result must decode as success")
        }
        guard case .failure(let code) = LockdownProtocol.Response.decode(
            ["Error": "InvalidPairRecord"]) else {
            return XCTFail("an Error must decode as a failure")
        }
        XCTAssertEqual(code, "InvalidPairRecord")
        guard case .failure(let missing) = LockdownProtocol.Response.decode([:]) else {
            return XCTFail("a response without Result must be a failure")
        }
        XCTAssertEqual(missing, "MissingResult")
    }

    func testAFCHeaderCodec() throws {
        let header = AFCProtocol.Header(
            entryType: 0,
            operation: .fileWrite,
            operationRaw: AFCProtocol.Operation.fileWrite.rawValue,
            transaction: 9,
            payloadSize: 1_024)
        let encoded = header.serialized()
        XCTAssertEqual(encoded.count, 40)
        XCTAssertEqual(encoded.prefix(8), AFCProtocol.magic)
        let decoded = try AFCProtocol.Header.decode(encoded)
        XCTAssertEqual(decoded.operation, .fileWrite)
        XCTAssertEqual(decoded.transaction, 9)
        XCTAssertEqual(decoded.payloadSize, 1_024)
        XCTAssertEqual(decoded.entryType, 0)
    }

    func testAFCMagicMismatchIsRefused() {
        XCTAssertThrowsError(try AFCProtocol.Header.decode(Data(repeating: 0, count: 40))) {
            XCTAssertEqual($0 as? DeviceProtocolError, .invalidAFCMagic)
        }
    }

    func testInstallationProgressDecoding() {
        let step = InstallationProxyProtocol.Update.decode(
            ["Status": "VerifyingApplication", "PercentComplete": 60]).progressValue
        XCTAssertEqual(step?.status, .verifyingApplication)
        XCTAssertEqual(step?.percentComplete, 60)

        let complete = InstallationProxyProtocol.Update.decode(
            ["Status": "Complete", "PercentComplete": 100]).progressValue
        XCTAssertEqual(complete?.isTerminal, true)

        guard case .failure(let code, let description) =
                InstallationProxyProtocol.Update.decode(
                    ["Error": "ApplicationVerificationFailed",
                     "ErrorDescription": "not trusted"]) else {
            return XCTFail("an Error message must decode as a failure")
        }
        XCTAssertEqual(code, "ApplicationVerificationFailed")
        XCTAssertEqual(description, "not trusted")

        let unknown = InstallationProxyProtocol.Update.decode(
            ["Status": "NewDeviceStatus"]).progressValue
        XCTAssertEqual(unknown?.status, .unknown("NewDeviceStatus"))
    }

    func testInstallMessageCarriesTheBundleIdentifier() {
        let message = InstallationProxyProtocol.Command.install(
            packagePath: "/PublicStaging/App.ipa",
            bundleIdentifier: "com.example.demo",
            isUpgrade: false).message()
        XCTAssertEqual(message["Command"] as? String, "Install")
        XCTAssertEqual(message["PackagePath"] as? String, "/PublicStaging/App.ipa")
        let options = message["ClientOptions"] as? [String: String]
        XCTAssertEqual(options?["CFBundleIdentifier"], "com.example.demo")
        XCTAssertEqual(options?["PackageType"], "Developer")
    }
}

private extension InstallationProxyProtocol.Update {
    var progressValue: InstallationProxyProtocol.Progress? {
        guard case .progress(let value) = self else { return nil }
        return value
    }
}

final class PairingRecordCodingTests: XCTestCase {

    private func digestReturning(_ byte: UInt8) -> RecordingMessageDigest {
        let digest = RecordingMessageDigest()
        digest.preparedDigest = Digest(algorithm: .sha1, bytes: Data(repeating: byte, count: 20))
        return digest
    }

    func testHostIdentifierIsUppercaseHexOfTheDigest() throws {
        let value = try PairingRecordCoding.hostIdentifier(
            forCertificate: Data([1, 2, 3]), digest: digestReturning(0xAB))
        XCTAssertEqual(value, String(repeating: "AB", count: 20))
        XCTAssertEqual(value.count, 40)
    }

    func testRecordIsRefusedWhenTheHostIDDisagrees() {
        let recorder = digestReturning(0x11)
        let record: [String: Any] = [
            DevicePairingRecord.Key.deviceCertificate: Data([1]),
            DevicePairingRecord.Key.rootCertificate: Data([2]),
            DevicePairingRecord.Key.hostCertificate: Data([3]),
            DevicePairingRecord.Key.hostPrivateKey: Data([4]),
            DevicePairingRecord.Key.hostID: "DEADBEEF",
            DevicePairingRecord.Key.systemBUID: "BUID",
        ]
        let plist = try? PropertyListSerialization.data(
            fromPropertyList: record, format: .binary, options: 0)
        XCTAssertThrowsError(try PairingRecordCoding.decode(plist ?? Data(), digest: recorder)) {
            guard case .hostIdentifierMismatch? = $0 as? PairingRecordError else {
                return XCTFail("expected a HostID mismatch, got \($0)")
            }
        }
    }

    func testMissingKeysAreNamed() {
        let plist = try? PropertyListSerialization.data(
            fromPropertyList: ["HostID": "X"], format: .binary, options: 0)
        XCTAssertThrowsError(try PairingRecordCoding.decode(plist ?? Data(),
                                                            digest: digestReturning(1))) {
            guard case .missingKeys(let keys)? = $0 as? PairingRecordError else {
                return XCTFail("expected missing keys, got \($0)")
            }
            XCTAssertTrue(keys.contains(DevicePairingRecord.Key.hostPrivateKey))
        }
    }
}

final class GuestContainerTests: XCTestCase {

    func testRunnableGuestHasNoBlocks() {
        let assessment = GuestContainer.assess(
            GuestContainer.Evidence(bundleIdentifier: "com.example.guest",
                                    name: "Guest", version: "1.0",
                                    executableName: "Guest"))
        XCTAssertTrue(assessment.isRunnable)
        XCTAssertEqual(assessment.blocks, [])
        XCTAssertTrue(assessment.summary.hasPrefix("Runnable"))
    }

    func testEncryptedGuestIsBlocked() {
        let assessment = GuestContainer.assess(
            GuestContainer.Evidence(bundleIdentifier: "com.example.guest",
                                    name: "Guest", version: "1.0",
                                    executableName: "Guest", isEncrypted: true))
        XCTAssertFalse(assessment.isRunnable)
        XCTAssertEqual(assessment.blocks, [.fairplayEncrypted])
    }

    func testExtensionsAndWatchBundlesBlock() {
        let assessment = GuestContainer.assess(
            GuestContainer.Evidence(bundleIdentifier: "com.example.guest",
                                    name: "Guest", version: "1.0",
                                    executableName: "Guest",
                                    nestedBundleKinds: ["appex", "app"]))
        XCTAssertEqual(assessment.blocks, [.appExtensions, .watchApp])
    }

    func testMissingLoaderIsABlockAndTheFirstPlanStep() {
        let assessment = GuestContainer.assess(
            GuestContainer.Evidence(bundleIdentifier: "com.example.guest",
                                    name: "Guest", version: "1.0",
                                    executableName: "Guest", loaderBundled: false))
        XCTAssertTrue(assessment.blocks.contains(.loaderUnavailable))
        let plan = GuestContainer.launchPlan(for: assessment)
        XCTAssertEqual(plan.first?.requirement, .bundledLoader)
    }

    func testPlanNamesEveryRequirement() {
        let assessment = GuestContainer.assess(
            GuestContainer.Evidence(bundleIdentifier: "com.example.guest",
                                    name: "Guest", version: "1.0",
                                    executableName: "Guest"))
        let plan = GuestContainer.launchPlan(for: assessment)
        XCTAssertEqual(plan.count, 5)
        XCTAssertEqual(Set(plan.map(\.requirement)),
                       Set([.guestPatched, .containerRedirect, .mainThreadEntry,
                            .bundleSwizzling]))
        XCTAssertTrue(plan.contains { $0.detail.contains("dlopen") })
        XCTAssertTrue(plan.contains { $0.detail.contains("MH_EXECUTE to MH_DYLIB") })
    }

    func testJITAndMetalAreWarningsNotBlocks() {
        let assessment = GuestContainer.assess(
            GuestContainer.Evidence(bundleIdentifier: "com.example.guest",
                                    name: "Guest", version: "1.0",
                                    executableName: "Guest", requiresJIT: true,
                                    requiresMetal: true))
        XCTAssertTrue(assessment.isRunnable)
        XCTAssertEqual(assessment.warnings, [.requiresJIT, .metalRequired])
    }

    func testMetadataCarriesTheContainerPaths() {
        let assessment = GuestContainer.assess(
            GuestContainer.Evidence(bundleIdentifier: "com.example.guest",
                                    name: "Guest", version: "2.0",
                                    executableName: "Guest"))
        let values = assessment.metadata.propertyList()
        XCTAssertEqual(values["LCGuestPath"] as? String,
                       "Applications/com.example.guest/App.app")
        XCTAssertEqual(values["LCDataPath"] as? String,
                       "Applications/com.example.guest/Data")
        XCTAssertEqual(values["LCExecutable"] as? String, "Guest")
        XCTAssertEqual(values["LCContainerVersion"] as? Int, 1)
    }
}

final class SideloadingCapabilityTests: XCTestCase {

    func testEveryCapabilityIsAssessedWithAReason() {
        let assessments = SideloadingCapability.all(
            evidence: SideloadingCapability.Evidence())
        XCTAssertEqual(assessments.count, SideloadingCapability.allCases.count)
        for assessment in assessments {
            XCTAssertFalse(assessment.summary.isEmpty)
            if !assessment.isSupported {
                XCTAssertFalse(assessment.unmetRequirements.isEmpty)
            }
        }
    }

    func testPairingNeedsARecordAndTheEntitlement() {
        let assessment = SideloadingCapability.assess(
            .devicePairing, evidence: SideloadingCapability.Evidence())
        XCTAssertEqual(assessment.unmetRequirements, [.pairingRecord,
                                                      .localTunnelEntitlement,
                                                      .entitledBuild])
        XCTAssertFalse(assessment.isSupported)
    }

    func testAnEntitledBuildWithARecordSupportsPairing() {
        let assessment = SideloadingCapability.assess(
            .devicePairing,
            evidence: SideloadingCapability.Evidence(
                hasPairingRecord: true,
                buildCarriesLocalTunnelEntitlement: true))
        XCTAssertTrue(assessment.isSupported)
        XCTAssertEqual(assessment.unmetRequirements, [])
    }

    func testContainerNeedsALoaderAndADecryptedGuest() {
        let assessment = SideloadingCapability.assess(
            .guestContainer,
            evidence: SideloadingCapability.Evidence(loaderBundled: false,
                                                     guestDecrypted: true))
        XCTAssertEqual(assessment.unmetRequirements, [.bundledLoader])
    }

    func testSmallHeaderPaddingBlocksInjection() {
        let assessment = SideloadingCapability.assess(
            .libraryInjection,
            evidence: SideloadingCapability.Evidence(targetHeaderPadding: 8))
        XCTAssertEqual(assessment.unmetRequirements, [.headerPadding])
    }

    func testAdHocSigningIsAlwaysPossibleButNotAlwaysTrusted() {
        let untrusted = SideloadingCapability.assess(
            .adHocSigning,
            evidence: SideloadingCapability.Evidence(deviceAcceptsAdHoc: false))
        XCTAssertEqual(untrusted.unmetRequirements, [.deviceTrustsAdHoc])
        let unknown = SideloadingCapability.assess(
            .adHocSigning, evidence: SideloadingCapability.Evidence())
        XCTAssertTrue(unknown.isSupported)
    }

    func testTruthStatementsAreNotEmpty() {
        XCTAssertGreaterThanOrEqual(SideloadingTruth.statements.count, 5)
        XCTAssertTrue(SideloadingTruth.statements.allSatisfy { !$0.isEmpty })
    }
}

final class CodeDirectoryVersionHeaderTests: XCTestCase {

    /// `cs_blobs.h`: `0x20400` ends with `execSegBase`, `execSegLimit` and
    /// `execSegFlags`, so its fixed header is 88 bytes — the size
    /// `ReadOnlyMachOParser` already read. Declaring 52 would put the
    /// identifier where a device expects `codeLimit64`.
    func testEveryPublishedHeaderLength() {
        XCTAssertEqual(CodeDirectoryVersion.v20001.headerLength, 44)
        XCTAssertEqual(CodeDirectoryVersion.v20200.headerLength, 52)
        XCTAssertEqual(CodeDirectoryVersion.v20400.headerLength, 88)
    }

    func testDERCapableVersionSupportsSlotSeven() {
        XCTAssertTrue(CodeDirectoryVersion.v20400.supportsDEREntitlements)
        XCTAssertFalse(CodeDirectoryVersion.v20200.supportsDEREntitlements)
    }
}
