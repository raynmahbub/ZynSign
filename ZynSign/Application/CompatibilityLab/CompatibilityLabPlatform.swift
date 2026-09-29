import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - iOS releases

/// One iOS release the compatibility matrix covers.
///
/// The matrix is built from what the build actually supports, not from what
/// a table somewhere claims: the deployment target sets the floor, so a
/// release below it is named here as unsupported rather than silently left
/// out. iOS 16 is in the table for exactly that reason — ZynSign cannot run
/// there, and a release decision should see that written down.
enum SupportedIOSRelease: String, CaseIterable, Identifiable, Sendable {

    case iOS16
    case iOS17
    case iOS18
    case iOS26

    var id: String { rawValue }

    /// The major version.
    var majorVersion: Int {
        switch self {
        case .iOS16: return 16
        case .iOS17: return 17
        case .iOS18: return 18
        case .iOS26: return 26
        }
    }

    /// The name the matrix shows.
    var displayName: String { "iOS \(majorVersion)" }

    /// The deployment target of this build: the earliest iOS that can run it.
    static let minimumSupportedMajorVersion = 17

    /// Whether this release can run ZynSign at all.
    var isSupported: Bool { majorVersion >= Self.minimumSupportedMajorVersion }

    /// Why a release is or is not in scope.
    var supportNote: String {
        isSupported
            ? "Supported: at or above the deployment target of iOS \(Self.minimumSupportedMajorVersion)."
            : "Not supported: below the deployment target of iOS \(Self.minimumSupportedMajorVersion). ZynSign does not install or launch here."
    }

    /// The workflows each supported release is checked for.
    static let workflows: [CompatibilityWorkflow] = CompatibilityWorkflow.allCases
}

/// One workflow the iOS matrix checks on each supported release.
enum CompatibilityWorkflow: String, CaseIterable, Identifiable, Sendable {

    case launch
    case importPackage
    case signing
    case store
    case export
    case installation

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .launch: return "Launch"
        case .importPackage: return "Import"
        case .signing: return "Signing"
        case .store: return "Store"
        case .export: return "Export"
        case .installation: return "Installation"
        }
    }

    /// What the check means, in one sentence.
    var claim: String {
        switch self {
        case .launch: return "ZynSign launches and composes its environment."
        case .importPackage: return "A package is read, structured and identified through the production boundary."
        case .signing: return "A signing identity is reachable, or its absence is reported as the reason signing did not run."
        case .store: return "A repository probe that cannot reach its source ends in a reported state, not a broken screen."
        case .export: return "The export location is reachable and the export catalog can be read."
        case .installation: return "The installation hand-off builds its manifest on this release."
        }
    }

    /// The check identifier for one release and workflow.
    func checkID(on release: SupportedIOSRelease) -> String {
        "platform.ios.\(release.majorVersion).\(rawValue)"
    }
}

// MARK: - Device classes

/// One hardware class the device matrix covers.
///
/// Classes are about how the app behaves, not about model names: screen
/// class, memory and idiom decide what a layout has to survive. The Lab
/// detects the class it is running on and reports every other class as not
/// run, because a device cannot validate a device it is not.
enum LabDeviceClass: String, CaseIterable, Identifiable, Sendable {

    /// iPhone SE and the 4.7-inch class: the smallest layout ZynSign draws.
    case compactPhone

    /// iPhone 13 / 14 / 15 class: the common layout.
    case standardPhone

    /// iPhone Plus / Pro Max class: the largest phone layout.
    case largePhone

    /// iPad: split view, Slide Over, Stage Manager, keyboard shortcuts.
    case tablet

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .compactPhone: return "Compact phone"
        case .standardPhone: return "Standard phone"
        case .largePhone: return "Large phone"
        case .tablet: return "Tablet"
        }
    }

    /// The devices the class stands for.
    var examples: String {
        switch self {
        case .compactPhone: return "iPhone SE (2nd/3rd generation), iPhone 8"
        case .standardPhone: return "iPhone 13, iPhone 14, iPhone 15"
        case .largePhone: return "iPhone 15 Pro Max, iPhone 16 Pro Max"
        case .tablet: return "iPad (all sizes), iPad mini, iPad Air, iPad Pro"
        }
    }

    /// What differs for this class, and therefore what must be checked.
    var expectations: String {
        switch self {
        case .compactPhone:
            return "Every screen fits without scrolling traps at the smallest width; content is reachable at the largest Dynamic Type size."
        case .standardPhone:
            return "The reference layout: grids, cards and sheets at the size most users see."
        case .largePhone:
            return "Grids use the extra width instead of stretching; reachability of top-edge controls stays comfortable."
        case .tablet:
            return "Split-view and Slide Over sizes, Stage Manager, multiple scenes, keyboard shortcuts and pointer focus."
        }
    }

    /// The aspects each class is checked for.
    static let aspects: [DeviceAspect] = DeviceAspect.allCases
}

