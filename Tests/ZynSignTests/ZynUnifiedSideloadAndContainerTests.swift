import Foundation
import Darwin
import XCTest
@testable import ZynSign

private struct TestGuestRuntimeLoader: GuestRuntimeLoading {
    let isBundledLoaderPresent = true

    func probeGuestExecutable(
        at executableURL: URL,
        entrySymbol: String,
        guest: HostedGuestDescriptor,
        containerRoot: URL,
        guestBundleURL: URL,
        activeDataDirectory: URL
    ) throws -> GuestRuntimeProbeReport {
        GuestRuntimeProbeReport(imageLoadable: true, entrySymbolFound: true, diagnosticMessage: "Test probe")
    }
}

final class ZynUnifiedSideloadAndContainerTests: XCTestCase {

    func testGuestMachOPatcherExtractsFatArm64ConvertsToDylibAndNeutralizesPageZero() throws {
        let thinExec = Self.makeSignableArm64Executable()
        let fatBinary = Self.wrapInUniversalFatHeader(arm64Slice: thinExec)

        let inspectionBefore = try XCTUnwrap(GuestMachOPatcher.inspectCandidateBinary(fatBinary))
        XCTAssertTrue(inspectionBefore.isUniversal)
        XCTAssertTrue(inspectionBefore.hasArm64Slice)
        XCTAssertTrue(inspectionBefore.hasPageZeroSegment)
        XCTAssertEqual(inspectionBefore.headerFileType, GuestMachOPatcher.mhExecute)

        let patched = try GuestMachOPatcher.patchExecutableForGuestRuntime(
            fatBinary,
            installID: "@rpath/GuestApp",
            injectedInstallNames: ["@rpath/TweakLoader.dylib"]
        )
        XCTAssertTrue(patched.extractedFromUniversal)
        XCTAssertTrue(patched.convertedExecuteToDylib)
        XCTAssertTrue(patched.neutralizedPageZero)
        XCTAssertEqual(patched.injectedInstallNames, ["@rpath/TweakLoader.dylib"])

        let inspectionAfter = try XCTUnwrap(GuestMachOPatcher.inspectCandidateBinary(patched.binary))
        XCTAssertFalse(inspectionAfter.isUniversal)
        XCTAssertFalse(inspectionAfter.hasPageZeroSegment)
        XCTAssertEqual(inspectionAfter.headerFileType, GuestMachOPatcher.mhDylib)

        let adHoc = try AdHocMachOSigner().signMachO(
            patched.binary,
            identifier: "io.zynsign.hosted.guest"
        )
        let parsed = try ReadOnlyMachOParser().parse(adHoc.signedBytes)
        guard case .thin(let slice) = parsed.container,
              let embedded = slice.embeddedSignature,
              let cdEntry = embedded.superBlob.entries.first(where: { $0.slot == .codeDirectory }),
              let cd = cdEntry.codeDirectory else {
            return XCTFail("Expected valid embedded CS_ADHOC SuperBlob")
        }
        XCTAssertEqual(cd.flags & 0x0000_0002, 0x0000_0002)
        XCTAssertFalse(embedded.superBlob.entries.contains { $0.slot == .cms })
    }

    @MainActor
    func testGuestContainerHostServiceStagesMultiSlotGuestAndRestoresStandaloneIPA() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zynsign-container-host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let ipaURL = tempRoot.appendingPathComponent("SampleGuest.ipa")
        try Self.writeSyntheticIPA(to: ipaURL, bundleID: "io.zynsign.sampleguest", appName: "SampleGuest")

