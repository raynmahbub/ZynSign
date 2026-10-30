import Foundation

/// Runtime loader port for probing and preparing in-process `MH_DYLIB` guest
/// bundles inside ZynSign's Host Container.
struct GuestRuntimeProbeReport: Equatable, Sendable {
    let imageLoadable: Bool
    let entrySymbolFound: Bool
    let diagnosticMessage: String
}

protocol GuestRuntimeLoading: Sendable {
    var isBundledLoaderPresent: Bool { get }
    func probeGuestExecutable(
        at executableURL: URL,
        entrySymbol: String,
        guest: HostedGuestDescriptor,
        containerRoot: URL,
        guestBundleURL: URL,
        activeDataDirectory: URL
    ) throws -> GuestRuntimeProbeReport
}

/// Experimental guest staging and inspection in `Documents/Applications/`.
/// Separate data directories are not sandbox isolation; staging or a successful
/// loader probe does not establish full application execution or compatibility.
@MainActor
final class GuestContainerHostService: ObservableObject {

    enum HostError: Error, LocalizedError {
        case guestNotFound(String)
        case missingBundleMetadata
        case invalidBundleMetadata
        case guestAlreadyExists(String)
        case cannotDeletePrimarySlot
        case slotNotFound(String)

        var errorDescription: String? {
            switch self {
            case .guestNotFound(let id):
                return "No hosted guest container found for \(id)."
            case .missingBundleMetadata:
                return "The package is missing Info.plist, CFBundleIdentifier, or CFBundleExecutable."
            case .invalidBundleMetadata:
                return "The bundle identifier or executable name is not safe for container storage."
            case .guestAlreadyExists(let id):
                return "A container for \(id) already exists. Existing data was not replaced."
            case .cannotDeletePrimarySlot:
                return "The primary data profile cannot be deleted."
            case .slotNotFound(let id):
                return "Data profile '\(id)' does not exist in this container."
            }
        }
    }

    struct PendingLaunch: Equatable, Identifiable, Sendable {
        var id: String { "\(bundleIdentifier):\(slotID)" }
        let bundleIdentifier: String
        let slotID: String
        let probe: GuestRuntimeProbeReport
        let requestedAt: Date
    }

    @Published private(set) var hostedGuests: [HostedGuestDescriptor]
    @Published var lastLaunchAttempt: PendingLaunch?
    @Published var statusBanner: String?

    let documentsDirectory: URL
    private let runtimeLoader: any GuestRuntimeLoading
    private let adHocSigner: AdHocMachOSigner
    private let makeReader: @Sendable (URL) -> any ArchiveReader
    private let makeWriter: @Sendable () -> any ArchiveWriter

    var applicationsRoot: URL {
        documentsDirectory.appendingPathComponent(GuestContainer.Layout.applications, isDirectory: true)
    }

    var isBundledLoaderAvailable: Bool {
        runtimeLoader.isBundledLoaderPresent
    }

    nonisolated init(
        documentsDirectory: URL,
        runtimeLoader: any GuestRuntimeLoading,
        adHocSigner: AdHocMachOSigner = AdHocMachOSigner(),
        makeReader: @escaping @Sendable (URL) -> any ArchiveReader = { ZipArchiveReader(location: $0) },
        makeWriter: @escaping @Sendable () -> any ArchiveWriter = { ZipArchiveWriter() }
    ) {
        self.documentsDirectory = documentsDirectory
        self.runtimeLoader = runtimeLoader
        self.adHocSigner = adHocSigner
        self.makeReader = makeReader
        self.makeWriter = makeWriter
        let root = documentsDirectory.appendingPathComponent(GuestContainer.Layout.applications, isDirectory: true)
        self._hostedGuests = Published(initialValue: Self.discoverHostedGuests(at: root))
    }

    // MARK: - Discovery & Persistence

    func reload() {
        hostedGuests = Self.discoverHostedGuests(at: applicationsRoot)
    }

    private nonisolated static func discoverHostedGuests(at applicationsRoot: URL) -> [HostedGuestDescriptor] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: applicationsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var loaded: [HostedGuestDescriptor] = []
        for dir in entries {
            if let descriptor = Self.readDescriptor(in: dir) {
                loaded.append(descriptor)
            }
        }
        return loaded.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    // MARK: - Stage IPA into Host Container