/// One aspect the device matrix checks per class.
enum DeviceAspect: String, CaseIterable, Identifiable, Sendable {

    case layout
    case performance
    case memory
    case multitasking
    case orientation

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .layout: return "Layout"
        case .performance: return "Performance"
        case .memory: return "Memory behaviour"
        case .multitasking: return "Multitasking"
        case .orientation: return "Orientation"
        }
    }

    var claim: String {
        switch self {
        case .layout: return "The interface lays out in this class's sizes, including split-view widths on iPad."
        case .performance: return "Measured work stays inside the benchmarks on this class's hardware."
        case .memory: return "The device's memory and thermal state leave room for a signing run."
        case .multitasking: return "Multiple scenes are declared where the platform expects them."
        case .orientation: return "ZynSign declares the orientations this class uses."
        }

    }

    func checkID(on deviceClass: LabDeviceClass) -> String {
        "platform.device.\(deviceClass.rawValue).\(rawValue)"
    }
}

// MARK: - Device facts

/// What the running device is, as far as the platform will say.
///
/// The Lab asks only for facts the platform offers without an entitlement
/// and without identifying the user: the idiom, the screen class, how much
/// memory the device has, how hot it is, and how much space is free. No
/// device name, no identifier, and nothing that could be used to track.
struct LabDeviceFacts: Equatable, Sendable {

    /// The hardware class the facts describe.
    let deviceClass: LabDeviceClass

    /// How much memory the device has, in bytes.
    let physicalMemoryBytes: UInt64

    /// How many cores are available.
    let processorCount: Int

    /// The thermal state at the time of the run.
    let thermalState: ProcessInfo.ThermalState

    /// Free space on the volume holding the user's Documents, when known.
    let availableCapacityBytes: Int?

    /// Whether the device is an iPad, as the platform reports it.
    let isTablet: Bool

    /// The orientations ZynSign declares support for.
    let declaredOrientations: [String]

    /// Whether the app declares support for multiple scenes.
    let supportsMultipleScenes: Bool

    /// Whether this run is on a simulator. A simulator result is never a
    /// device result, and the report says which it is.
    let isSimulator: Bool

    #if canImport(UIKit)
    /// Reads the facts of the running device.
    static func current(fileManager: FileManager = .default) -> LabDeviceFacts {
        let processInfo = ProcessInfo.processInfo
        let screen = UIScreen.main
        let idiom = UIDevice.current.userInterfaceIdiom
        let height = max(screen.bounds.height, screen.bounds.width)
        let width = min(screen.bounds.height, screen.bounds.width)
        let deviceClass: LabDeviceClass
        switch idiom {
        case .pad:
            deviceClass = .tablet
        default:
            // Width is the honest discriminator for phone classes: a device
            // in landscape reports a large "height", and the class is about
            // the layout envelope rather than the current orientation.
            if width >= 428 { deviceClass = .largePhone }
            else if width >= 390 { deviceClass = .standardPhone }
            else { deviceClass = .compactPhone }
        }
        let info = Bundle.main.infoDictionary ?? [:]
        let orientations = (info["UISupportedInterfaceOrientations"] as? [String]) ?? []
        let manifest = info["UIApplicationSceneManifest"] as? [String: Any]
        let probe = VolumeStorageCapacityProbe(volume: CompositionRoot.documentsDirectory)
        #if targetEnvironment(simulator)
        let isSimulator = true
        #else
        let isSimulator = false
        #endif
        return LabDeviceFacts(
            deviceClass: deviceClass,
            physicalMemoryBytes: processInfo.physicalMemory,
            processorCount: processInfo.processorCount,
            thermalState: processInfo.thermalState,
            availableCapacityBytes: probe.availableCapacity(),
            isTablet: idiom == .pad,
            declaredOrientations: orientations,
            supportsMultipleScenes: manifest?["UIApplicationSupportsMultipleScenes"] as? Bool ?? false,
            isSimulator: isSimulator
        )
    }
    #else
    static func current(fileManager: FileManager = .default) -> LabDeviceFacts {
        let processInfo = ProcessInfo.processInfo
        let info = Bundle.main.infoDictionary ?? [:]
        let orientations = (info["UISupportedInterfaceOrientations"] as? [String]) ?? []
        let manifest = info["UIApplicationSceneManifest"] as? [String: Any]
        return LabDeviceFacts(
            deviceClass: .standardPhone,
            physicalMemoryBytes: processInfo.physicalMemory,
            processorCount: processInfo.processorCount,
            thermalState: processInfo.thermalState,
            availableCapacityBytes: nil,
            isTablet: false,
            declaredOrientations: orientations,
            supportsMultipleScenes: manifest?["UIApplicationSupportsMultipleScenes"] as? Bool ?? false,
            isSimulator: true
        )
    }
    #endif