        let docsDir = tempRoot.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)

        let host = GuestContainerHostService(
            documentsDirectory: docsDir,
            runtimeLoader: TestGuestRuntimeLoader()
        )
        let staged = try await host.stagePackage(from: ipaURL, customDisplayName: "Hosted Sample")
        XCTAssertEqual(staged.bundleIdentifier, "io.zynsign.sampleguest")
        XCTAssertEqual(staged.displayName, "Hosted Sample")
        XCTAssertEqual(host.hostedGuests.count, 1)
        host.requestLaunch(bundleIdentifier: staged.bundleIdentifier)
        XCTAssertEqual(host.lastLaunchAttempt?.probe.imageLoadable, true)
        XCTAssertNil(host.hostedGuests.first?.lastLaunchedAt, "A probe is not an app launch")

        let original = getenv("ZYNSIGN_GUEST_BUNDLE_ID").map { String(cString: $0) }
        defer {
            if let original { _ = setenv("ZYNSIGN_GUEST_BUNDLE_ID", original, 1) }
            else { _ = unsetenv("ZYNSIGN_GUEST_BUNDLE_ID") }
        }
        XCTAssertEqual(setenv("ZYNSIGN_GUEST_BUNDLE_ID", "previous-value", 1), 0)
        let failedProbe = try PosixGuestRuntimeLoader().probeGuestExecutable(
            at: tempRoot.appendingPathComponent("missing-executable"), entrySymbol: "main",
            guest: staged, containerRoot: tempRoot, guestBundleURL: tempRoot, activeDataDirectory: tempRoot
        )
        XCTAssertFalse(failedProbe.imageLoadable)
        XCTAssertEqual(getenv("ZYNSIGN_GUEST_BUNDLE_ID").map { String(cString: $0) }, "previous-value")

        let marker = docsDir.appendingPathComponent("Applications/io.zynsign.sampleguest/Data/Documents/keep.txt")
        try Data("do not delete".utf8).write(to: marker)
        do {
            _ = try await host.stagePackage(from: ipaURL)
            XCTFail("Staging an existing guest must not replace its data.")
        } catch GuestContainerHostService.HostError.guestAlreadyExists(let id) {
            XCTAssertEqual(id, "io.zynsign.sampleguest")
        }
        XCTAssertEqual(try Data(contentsOf: marker), Data("do not delete".utf8))

        let guestInfoURL = docsDir
            .appendingPathComponent("Applications/io.zynsign.sampleguest/\(GuestContainer.Layout.info)")
        let infoDict = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: guestInfoURL),
            options: [],
            format: nil
        ) as? [String: Any]
        XCTAssertEqual(infoDict?["ZynBundleId"] as? String, "io.zynsign.sampleguest")

        let secondSlot = try host.createDataSlot(for: "io.zynsign.sampleguest", label: "Work Account")
        try host.switchActiveSlot(for: "io.zynsign.sampleguest", to: secondSlot.id)
        XCTAssertEqual(host.hostedGuests.first?.activeSlotID, secondSlot.id)

        let backupZipURL = try await host.exportSlotDataArchive(for: "io.zynsign.sampleguest")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupZipURL.path))
        defer { try? FileManager.default.removeItem(at: backupZipURL) }

        let standaloneURL = try await host.exportStandaloneIPA(for: "io.zynsign.sampleguest")
        XCTAssertTrue(FileManager.default.fileExists(atPath: standaloneURL.path))
        defer { try? FileManager.default.removeItem(at: standaloneURL) }
    }

    @MainActor
    func testGuestStagingRejectsUnsafeBundleAndExecutableNames() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zynsign-guest-validation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = GuestContainerHostService(documentsDirectory: root, runtimeLoader: PosixGuestRuntimeLoader())
        for (bundleID, executable) in [("../outside", "App"), ("io.example.app", "../outside")] {
            let ipa = root.appendingPathComponent("test-\(UUID().uuidString).ipa")
            try Self.writeSyntheticIPA(to: ipa, bundleID: bundleID, appName: "App", executableName: executable)
            do {
                _ = try await host.stagePackage(from: ipa)
                XCTFail("Unsafe guest metadata must be rejected.")
            } catch GuestContainerHostService.HostError.invalidBundleMetadata {
                // Expected; nothing should be staged under Applications.
            }
        }
        XCTAssertTrue(host.hostedGuests.isEmpty)
    }

    @MainActor
    func testGuestRemovalRejectsEscapingIdentifier() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zynsign-guest-removal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)
        let host = GuestContainerHostService(documentsDirectory: root, runtimeLoader: PosixGuestRuntimeLoader())
        XCTAssertThrowsError(try host.removeHostedGuest("../keep.txt"))
        XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))
    }

    @MainActor
    func testUnsafeStoredGuestDescriptorIsNotLoadedOrDeleted() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zynsign-guest-descriptor-\(UUID().uuidString)", isDirectory: true)
        let container = root.appendingPathComponent("Applications/io.example.guest", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "ZynBundleId": "../outside", "ZynAppName": "Guest", "ZynExecutable": "Guest"
        ], format: .xml, options: 0)
        let metadataURL = container.appendingPathComponent(GuestContainer.Layout.info)
        try plist.write(to: metadataURL)
        let host = GuestContainerHostService(documentsDirectory: root, runtimeLoader: PosixGuestRuntimeLoader())
        XCTAssertTrue(host.hostedGuests.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataURL.path))
    }

    func testStrategyAdvisorRoutesPaidFreeAndZeroSlotContainer() {
        let paidRec = ZynSigningStrategyAdvisor.recommend(
            hasPaidCertificate: true,
            hasFreePersonalTeam: true,
            activeFreeAppCount: 3,
            hasAppExtensions: true,
            requiresPushOrBackground: true,
            prefersUnlimitedContainerApps: false
        )
        XCTAssertEqual(paidRec.track, .paidCertificate)

        let capReachedRec = ZynSigningStrategyAdvisor.recommend(
            hasPaidCertificate: false,
            hasFreePersonalTeam: true,
            activeFreeAppCount: 3,
            hasAppExtensions: false,
            requiresPushOrBackground: false,
            prefersUnlimitedContainerApps: false
        )
        XCTAssertEqual(capReachedRec.track, .hostContainer)
        XCTAssertTrue(capReachedRec.preservesThreeAppBudget)

        let freeDirectRec = ZynSigningStrategyAdvisor.recommend(
            hasPaidCertificate: false,
            hasFreePersonalTeam: true,
            activeFreeAppCount: 1,
            hasAppExtensions: false,
            requiresPushOrBackground: false,
            prefersUnlimitedContainerApps: false
        )
        XCTAssertEqual(freeDirectRec.track, .freeAccountDirect)
    }

    func testWebClipBuilderPKCS10CSRAndAnisetteBundle() throws {
        let guest = HostedGuestDescriptor(
            bundleIdentifier: "io.zynsign.reader",
            displayName: "ZynReader",
            shortVersion: "1.2.0",
            buildVersion: "12",
            executableName: "ZynReader",
            activeSlotID: "work-profile",
            slots: [
                .primary(),
                GuestDataSlot(id: "work-profile", label: "Work", createdAt: Date())
            ],
            stagedTweaks: [],
            injectedLibraries: [],
            requiresJIT: false,
            jitlessCompatible: true,
            sharedAppGroupIsolation: true,
            stagedAt: Date(),
            lastLaunchedAt: nil
        )
        let mobileConfig = try GuestWebClipProfileBuilder.buildMobileConfig(guest: guest)
        let xmlText = String(decoding: mobileConfig, as: UTF8.self)
        XCTAssertTrue(xmlText.contains("com.apple.webClip.managed"))
        XCTAssertTrue(xmlText.contains("zynsign://launch-guest?bundleId=io.zynsign.reader&amp;slot=work-profile"))

        let anisetteJSON = """
        {
          "X-Apple-I-MD": "OTP123456",
          "X-Apple-I-MD-M": "MACHINE987654",
          "X-Mme-Device-Id": "DEV-UUID-01"
        }
        """
        let bundle = try AnisetteHeaderBundle.decode(from: Data(anisetteJSON.utf8))
        XCTAssertEqual(bundle.httpHeaders()["X-Apple-I-MD"], "OTP123456")

        let freeTeam = AppleDeveloperTeam(
            teamID: "ABC123XYZ0",
            name: "Personal Team",
            accountKind: .personalTeam,
            rawType: "Individual"
        )
        XCTAssertEqual(
            PersonalTeamBundleIDPlanner.scopedBundleIdentifier(originalBundleID: "org.sample.client", team: freeTeam),
            "org.sample.client.abc123xyz0"
        )

        var syntheticRSAPub = Data([0x30, 0x48, 0x02, 0x41, 0x00])
        syntheticRSAPub.append(Data(repeating: 0xAB, count: 64))
        syntheticRSAPub.append(contentsOf: [0x02, 0x03, 0x01, 0x00, 0x01])
        let csrInfo = try PKCS10CertificateRequestBuilder.buildCertificationRequestInfoDER(
            rsaPublicKeyDER: syntheticRSAPub,
            commonName: "ZynSign Unit Test"
        )
        let signedCSR = PKCS10CertificateRequestBuilder.assembleSignedCSR(
            certificationRequestInfoDER: csrInfo,
            signatureBytes: Data(repeating: 0x55, count: 256)
        )
        XCTAssertTrue(signedCSR.pem.hasPrefix("-----BEGIN CERTIFICATE REQUEST-----"))
        XCTAssertEqual(signedCSR.der.first, 0x30)
    }

    @MainActor
    func testDeviceBridgeControllerImportsAndStoresPairingRecord() throws {
        let digest = CryptoKitMessageDigest()
        let hostCert = Data("HOST-CERT-DER-BYTES".utf8)
        let hostID = try PairingRecordCoding.hostIdentifier(forCertificate: hostCert, digest: digest)
        let pairingDict: [String: Any] = [
            DevicePairingRecord.Key.deviceCertificate: Data("DEV-CERT".utf8),
            DevicePairingRecord.Key.rootCertificate: Data("ROOT-CERT".utf8),
            DevicePairingRecord.Key.hostCertificate: hostCert,
            DevicePairingRecord.Key.hostPrivateKey: Data("HOST-KEY".utf8),
            DevicePairingRecord.Key.hostID: hostID,
            DevicePairingRecord.Key.systemBUID: "BUID-1234-5678"
        ]
        let plistBytes = try PropertyListSerialization.data(fromPropertyList: pairingDict, format: .xml, options: 0)
        let endpoint = DeviceBridgeEndpointConfig()
        let memoryStore = InMemoryPairingStore()
        let controller = DeviceBridgeController(
            recordStore: memoryStore,
            digest: digest,
            endpointConfig: endpoint,
            makeTransport: { NetworkDeviceBridgeTransport(endpointConfig: endpoint) }
        )
        let imported = try controller.importPairingFile(data: plistBytes)
        XCTAssertTrue(controller.hasPairingRecord)
        XCTAssertEqual(imported.hostIdentifier, hostID)
    }

    func testProductionDeviceTransportFailsClosedWithoutAuthenticatedTLS() async {
        let record = DevicePairingRecord(
            deviceCertificate: Data([1]), rootCertificate: Data([2]),
            hostCertificate: Data([3]), hostPrivateKey: Data([4]),
            hostIdentifier: "TEST", systemBUID: "TEST"
        )
        let transport = NetworkDeviceBridgeTransport(endpointConfig: DeviceBridgeEndpointConfig())
        XCTAssertFalse(NetworkDeviceBridgeTransport.supportsAuthenticatedSessions)
        do {
            try await transport.connect(pairing: record, port: 62078)
            XCTFail("An unauthenticated transport must not open a device session.")
        } catch let error as DeviceProtocolError {
            XCTAssertEqual(error, .authenticatedTransportUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testUnavailableDeviceControllerRefusesBeforeReadingPackage() async {
        let endpoint = DeviceBridgeEndpointConfig()
        let controller = DeviceBridgeController(
            recordStore: InMemoryPairingStore(),
            digest: CryptoKitMessageDigest(),
            endpointConfig: endpoint,
            isTransportComposed: false,
            makeTransport: { NetworkDeviceBridgeTransport(endpointConfig: endpoint) }
        )
        do {
            _ = try await controller.installSignedPackage(
                at: URL(fileURLWithPath: "/nonexistent.ipa"), bundleIdentifier: "example.app"
            )
            XCTFail("Unavailable transport must refuse installation.")
        } catch let error as DeviceProtocolError {
            XCTAssertEqual(error, .authenticatedTransportUnavailable)
            XCTAssertEqual(controller.errorMessage, error.message)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Synthetic Fixtures

    private final class InMemoryPairingStore: PairingRecordStoring, @unchecked Sendable {
        private var records: [DevicePairingRecord] = []

        func save(_ record: DevicePairingRecord) throws {
            records.removeAll { $0.hostIdentifier == record.hostIdentifier }
            records.append(record)
        }

        func all() throws -> [DevicePairingRecord] {
            records
        }

        func remove(hostIdentifier: String) throws {
            records.removeAll { $0.hostIdentifier == hostIdentifier }
        }
    }

    private static func writeSyntheticIPA(
        to outputURL: URL, bundleID: String, appName: String, executableName: String? = nil
    ) throws {
        let infoDict: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": appName,
            "CFBundleDisplayName": appName,
            "CFBundleExecutable": executableName ?? appName,
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1"
        ]
        let infoBytes = try PropertyListSerialization.data(fromPropertyList: infoDict, format: .xml, options: 0)
        let execBytes = makeSignableArm64Executable()

        let entries: [ArchiveWriteEntry] = [
            ArchiveWriteEntry(path: try XCTUnwrap(ArchivePath(rawValue: "Payload")), kind: .directory),
            ArchiveWriteEntry(path: try XCTUnwrap(ArchivePath(rawValue: "Payload/\(appName).app")), kind: .directory),
            ArchiveWriteEntry(
                path: try XCTUnwrap(ArchivePath(rawValue: "Payload/\(appName).app/Info.plist")),
                kind: .regularFile(isExecutable: false),
                content: infoBytes
            ),
            ArchiveWriteEntry(
                path: try XCTUnwrap(ArchivePath(rawValue: "Payload/\(appName).app/\(appName)")),
                kind: .regularFile(isExecutable: true),
                content: execBytes
            )
        ]
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }
        try ZipArchiveWriter().writeArchive(entries: entries, policy: .default) { chunk in
            try handle.write(contentsOf: chunk)
        }
    }

    private static func makeSignableArm64Executable() -> Data {
        let pageSize = 16_384
        var data = Data(count: pageSize * 2)
        func put32(_ o: Int, _ v: UInt32) {
            data[o] = UInt8(v & 0xFF)
            data[o + 1] = UInt8((v >> 8) & 0xFF)
            data[o + 2] = UInt8((v >> 16) & 0xFF)
            data[o + 3] = UInt8((v >> 24) & 0xFF)
        }
        func put64(_ o: Int, _ v: UInt64) {
            put32(o, UInt32(v & 0xFFFF_FFFF))
            put32(o + 4, UInt32((v >> 32) & 0xFFFF_FFFF))
        }
        func putName(_ o: Int, _ s: String) {
            for (i, b) in s.utf8.prefix(16).enumerated() { data[o + i] = b }
        }

        put32(0, 0xFEED_FACF)
        put32(4, 0x0100_000C)
        put32(8, 0)
        put32(12, 0x2) // MH_EXECUTE
        put32(16, 3)
        put32(20, 72 + 152 + 72)
        put32(24, 0x0020_0000) // MH_PIE

        // 1. __PAGEZERO at 32 (72 bytes)
        put32(32, 0x19)
        put32(36, 72)
        putName(40, "__PAGEZERO")
        put64(56, 0)
        put64(64, 0x1_0000_0000)

        // 2. __TEXT + 1 section (__text) at 104 (152 bytes)
        let textCmd = 104
        put32(textCmd, 0x19)
        put32(textCmd + 4, 152)
        putName(textCmd + 8, "__TEXT")
        put64(textCmd + 24, 0x1_0000_0000)
        put64(textCmd + 32, UInt64(pageSize))
        put64(textCmd + 40, 0)
        put64(textCmd + 48, UInt64(pageSize))
        put32(textCmd + 56, 5)
        put32(textCmd + 60, 5)
        put32(textCmd + 64, 1)

        let sect = textCmd + 72
        putName(sect, "__text")
        putName(sect + 16, "__TEXT")
        put64(sect + 32, 0x1_0000_1000)
        put64(sect + 40, 64)
        put32(sect + 48, 4096)

        // 3. __LINKEDIT at 256 (72 bytes)
        let linkCmd = 256
        put32(linkCmd, 0x19)
        put32(linkCmd + 4, 72)
        putName(linkCmd + 8, "__LINKEDIT")
        put64(linkCmd + 24, 0x1_0000_4000)
        put64(linkCmd + 32, UInt64(pageSize))
        put64(linkCmd + 40, UInt64(pageSize))
        put64(linkCmd + 48, UInt64(pageSize))
        put32(linkCmd + 56, 1)
        put32(linkCmd + 60, 1)
        put32(linkCmd + 64, 0)

        return data
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
}