    @discardableResult
    func stagePackage(
        from ipaURL: URL,
        customDisplayName: String? = nil,
        tweakDylibURLs: [URL] = [],
        sharedAppGroupIsolation: Bool = true
    ) async throws -> HostedGuestDescriptor {
        let fm = FileManager.default
        let tempWork = fm.temporaryDirectory
            .appendingPathComponent("zynsign-guest-stage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempWork, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempWork) }

        let extractedApp = try await extractSingleAppBundle(from: ipaURL, into: tempWork)
        let appValues = try extractedApp.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard appValues.isDirectory == true, appValues.isSymbolicLink != true else { throw HostError.invalidBundleMetadata }
        let infoURL = extractedApp.appendingPathComponent("Info.plist")
        let infoValues = try infoURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard infoValues.isRegularFile == true, infoValues.isSymbolicLink != true else { throw HostError.invalidBundleMetadata }
        guard let infoData = try? Data(contentsOf: infoURL),
              var infoPlist = try? PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any],
              let bundleID = infoPlist["CFBundleIdentifier"] as? String,
              let execName = infoPlist["CFBundleExecutable"] as? String,
              !bundleID.isEmpty, !execName.isEmpty else {
            throw HostError.missingBundleMetadata
        }

        guard BundleIdentifier(rawValue: bundleID) != nil,
              let executablePath = ArchivePath(rawValue: execName),
              executablePath.rawValue == execName,
              executablePath.components.count == 1 else {
            throw HostError.invalidBundleMetadata
        }
        let execValues = try extractedApp.appendingPathComponent(execName)
            .resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard execValues.isRegularFile == true, execValues.isSymbolicLink != true else { throw HostError.invalidBundleMetadata }
        let finalContainerDir = applicationsRoot.appendingPathComponent(bundleID, isDirectory: true)
        guard !fm.fileExists(atPath: finalContainerDir.path) else {
            throw HostError.guestAlreadyExists(bundleID)
        }

        let resolvedName = customDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyValue
            ?? (infoPlist["CFBundleDisplayName"] as? String)?.nonEmptyValue
            ?? (infoPlist["CFBundleName"] as? String)?.nonEmptyValue
            ?? bundleID
        let shortVersion = (infoPlist["CFBundleShortVersionString"] as? String) ?? "1.0"
        let buildVersion = (infoPlist["CFBundleVersion"] as? String) ?? shortVersion

        stripUnsupportedNestedBundles(in: extractedApp)
        if let customName = customDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyValue {
            infoPlist["CFBundleDisplayName"] = customName
            let rewritten = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
            try rewritten.write(to: infoURL, options: .atomic)
        }

        // Build beside the final destination, so publication does not require
        // a cross-volume copy. Failed preparation is cleaned up separately.
        try fm.createDirectory(at: applicationsRoot, withIntermediateDirectories: true)
        let containerDir = applicationsRoot.appendingPathComponent(".zynsign-stage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: containerDir, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: containerDir) }

        let (stagedTweakNames, injectedInstallNames) = try stageContainerTweaks(
            tweakDylibURLs,
            in: containerDir
        )
        let patchOutcome = try patchAndMoveGuestBundle(
            extractedApp: extractedApp,
            containerDir: containerDir,
            bundleID: bundleID,
            execName: execName,
            injectedInstallNames: injectedInstallNames
        )

        let primarySlot = GuestDataSlot.primary()
        let stagedData = containerDir.appendingPathComponent(GuestContainer.Layout.data, isDirectory: true)
        for subdirectory in GuestContainer.Layout.dataDirectories {
            try fm.createDirectory(at: stagedData.appendingPathComponent(subdirectory, isDirectory: true),
                                   withIntermediateDirectories: true)
        }
        let requiresJIT = detectJITHint(in: infoPlist)
        let descriptor = HostedGuestDescriptor(
            bundleIdentifier: bundleID,
            displayName: resolvedName,
            shortVersion: shortVersion,
            buildVersion: buildVersion,
            executableName: execName,
            activeSlotID: primarySlot.id,
            slots: [primarySlot],
            stagedTweaks: stagedTweakNames,
            injectedLibraries: patchOutcome.injectedInstallNames,
            requiresJIT: requiresJIT,
            jitlessCompatible: !requiresJIT,
            sharedAppGroupIsolation: sharedAppGroupIsolation,
            stagedAt: Date(),
            lastLaunchedAt: nil
        )
        try writeDescriptor(descriptor, in: containerDir)
        try Task.checkCancellation()
        // moveItem refuses an existing destination, including a concurrent one.
        try fm.moveItem(at: containerDir, to: finalContainerDir)
        reload()
        statusBanner = "Staged \(resolvedName) for experimental guest inspection; execution is not guaranteed."
        return descriptor
    }

    private func extractSingleAppBundle(from ipaURL: URL, into tempWork: URL) async throws -> URL {
        let limits = ArchiveLimits.default
        let reader = makeReader(ipaURL)
        defer { reader.close() }
        let entries = try reader.readEntryTable()
        guard case .exactlyOne(let bundleArchivePath) = ApplicationBundleDiscovery.discover(in: entries).outcome else {
            throw ZynSignError.missingApplicationBundle(diagnosticDetail: "Expected a single Payload/*.app bundle.")
        }
        let policy = ArchiveExtractionPolicy(
            maximumExtractedBytes: limits.maximumTotalUncompressedBytes,
            maximumLinkTargetBytes: limits.maximumEntryNameLength,
            symlinkPolicy: .recreateWithinRoot
        )
        _ = try await DirectoryArchiveExtractor(
            destination: tempWork,
            policy: policy,
            readBound: limits.maximumEntryBytes
        ).extract(reader: reader)
        var extractedApp = tempWork
        for component in bundleArchivePath.components {
            extractedApp.appendPathComponent(component)
        }
        return extractedApp
    }

    private func stripUnsupportedNestedBundles(in extractedApp: URL) {
        let fm = FileManager.default
        for unsupportedSubdir in ["PlugIns", "Watch", "Extensions"] {
            let subURL = extractedApp.appendingPathComponent(unsupportedSubdir, isDirectory: true)
            if fm.fileExists(atPath: subURL.path) {
                try? fm.removeItem(at: subURL)
            }
        }
    }

    private func stageContainerTweaks(_ tweakDylibURLs: [URL], in containerDir: URL) throws -> ([String], [String]) {
        let fm = FileManager.default
        let tweaksDir = containerDir.appendingPathComponent(GuestContainer.Layout.tweaks, isDirectory: true)
        try fm.createDirectory(at: tweaksDir, withIntermediateDirectories: true)
        var stagedTweakNames: [String] = []
        var injectedInstallNames: [String] = []
        if runtimeLoader.isBundledLoaderPresent {
            injectedInstallNames.append("@rpath/\(GuestContainer.Layout.loaderName)")
        }
        for tweakURL in tweakDylibURLs where fm.fileExists(atPath: tweakURL.path) {
            let dest = tweaksDir.appendingPathComponent(tweakURL.lastPathComponent)
            if var tweakBytes = try? Data(contentsOf: tweakURL) {
                if tweakBytes.count >= 32 {
                    if let arm64 = try? GuestMachOPatcher.extractArm64Slice(tweakBytes) {
                        tweakBytes = arm64
                    }
                    if let stripped = try? MachOCodeSignatureStripper.stripSignature(from: tweakBytes) {
                        tweakBytes = stripped
                    }
                    if let adHocSigned = try? adHocSigner.signMachO(
                        tweakBytes,
                        identifier: tweakURL.deletingPathExtension().lastPathComponent
                    ) {
                        tweakBytes = adHocSigned.signedBytes
                    }
                }
                try? tweakBytes.write(to: dest, options: .atomic)
            } else {
                try? fm.copyItem(at: tweakURL, to: dest)
            }
            stagedTweakNames.append(tweakURL.lastPathComponent)
            injectedInstallNames.append("@executable_path/../../\(GuestContainer.Layout.tweaks)/\(tweakURL.lastPathComponent)")
        }
        return (stagedTweakNames, injectedInstallNames)
    }

    private func patchAndMoveGuestBundle(
        extractedApp: URL,
        containerDir: URL,
        bundleID: String,
        execName: String,
        injectedInstallNames: [String]
    ) throws -> GuestMachOPatcher.GuestBinaryPatchOutcome {
        let execURL = extractedApp.appendingPathComponent(execName)
        let originalExecBytes = try Data(contentsOf: execURL)
        let backupExecURL = containerDir.appendingPathComponent("\(execName).zynorig")
        try originalExecBytes.write(to: backupExecURL, options: .atomic)

        normalizeNestedMachOImages(in: extractedApp, excludingRootExecutable: execURL)

        let patchOutcome = try GuestMachOPatcher.patchExecutableForGuestRuntime(
            originalExecBytes,
            installID: "@rpath/\(execName)",
            injectedInstallNames: injectedInstallNames
        )
        try patchOutcome.binary.write(to: execURL, options: .atomic)
        let guestAppDest = containerDir.appendingPathComponent(GuestContainer.Layout.appBundle, isDirectory: true)
        try FileManager.default.moveItem(at: extractedApp, to: guestAppDest)
        _ = try adHocSigner.signBundleDirectory(at: guestAppDest, bundleIdentifier: bundleID, executableName: execName)
        return patchOutcome
    }

    private func normalizeNestedMachOImages(in appDirectory: URL, excludingRootExecutable rootExecURL: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: appDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let rootStandardized = rootExecURL.standardizedFileURL
        for case let fileURL as URL in enumerator {
            guard fileURL.standardizedFileURL != rootStandardized else { continue }
            guard let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  vals.isRegularFile == true,
                  vals.isSymbolicLink != true,
                  let data = try? Data(contentsOf: fileURL),
                  data.count >= 32 else { continue }
            var current = data
            var changed = false
            if let arm64 = try? GuestMachOPatcher.extractArm64Slice(current), arm64 != current {
                current = arm64
                changed = true
            }
            if let stripped = try? MachOCodeSignatureStripper.stripSignature(from: current), stripped != current {
                current = stripped
                changed = true
            }
            if changed {
                try? current.write(to: fileURL, options: .atomic)
            }
        }
    }

    // MARK: - Multi-Profile Sandbox Slots

    @discardableResult
    func createDataSlot(for bundleIdentifier: String, label: String) throws -> GuestDataSlot {
        guard var guest = hostedGuests.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            throw HostError.guestNotFound(bundleIdentifier)
        }
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyValue ?? "Profile \(guest.slots.count + 1)"
        let slug = "slot-\(UUID().uuidString.prefix(8).lowercased())"
        let slot = GuestDataSlot(id: slug, label: cleanLabel, createdAt: Date())
        try ensureSandboxDirectories(for: bundleIdentifier, slot: slot)
        guest.slots.append(slot)
        guest.activeSlotID = slot.id
        try writeDescriptor(guest, in: applicationsRoot.appendingPathComponent(bundleIdentifier, isDirectory: true))
        reload()
        return slot
    }