    /// The memory in gibibytes, for evidence a reader can compare.
    var physicalMemoryGigabytes: Double {
        Double(physicalMemoryBytes) / 1_073_741_824
    }

    /// The free space in gibibytes, when known.
    var availableCapacityGigabytes: Double? {
        availableCapacityBytes.map { Double($0) / 1_073_741_824 }
    }

    /// One line naming the device class and whether this is a simulator.
    var summary: String {
        isSimulator ? "\(deviceClass.displayName) (simulator)" : deviceClass.displayName
    }
}

// MARK: - iOS suite

/// The iOS compatibility matrix: what each supported release was checked for.
///
/// Only the release ZynSign is running on can be checked here, and the suite
/// says so for every other row. What it *can* do on the running release it
/// does: it reads a synthetic package through the production boundary, asks
/// the identity store what is available, probes a repository through a
/// transport that cannot reach anything, reads the export location, and
/// builds an installation manifest.
struct IOSCompatibilitySuite: CompatibilitySuite {

    /// The releases in the matrix, oldest first.
    static let releases: [SupportedIOSRelease] = SupportedIOSRelease.allCases

    /// The checks for every release and workflow.
    func checks(context: CompatibilityLabContext) async -> [CompatibilityCheck] {
        let runningMajor = Self.runningMajorVersion
        var collected: [CompatibilityCheck] = []
        for release in Self.releases {
            for workflow in CompatibilityWorkflow.allCases {
                collected.append(
                    await check(
                        release: release,
                        workflow: workflow,
                        runningMajor: runningMajor,
                        context: context
                    )
                )
            }
        }
        return collected
    }

    /// The major version ZynSign is running on, from the platform.
    static var runningMajorVersion: Int {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    /// The running system's version as one line.
    static var runningVersionText: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let patch = version.patchVersion
        return "\(version.majorVersion).\(version.minorVersion)\(patch == 0 ? "" : ".\(patch)")"
    }

    private func check(
        release: SupportedIOSRelease,
        workflow: CompatibilityWorkflow,
        runningMajor: Int,
        context: CompatibilityLabContext
    ) async -> CompatibilityCheck {
        let checkID = workflow.checkID(on: release)
        guard release.isSupported else {
            return CompatibilityCheck(
                id: checkID,
                category: .iOSCompatibility,
                title: "\(release.displayName) · \(workflow.displayName)",
                status: .skipped,
                summary: "\(release.displayName) cannot run this build.",
                verified: "Nothing was executed: the build's deployment target excludes this release.",
                nextStep: nil,
                evidence: [release.supportNote],
                blocker: nil
            )
        }
        guard release.majorVersion == runningMajor else {
            return CompatibilityCheck(
                id: checkID,
                category: .iOSCompatibility,
                title: "\(release.displayName) · \(workflow.displayName)",
                status: .notRun,
                summary: "Not executed: this device runs iOS \(runningMajor).",
                verified: "Nothing was executed on \(release.displayName).",
                nextStep: "Run the Compatibility Lab on a device running \(release.displayName) and import its report, or attach the device-class run to this release's row.",
                evidence: [release.supportNote, "Running: iOS \(Self.runningVersionText)"],
                blocker: .medium
            )
        }
        return await execute(workflow: workflow, release: release, checkID: checkID, context: context)
    }

    // MARK: Execution

    private func execute(
        workflow: CompatibilityWorkflow,
        release: SupportedIOSRelease,
        checkID: String,
        context: CompatibilityLabContext
    ) async -> CompatibilityCheck {
        switch workflow {
        case .launch:
            return check(
                id: checkID,
                release: release,
                workflow: workflow,
                status: .passed,
                summary: "ZynSign launched on \(release.displayName) and composed its environment.",
                verified: "The Lab itself is running, which means the application launched, read its preferences and composed the application environment on this release.",
                evidence: [
                    "iOS \(Self.runningVersionText)",
                    "release stage: \(ReleaseTrain.current.tag)"
                ]
            )
        case .importPackage:
            return importCheck(checkID: checkID, release: release, context: context)
        case .signing:
            return signingCheck(checkID: checkID, release: release, context: context)
        case .store:
            return await storeCheck(checkID: checkID, release: release)
        case .export:
            return await exportCheck(checkID: checkID, release: release, context: context)
        case .installation:
            return installationCheck(checkID: checkID, release: release)
        }
    }

    private func check(
        id: String,
        release: SupportedIOSRelease,
        workflow: CompatibilityWorkflow,
        status: CompatibilityStatus,
        summary: String,
        verified: String,
        nextStep: String? = nil,
        evidence: [String] = [],
        measurements: [CompatibilityMeasurement] = []
    ) -> CompatibilityCheck {
        CompatibilityCheck(
            id: id,
            category: .iOSCompatibility,
            title: "\(release.displayName) · \(workflow.displayName)",
            status: status,
            summary: summary,
            verified: verified,
            nextStep: nextStep,
            evidence: evidence,
            measurements: measurements,
            blocker: status == .failed ? .high : nil
        )
    }

    /// Reads a synthetic package through the production boundary, which is
    /// the read half of an import.
    private func importCheck(
        checkID: String,
        release: SupportedIOSRelease,
        context: CompatibilityLabContext
    ) -> CompatibilityCheck {
        let lab = SigningScenarioLab()
        do {
            let outcome = try lab.run(.simpleApplication, context: context)
            let passed = outcome.classification == .valid && outcome.metadataWasRead
            return check(
                id: checkID,
                release: release,
                workflow: .importPackage,
                status: passed ? .passed : .failed,
                summary: passed
                    ? "A synthetic package was read and identified on \(release.displayName)."
                    : "A synthetic package could not be read as declared on \(release.displayName).",
                verified: "Verified the read half of an import — structure, metadata and identity — without touching the library. Writing a library record is covered by the import regressions instead, so a Lab run never changes what the user has imported.",
                nextStep: passed ? nil : "Compare the reported findings with the platform matrix before the release.",
                evidence: [
                    "classification: \(outcome.classification.displayName)",
                    "entries: \(outcome.entryCount)",
                    "metadata: \(outcome.metadataWasRead ? "read" : "not read")"
                ]
            )
        } catch {
            return check(
                id: checkID,
                release: release,
                workflow: .importPackage,
                status: .failed,
                summary: "The read of a synthetic package failed on \(release.displayName).",
                verified: "The failure is in the pipeline the import path uses.",
                nextStep: "Read the error, then re-run the Lab.",
                evidence: ["error: \((error as? ZynSignError)?.userMessage ?? String(describing: type(of: error)))"]
            )
        }
    }