    func switchActiveSlot(for bundleIdentifier: String, to slotID: String) throws {
        guard var guest = hostedGuests.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            throw HostError.guestNotFound(bundleIdentifier)
        }
        guard let slot = guest.slots.first(where: { $0.id == slotID }) else {
            throw HostError.slotNotFound(slotID)
        }
        try ensureSandboxDirectories(for: bundleIdentifier, slot: slot)
        guest.activeSlotID = slot.id
        try writeDescriptor(guest, in: applicationsRoot.appendingPathComponent(bundleIdentifier, isDirectory: true))
        reload()
    }

    func deleteDataSlot(for bundleIdentifier: String, slotID: String) throws {
        guard slotID != "primary" else { throw HostError.cannotDeletePrimarySlot }
        guard var guest = hostedGuests.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            throw HostError.guestNotFound(bundleIdentifier)
        }
        guard let slot = guest.slots.first(where: { $0.id == slotID }) else {
            throw HostError.slotNotFound(slotID)
        }
        let slotDir = documentsDirectory.appendingPathComponent(slot.relativeDataPath(bundleIdentifier: bundleIdentifier), isDirectory: true)
        if FileManager.default.fileExists(atPath: slotDir.path) {
            try FileManager.default.removeItem(at: slotDir)
        }
        guest.slots.removeAll { $0.id == slotID }
        if guest.activeSlotID == slotID {
            guest.activeSlotID = "primary"
        }
        try writeDescriptor(guest, in: applicationsRoot.appendingPathComponent(bundleIdentifier, isDirectory: true))
        reload()
    }

    // MARK: - Container Backup, Standalone IPA Conversion & WebClip

    func exportSlotDataArchive(for bundleIdentifier: String, slotID: String? = nil) async throws -> URL {
        guard let guest = hostedGuests.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            throw HostError.guestNotFound(bundleIdentifier)
        }
        let targetID = slotID ?? guest.activeSlotID
        guard let slot = guest.slots.first(where: { $0.id == targetID }) else {
            throw HostError.slotNotFound(targetID)
        }
        let slotDir = documentsDirectory.appendingPathComponent(
            slot.relativeDataPath(bundleIdentifier: bundleIdentifier),
            isDirectory: true
        )
        let exportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zynsign-container-backups", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let archiveURL = exportDir.appendingPathComponent("\(bundleIdentifier)-\(slot.id)-data.zip")
        try packDirectory(at: slotDir, rootPrefix: "ContainerData", to: archiveURL)
        return archiveURL
    }

    func exportStandaloneIPA(for bundleIdentifier: String) async throws -> URL {
        guard let guest = hostedGuests.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            throw HostError.guestNotFound(bundleIdentifier)
        }
        let fm = FileManager.default
        let containerDir = applicationsRoot.appendingPathComponent(bundleIdentifier, isDirectory: true)
        let stagedApp = containerDir.appendingPathComponent(GuestContainer.Layout.appBundle, isDirectory: true)
        let workDir = fm.temporaryDirectory.appendingPathComponent("zynsign-standalone-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let safeBundleName = "\(guest.displayName.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }).app"
        let bundleName = safeBundleName == ".app" ? "Application.app" : safeBundleName
        let tempApp = workDir.appendingPathComponent(bundleName, isDirectory: true)
        try fm.copyItem(at: stagedApp, to: tempApp)

        // Restore original MH_EXECUTE binary when preserved.
        let origExec = containerDir.appendingPathComponent("\(guest.executableName).zynorig")
        if fm.fileExists(atPath: origExec.path) {
            let destExec = tempApp.appendingPathComponent(guest.executableName)
            try? fm.removeItem(at: destExec)
            try fm.copyItem(at: origExec, to: destExec)
        }

        let outDir = fm.temporaryDirectory.appendingPathComponent("zynsign-standalone-exports", isDirectory: true)
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        let outURL = outDir.appendingPathComponent("\(guest.bundleIdentifier)-Standalone.ipa")
        let packager = PackageSignedApplication(writer: makeWriter(), makeReader: makeReader)
        _ = try await packager.package(
            PackageSignedApplicationRequest(
                bundleDirectory: tempApp,
                bundleName: bundleName,
                outputURL: outURL
            )
        )
        return outURL
    }

    func generateWebClipProfile(for bundleIdentifier: String, slotID: String? = nil) throws -> Data {
        guard let guest = hostedGuests.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            throw HostError.guestNotFound(bundleIdentifier)
        }
        return try GuestWebClipProfileBuilder.buildMobileConfig(guest: guest, slotID: slotID)
    }

    func removeHostedGuest(_ bundleIdentifier: String) throws {
        guard BundleIdentifier(rawValue: bundleIdentifier) != nil,
              hostedGuests.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            throw HostError.guestNotFound(bundleIdentifier)
        }
        let dir = applicationsRoot.appendingPathComponent(bundleIdentifier, isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
        reload()
    }

    // MARK: - Readiness & Launch Handoff

    func assessGuest(_ bundleIdentifier: String) -> GuestContainer.Assessment? {
        guard let guest = hostedGuests.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return nil
        }
        let execURL = applicationsRoot
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent(GuestContainer.Layout.appBundle, isDirectory: true)
            .appendingPathComponent(guest.executableName)
        let data = try? Data(contentsOf: execURL)
        let inspection = data.flatMap { GuestMachOPatcher.inspectCandidateBinary($0) }
        let evidence = GuestContainer.Evidence(
            bundleIdentifier: guest.bundleIdentifier,
            name: guest.displayName,
            version: guest.shortVersion,
            executableName: guest.executableName,
            executableExists: data != nil,
            isEncrypted: inspection?.isFairPlayEncrypted ?? false,
            isPositionIndependent: inspection?.isPositionIndependent ?? true,
            isUniversal: inspection?.isUniversal ?? false,
            nestedBundleKinds: [],
            minimumOSVersion: inspection?.minimumOSVersion ?? "17.0",
            requiresJIT: guest.requiresJIT,
            requiresMetal: false,
            loaderBundled: runtimeLoader.isBundledLoaderPresent || guest.injectedLibraries.isEmpty,
            stagedTweaks: guest.stagedTweaks.count
        )
        return GuestContainer.assess(evidence)
    }

    func requestLaunch(bundleIdentifier: String, slotID: String? = nil) {
        lastLaunchAttempt = nil
        guard var guest = hostedGuests.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            statusBanner = "Container app \(bundleIdentifier) is not staged."
            return
        }
        if let slotID {
            do {
                try switchActiveSlot(for: bundleIdentifier, to: slotID)
                guest = hostedGuests.first(where: { $0.bundleIdentifier == bundleIdentifier }) ?? guest
            } catch {
                statusBanner = "Unable to select data profile: \(error.localizedDescription)"
                return
            }
        }
        let containerDir = applicationsRoot.appendingPathComponent(bundleIdentifier, isDirectory: true)
        let guestBundleURL = containerDir.appendingPathComponent(GuestContainer.Layout.appBundle, isDirectory: true)
        let activeSlot = guest.activeSlot
        let dataDir = documentsDirectory.appendingPathComponent(
            activeSlot.relativeDataPath(bundleIdentifier: bundleIdentifier),
            isDirectory: true
        )
        let probe: GuestRuntimeProbeReport
        do {
            try ensureSandboxDirectories(for: bundleIdentifier, slot: activeSlot)
            let execURL = guestBundleURL.appendingPathComponent(guest.executableName)
            probe = try runtimeLoader.probeGuestExecutable(
                at: execURL,
                entrySymbol: GuestContainer.Layout.entryPoint,
                guest: guest,
                containerRoot: containerDir,
                guestBundleURL: guestBundleURL,
                activeDataDirectory: dataDir
            )
        } catch {
            statusBanner = "Unable to prepare executable probe: \(error.localizedDescription)"
            return
        }
        // Mapping a dynamic library is a probe, not a launched application.
        // Do not update the persisted last-launch timestamp.
        lastLaunchAttempt = PendingLaunch(
            bundleIdentifier: bundleIdentifier,
            slotID: activeSlot.id,
            probe: probe,
            requestedAt: Date()
        )
        statusBanner = probe.diagnosticMessage
    }

    // MARK: - Internal Helpers

    private func ensureSandboxDirectories(for bundleIdentifier: String, slot: GuestDataSlot) throws {
        let fm = FileManager.default
        let base = documentsDirectory.appendingPathComponent(
            slot.relativeDataPath(bundleIdentifier: bundleIdentifier),
            isDirectory: true
        )
        for sub in GuestContainer.Layout.dataDirectories {
            try fm.createDirectory(at: base.appendingPathComponent(sub, isDirectory: true), withIntermediateDirectories: true)
        }
    }

    private func detectJITHint(in infoPlist: [String: Any]) -> Bool {
        if (infoPlist["GCSupportedGameControllers"] != nil) && (infoPlist["ZynRequiresJIT"] as? Bool == true) {
            return true
        }
        return (infoPlist["ZynRequiresJIT"] as? Bool) ?? false
    }

    private func writeDescriptor(_ descriptor: HostedGuestDescriptor, in containerDir: URL) throws {
        let plistDict = descriptor.toContainerMetadata().propertyList()
        let plistBytes = try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
        try plistBytes.write(to: containerDir.appendingPathComponent(GuestContainer.Layout.info), options: .atomic)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let descriptorJSON = try encoder.encode(descriptor)
        let descriptorObj = (try? JSONSerialization.jsonObject(with: descriptorJSON)) ?? [:]

        let manifestDict: [String: Any] = [
            "ZynContainerVersion": 1,
            "ZynBundleId": descriptor.bundleIdentifier,
            "ZynActiveSlot": descriptor.activeSlotID,
            "zynDescriptor": descriptorObj
        ]
        let manifestBytes = try JSONSerialization.data(withJSONObject: manifestDict, options: [.prettyPrinted, .sortedKeys])
        try manifestBytes.write(to: containerDir.appendingPathComponent(GuestContainer.Layout.manifest), options: .atomic)
    }

    private nonisolated static func readDescriptor(in containerDir: URL) -> HostedGuestDescriptor? {
        let manifestURL = containerDir.appendingPathComponent(GuestContainer.Layout.manifest)
        if let bytes = try? Data(contentsOf: manifestURL),
           let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
           let nested = root["zynDescriptor"],
           let nestedData = try? JSONSerialization.data(withJSONObject: nested) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let decoded = try? decoder.decode(HostedGuestDescriptor.self, from: nestedData),
               isSafeDescriptor(decoded, in: containerDir) {
                return decoded
            }
        }
        let infoURL = containerDir.appendingPathComponent(GuestContainer.Layout.info)
        guard let plistBytes = try? Data(contentsOf: infoURL),
              let dict = try? PropertyListSerialization.propertyList(from: plistBytes, options: [], format: nil) as? [String: Any],
              let bundleID = dict["ZynBundleId"] as? String,
              let name = dict["ZynAppName"] as? String,
              let exec = dict["ZynExecutable"] as? String else {
            return nil
        }
        let ver = (dict["ZynVersion"] as? String) ?? "1.0"
        let build = (dict["ZynBuildVersion"] as? String) ?? ver
        let slotID = (dict["ZynDataUUID"] as? String) ?? "primary"
        let slot = GuestDataSlot(id: slotID, label: slotID == "primary" ? "Primary Profile" : slotID, createdAt: Date())
        let needsJIT = (dict["ZynRequiresJIT"] as? Bool) ?? false
        let descriptor = HostedGuestDescriptor(
            bundleIdentifier: bundleID,
            displayName: name,
            shortVersion: ver,
            buildVersion: build,
            executableName: exec,
            activeSlotID: slot.id,
            slots: [slot],
            stagedTweaks: (dict["ZynTweaks"] as? [String]) ?? [],
            injectedLibraries: (dict["ZynInjectedLibraries"] as? [String]) ?? [],
            requiresJIT: needsJIT,
            jitlessCompatible: !needsJIT,
            sharedAppGroupIsolation: true,
            stagedAt: Date(),
            lastLaunchedAt: nil
        )
        return isSafeDescriptor(descriptor, in: containerDir) ? descriptor : nil
    }

    private nonisolated static func isSafeDescriptor(_ descriptor: HostedGuestDescriptor, in directory: URL) -> Bool {
        func isSingleComponent(_ value: String) -> Bool {
            guard let path = ArchivePath(rawValue: value) else { return false }
            return path.rawValue == value && path.components.count == 1
        }
        return BundleIdentifier(rawValue: descriptor.bundleIdentifier) != nil
            && descriptor.bundleIdentifier == directory.lastPathComponent
            && isSingleComponent(descriptor.executableName)
            && isSingleComponent(descriptor.activeSlotID)
            && descriptor.slots.allSatisfy { isSingleComponent($0.id) }
    }

    private func packDirectory(at directoryURL: URL, rootPrefix: String, to outputURL: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: outputURL.path) {
            try fm.removeItem(at: outputURL)
        }
        var entries: [ArchiveWriteEntry] = []
        if let rootArchivePath = ArchivePath(rawValue: rootPrefix) {
            entries.append(ArchiveWriteEntry(path: rootArchivePath, kind: .directory))
        }
        let base = directoryURL.standardizedFileURL.path + "/"
        if let enumerator = fm.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isExecutableKey]
        ) {
            for case let itemURL as URL in enumerator {
                let full = itemURL.standardizedFileURL.path
                guard full.hasPrefix(base) else { continue }
                let rel = String(full.dropFirst(base.count))
                guard let archivePath = ArchivePath(rawValue: "\(rootPrefix)/\(rel)"),
                      let vals = try? itemURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isExecutableKey]) else {
                    continue
                }
                if vals.isDirectory == true {
                    entries.append(ArchiveWriteEntry(path: archivePath, kind: .directory))
                } else if vals.isRegularFile == true, let data = try? Data(contentsOf: itemURL) {
                    entries.append(ArchiveWriteEntry(
                        path: archivePath,
                        kind: .regularFile(isExecutable: vals.isExecutable == true),
                        content: data
                    ))
                }
            }
        }
        _ = fm.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }
        try makeWriter().writeArchive(entries: entries, policy: .default) { chunk in
            try handle.write(contentsOf: chunk)
        }
    }
}

private extension String {
    var nonEmptyValue: String? {
        isEmpty ? nil : self
    }
}