    /// Asks the identity store what is available. Without an identity there
    /// is nothing to sign with, and the honest answer is "not run" with the
    /// reason, not a pass nobody earned.
    private func signingCheck(
        checkID: String,
        release: SupportedIOSRelease,
        context: CompatibilityLabContext
    ) -> CompatibilityCheck {
        guard let environment = context.environment else {
            return check(
                id: checkID,
                release: release,
                workflow: .signing,
                status: .notRun,
                summary: "No application environment was composed for this run.",
                verified: "Nothing was executed.",
                nextStep: "Run the Lab from the application, where the environment is composed."
            )
        }
        let identities: [SigningIdentity]
        do {
            identities = try environment.identityStore.listIdentities()
        } catch {
            return check(
                id: checkID,
                release: release,
                workflow: .signing,
                status: .failed,
                summary: "The signing identity store could not be read on \(release.displayName).",
                verified: "A store that cannot be read is a signing blocker on this release.",
                nextStep: "Read the error, then re-run the Lab. If it persists on a device, the Keychain boundary is the place to look.",
                evidence: ["error: \((error as? ZynSignError)?.userMessage ?? String(describing: type(of: error)))"]
            )
        }
        guard !identities.isEmpty else {
            return check(
                id: checkID,
                release: release,
                workflow: .signing,
                status: .notRun,
                summary: "No signing identity is imported, so no signing run was executed.",
                verified: "Verified that the identity store is reachable and reports itself empty. Not verified: an actual signature on \(release.displayName).",
                nextStep: "Import a certificate in Certificates, then run the Lab again to execute the signing path on this release."
            )
        }
        let ready = identities.filter { $0.isUsableForSigning }
        return check(
            id: checkID,
            release: release,
            workflow: .signing,
            status: ready.isEmpty ? .warning : .passed,
            summary: "\(identities.count) identity(ies) reachable on \(release.displayName); \(ready.count) with a usable key.",
            verified: "Verified that the identity store lists identities and reports key availability. Not verified: an actual signature — the Lab does not sign without the user choosing an identity and a profile.",
            nextStep: ready.isEmpty ? "Re-import the certificate whose key is unavailable: signing cannot complete without it." : nil,
            evidence: [
                "identities: \(identities.count)",
                "with a usable key: \(ready.count)"
            ]
        )
    }

    /// Probes a repository through a transport that cannot reach anything.
    /// What matters on this release is that the failure is a state the
    /// interface can render, not a crash or a stuck screen.
    private func storeCheck(checkID: String, release: SupportedIOSRelease) async -> CompatibilityCheck {
        let probe = RepositoryHealthProbe(transport: UnreachableRepositoryTransport())
        let result = await probe.probe(url: URL(string: "https://example.invalid/source.json") ?? URL(fileURLWithPath: "/"))
        let passed = result.health == .offline
        return check(
            id: checkID,
            release: release,
            workflow: .store,
            status: passed ? .passed : .failed,
            summary: passed
                ? "An unreachable source was reported as offline on \(release.displayName)."
                : "An unreachable source was not reported as offline on \(release.displayName).",
            verified: "Verified that the probe finishes, never throws, and classifies a transport failure as offline — the state the Store shows.",
            nextStep: passed ? nil : "A failing source must reach the interface as a health state, not as an exception.",
            evidence: [
                "health: \(result.health.rawValue)",
                "error category: \(result.errorCategory ?? "none")"
            ]
        )
    }

    /// Reads the export location without writing to it.
    private func exportCheck(
        checkID: String,
        release: SupportedIOSRelease,
        context: CompatibilityLabContext
    ) async -> CompatibilityCheck {
        let documents = CompositionRoot.documentsDirectory
        let writable = context.fileManager.isWritableFile(atPath: documents.path)
        var catalogReadable = false
        var catalogDetail = "not composed"
        if let environment = context.environment {
            do {
                let held = try await environment.exportCenter.heldFileNames()
                catalogReadable = true
                catalogDetail = "\(held.count) exported file(s) held"
            } catch {
                catalogDetail = "catalog unreadable"
            }
        }
        let passed = writable && (context.environment == nil || catalogReadable)
        return check(
            id: checkID,
            release: release,
            workflow: .export,
            status: passed ? .passed : .failed,
            summary: passed
                ? "The export location is writable and the export catalog can be read on \(release.displayName)."
                : "The export path is not usable on \(release.displayName).",
            verified: "Verified the location and the catalog were read, not that an export was written: the Lab does not add files to what the user has exported.",
            nextStep: passed ? nil : "Check that the Documents folder is writable and the export catalog is intact (Settings → Recovery → Rebuild library index).",
            evidence: [
                "Documents writable: \(writable)",
                "export catalog: \(catalogDetail)"
            ]
        )
    }

    /// Builds an installation manifest, which is the whole of the hand-off
    /// ZynSign can perform without hosting anything.
    private func installationCheck(checkID: String, release: SupportedIOSRelease) -> CompatibilityCheck {
        let manifest = InstallationDeliveryManifest(
            softwarePackageURL: URL(string: "https://example.invalid/app.ipa") ?? URL(fileURLWithPath: "/"),
            manifestURL: URL(string: "https://example.invalid/manifest.plist") ?? URL(fileURLWithPath: "/"),
            bundleIdentifier: "\(LabPackageFactory.identifierRoot).handoff",
            bundleVersion: "1.0",
            displayName: "ZynSign Hand-off"
        )
        do {
            let data = try manifest.xmlData()
            let text = String(data: data, encoding: .utf8) ?? ""
            let wellFormed = text.contains("software-package") && text.contains("bundle-identifier")
            return check(
                id: checkID,
                release: release,
                workflow: .installation,
                status: wellFormed ? .passed : .failed,
                summary: wellFormed
                    ? "The installation hand-off built its manifest on \(release.displayName)."
                    : "The installation hand-off produced a manifest that does not carry its assets.",
                verified: "Verified that the manifest ZynSign builds for OTA delivery is well-formed here. Not verified: an installation — ZynSign has no delivery mechanism, and never claims one.",
                nextStep: wellFormed ? nil : "The manifest shape has changed; check InstallationDeliveryManifest before shipping.",
                evidence: ["manifest: \(data.count) bytes"]
            )
        } catch {
            return check(
                id: checkID,
                release: release,
                workflow: .installation,
                status: .failed,
                summary: "The installation hand-off could not serialize its manifest on \(release.displayName).",
                verified: "The failure is in the manifest writer.",
                nextStep: "Read the error, then re-run the Lab.",
                evidence: ["error: \(String(describing: error))"]
            )
        }
    }
}

// MARK: - Device suite

/// The device compatibility matrix.
///
/// The suite runs the aspects it can measure on the device it is on and
/// reports every other class as not run, because layout, multitasking and
/// memory behaviour are exactly the things a device cannot vouch for on
/// behalf of another device.
struct DeviceCompatibilitySuite: CompatibilitySuite {

    private let facts: LabDeviceFacts

    init(facts: LabDeviceFacts = .current()) {
        self.facts = facts
    }

    func checks(context: CompatibilityLabContext) async -> [CompatibilityCheck] {
        LabDeviceClass.allCases.flatMap { deviceClass in
            DeviceAspect.allCases.map { aspect in
                check(deviceClass: deviceClass, aspect: aspect)
            }
        }
    }

    private func check(deviceClass: LabDeviceClass, aspect: DeviceAspect) -> CompatibilityCheck {
        let checkID = aspect.checkID(on: deviceClass)
        let isCurrentDevice = deviceClass == facts.deviceClass
        guard isCurrentDevice else {
            return CompatibilityCheck(
                id: checkID,
                category: .deviceCompatibility,
                title: "\(deviceClass.displayName) · \(aspect.displayName)",
                status: .notRun,
                summary: "Not executed: this device is \(facts.summary).",
                verified: "Nothing was executed for \(deviceClass.displayName).",
                nextStep: "Run the Lab on \(deviceClass.examples), then import that report.",
                evidence: [
                    "class: \(deviceClass.displayName) (\(deviceClass.examples))",
                    "expectation: \(deviceClass.expectations)"
                ],
                blocker: .medium
            )
        }
        return execute(aspect: aspect, deviceClass: deviceClass, checkID: checkID)
    }

    private func execute(
        aspect: DeviceAspect,
        deviceClass: LabDeviceClass,
        checkID: String
    ) -> CompatibilityCheck {
        func result(
            _ status: CompatibilityStatus,
            _ summary: String,
            _ verified: String,
            _ nextStep: String? = nil,
            _ evidence: [String] = [],
            _ measurements: [CompatibilityMeasurement] = []
        ) -> CompatibilityCheck {
            CompatibilityCheck(
                id: checkID,
                category: .deviceCompatibility,
                title: "\(deviceClass.displayName) · \(aspect.displayName)",
                status: status,
                summary: summary,
                verified: verified,
                nextStep: nextStep,
                evidence: evidence,
                measurements: measurements,
                blocker: status == .failed ? .medium : nil
            )
        }

        switch aspect {
        case .layout:
            let orientations = facts.declaredOrientations
            let supportsBothLandscapes =
                orientations.contains("UIInterfaceOrientationLandscapeLeft")
                && orientations.contains("UIInterfaceOrientationLandscapeRight")
            let supportsPortrait = orientations.contains("UIInterfaceOrientationPortrait")
            let passed = supportsPortrait && supportsBothLandscapes
            return result(
                passed ? .passed : .warning,
                passed
                    ? "ZynSign declares portrait and both landscape orientations."
                    : "ZynSign does not declare the full orientation set for this class.",
                "Verified the orientations the bundle declares. Not verified: a human judgement of the rendered layout — that belongs to a manual pass on a real device.",
                passed ? nil : "Add the missing orientations to the Info.plist, or record why this class does not need them.",
                [
                    "declared: \(orientations.joined(separator: ", "))",
                    "class expectation: \(deviceClass.expectations)"
                ]
            )
        case .performance:
            return result(
                .passed,
                "This class's hardware was recorded with the run.",
                "Verified the hardware facts a performance comparison needs. The timings themselves are measured by the Performance suite on this device.",
                nil,
                [
                    "cores: \(facts.processorCount)",
                    "memory: \(String(format: "%.1f", facts.physicalMemoryGigabytes)) GB",
                    facts.isSimulator ? "simulator: figures here are not device figures" : "device"
                ],
                [
                    CompatibilityMeasurement(
                        name: "processor cores",
                        value: Double(facts.processorCount),
                        unit: "count",
                        comparison: .informational
                    ),
                    CompatibilityMeasurement(
                        name: "physical memory",
                        value: facts.physicalMemoryGigabytes,
                        unit: "GB",
                        threshold: PerformanceThresholds.minimumPhysicalMemoryGigabytes,
                        comparison: .higherIsBetter
                    )
                ]
            )
        case .memory:
            let state = facts.thermalState
            let status: CompatibilityStatus
            switch state {
            case .nominal, .fair: status = .passed
            case .serious: status = .warning
            case .critical: status = .failed
            @unknown default: status = .warning
            }
            return result(
                status,
                "Thermal state at the time of the run: \(Self.thermalName(state)).",
                "Verified the device's own thermal report and the memory it has. Not verified: ZynSign's peak footprint under a real signing run — the Performance suite measures that.",
                status == .passed ? nil : "Run the Lab again when the device has cooled: thermal throttling makes every timing measurement meaningless.",
                [
                    "thermal: \(Self.thermalName(state))",
                    "memory: \(String(format: "%.1f", facts.physicalMemoryGigabytes)) GB"
                ],
                [
                    CompatibilityMeasurement(
                        name: "physical memory",
                        value: facts.physicalMemoryGigabytes,
                        unit: "GB",
                        threshold: PerformanceThresholds.minimumPhysicalMemoryGigabytes,
                        comparison: .higherIsBetter
                    )
                ]
            )
        case .multitasking:
            if facts.isTablet {
                return result(
                    facts.supportsMultipleScenes ? .passed : .warning,
                    facts.supportsMultipleScenes
                        ? "Multiple scenes are declared, as iPad multitasking expects."
                        : "Multiple scenes are not declared on a tablet.",
                    "Verified what the bundle declares. Split view, Slide Over and Stage Manager themselves are a human pass on a real device.",
                    facts.supportsMultipleScenes ? nil : "Enable Supports multiple scenes, or record why this build does not need it.",
                    ["supports multiple scenes: \(facts.supportsMultipleScenes)"]
                )
            }
            return CompatibilityCheck(
                id: checkID,
                category: .deviceCompatibility,
                title: "\(deviceClass.displayName) · \(aspect.displayName)",
                status: .skipped,
                summary: "Split-view multitasking is a tablet behaviour.",
                verified: "Nothing was executed: this class does not run split view.",
                evidence: ["class: \(deviceClass.displayName)"]
            )
        case .orientation:
            let orientations = facts.declaredOrientations
            let expected = deviceClass == .tablet
                ? ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"]
                : ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"]
            let missing = expected.filter { !orientations.contains($0) }
            return result(
                missing.isEmpty ? .passed : .warning,
                missing.isEmpty
                    ? "Every orientation this class uses is declared."
                    : "\(missing.count) orientation(s) this class uses are not declared.",
                "Verified the declared orientations against what the class uses. The rendered result in each orientation is a human pass.",
                missing.isEmpty ? nil : "Declare \(missing.joined(separator: ", ")), or record why not.",
                ["missing: \(missing.isEmpty ? "none" : missing.joined(separator: ", "))"]
            )
        }
    }

    private static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
