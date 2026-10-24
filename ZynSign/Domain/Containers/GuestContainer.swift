import Foundation

/// A guest application the host runs itself, instead of handing it to the
/// device's installer.
///
/// This is the LiveContainer model: the package never reaches
/// `installation_proxy`. It is unpacked into a container the host owns, its
/// main executable is turned into something `dlopen` will map, the loader is
/// linked into it, and it is signed ad-hoc because no provisioning profile
/// takes part. What the host must then do at launch — and what each step
/// needs from the platform — is recorded here as a plan, so no screen can
/// claim a guest will run when one of the prerequisites is missing.
enum GuestContainer {

    /// The container's layout inside the host's Documents directory.
    enum Layout {
        static let applications = "Applications"
        static let appBundle = "App.app"
        static let tweaks = "Tweaks"
        static let data = "Data"
        static let info = "LCAppInfo.plist"
        static let manifest = "LCContainer.json"
        static let loaderName = "TweakLoader.dylib"
        static let entryPoint = "main"

        static func containerPath(bundleIdentifier: String) -> String {
            "\(applications)/\(bundleIdentifier)"
        }

        static func guestPath(bundleIdentifier: String) -> String {
            "\(containerPath(bundleIdentifier: bundleIdentifier))/\(appBundle)"
        }

        static func dataPath(bundleIdentifier: String) -> String {
            "\(containerPath(bundleIdentifier: bundleIdentifier))/\(data)"
        }

        /// The directories a guest expects to find in its own container.
        static let dataDirectories = [
            "Documents", "Library/Preferences", "Library/Caches", "tmp",
        ]
    }

    /// One fact that stops a guest from running in-process. Each case is a
    /// platform fact, not a judgment about the app's quality.
    enum Block: String, CaseIterable, Hashable, Sendable {
        case fairplayEncrypted
        case notPositionIndependent
        case missingExecutable
        case appExtensions
        case watchApp
        case universalBinary
        case loaderUnavailable

        var message: String {
            switch self {
            case .fairplayEncrypted:
                return "The binary is FairPlay-encrypted; in-process loading cannot decrypt it."
            case .notPositionIndependent:
                return "The binary is not position independent, so it cannot be mapped into the host."
            case .missingExecutable:
                return "The bundle does not contain the executable its Info.plist declares."
            case .appExtensions:
                return "The app ships an app extension, which cannot run inside the host."
            case .watchApp:
                return "The app ships a watchOS bundle, which cannot run inside the host."
            case .universalBinary:
                return "The executable is a universal binary; the container needs one arm64 slice."
            case .loaderUnavailable:
                return "No tweak loader is bundled, so the host cannot resolve guest entry points."
            }
        }
    }

    /// One caveat that does not stop the guest but changes what it can do.
    enum Warning: String, CaseIterable, Hashable, Sendable {
        case requiresJIT
        case metalRequired
        case minimumOSNewerThanHost
        case tweaksNotStaged

        var message: String {
            switch self {
            case .requiresJIT:
                return "The guest asks for just-in-time compilation, which needs a debugger relationship."
            case .metalRequired:
                return "The guest declares a Metal requirement."
            case .minimumOSNewerThanHost:
                return "The guest declares a minimum OS newer than the host's deployment target."
            case .tweaksNotStaged:
                return "No tweaks are staged; the loader will start the guest without hooks."
            }
        }
    }

    /// The metadata the host lists the guest from.
    struct Metadata: Equatable, Sendable {
        let name: String
        let bundleIdentifier: String
        let version: String
        let buildVersion: String
        let executable: String
        let dataIdentifier: String
        let stagingMode: String
        let tweaks: [String]
        let injectedLibraries: [String]
        let requiresJIT: Bool

        /// The property-list form written to `LCAppInfo.plist`.
        func propertyList() -> [String: Any] {
            [
                "LCAppName": name,
                "LCBundleId": bundleIdentifier,
                "LCVersion": version,
                "LCBuildVersion": buildVersion,
                "LCExecutable": executable,
                "LCDataUUID": dataIdentifier,
                "LCGuestPath": Layout.guestPath(bundleIdentifier: bundleIdentifier),
                "LCDataPath": Layout.dataPath(bundleIdentifier: bundleIdentifier),
                "LCTweaks": tweaks,
                "LCInjectedLibraries": injectedLibraries,
                "LCSignature": stagingMode,
                "LCRequiresJIT": requiresJIT,
                "LCContainerVersion": 1,
                "LCLaunchArgument": Layout.entryPoint,
            ]
        }
    }

    /// What the app knows about a candidate guest before preparing it.
    struct Evidence: Equatable, Sendable {
        let bundleIdentifier: String
        let name: String
        let version: String
        let executableName: String
        let executableExists: Bool
        let isEncrypted: Bool
        let isPositionIndependent: Bool
        let isUniversal: Bool
        let nestedBundleKinds: [String]
        let minimumOSVersion: String
        let requiresJIT: Bool
        let requiresMetal: Bool
        let loaderBundled: Bool
        let stagedTweaks: Int

        init(
            bundleIdentifier: String,
            name: String,
            version: String,
            executableName: String,
            executableExists: Bool = true,
            isEncrypted: Bool = false,
            isPositionIndependent: Bool = true,
            isUniversal: Bool = false,
            nestedBundleKinds: [String] = [],
            minimumOSVersion: String = "15.0",
            requiresJIT: Bool = false,
            requiresMetal: Bool = false,
            loaderBundled: Bool = true,
            stagedTweaks: Int = 0
        ) {
            self.bundleIdentifier = bundleIdentifier
            self.name = name
            self.version = version
            self.executableName = executableName
            self.executableExists = executableExists
            self.isEncrypted = isEncrypted
            self.isPositionIndependent = isPositionIndependent
            self.isUniversal = isUniversal
            self.nestedBundleKinds = nestedBundleKinds
            self.minimumOSVersion = minimumOSVersion
            self.requiresJIT = requiresJIT
            self.requiresMetal = requiresMetal
            self.loaderBundled = loaderBundled
            self.stagedTweaks = stagedTweaks
        }
    }

    /// The verdict, with reasons in a fixed order.
    struct Assessment: Equatable, Sendable {
        let bundleIdentifier: String
        let name: String
        let version: String
        let blocks: [Block]
        let warnings: [Warning]
        let metadata: Metadata

        var isRunnable: Bool { blocks.isEmpty }

        var summary: String {
            if let first = blocks.first {
                return "Not runnable: \(first.message)"
            }
            if !warnings.isEmpty {
                return "Runnable with \(warnings.count) caveat\(warnings.count == 1 ? "" : "s")."
            }
            return "Runnable in the container."
        }

        var spokenSummary: String {
            "\(name), version \(version). \(summary)"
        }
    }

    /// Evaluate the evidence. Nothing is guessed: a fact that was not
    /// established reads as a block or a warning, never as a pass.
    static func assess(_ evidence: Evidence,
                       hostMinimumOS: String = "17.0") -> Assessment {
        var blocks: [Block] = []
        var warnings: [Warning] = []
        if evidence.isEncrypted { blocks.append(.fairplayEncrypted) }
        if !evidence.isPositionIndependent { blocks.append(.notPositionIndependent) }
        if evidence.isUniversal { blocks.append(.universalBinary) }
        if !evidence.executableExists { blocks.append(.missingExecutable) }
        if evidence.nestedBundleKinds.contains("appex") { blocks.append(.appExtensions) }
        if evidence.nestedBundleKinds.contains("app") { blocks.append(.watchApp) }
        if !evidence.loaderBundled { blocks.append(.loaderUnavailable) }
        if evidence.requiresJIT { warnings.append(.requiresJIT) }
        if evidence.requiresMetal { warnings.append(.metalRequired) }
        if let order = DeclaredVersionOrder.compare(
            version: hostMinimumOS, build: nil,
            with: evidence.minimumOSVersion, build: nil),
           order == .orderedAscending {
            warnings.append(.minimumOSNewerThanHost)
        }
        if evidence.stagedTweaks == 0 { warnings.append(.tweaksNotStaged) }

        return Assessment(
            bundleIdentifier: evidence.bundleIdentifier,
            name: evidence.name,
            version: evidence.version,
            blocks: blocks,
            warnings: warnings,
            metadata: Metadata(
                name: evidence.name,
                bundleIdentifier: evidence.bundleIdentifier,
                version: evidence.version,
                buildVersion: evidence.version,
                executable: evidence.executableName,
                dataIdentifier: "primary",
                stagingMode: "adhoc",
                tweaks: [],
                injectedLibraries: [],
                requiresJIT: evidence.requiresJIT
            )
        )
    }

    /// The runtime sequence, with everything it depends on named.
    ///
    /// The plan is not executed by this type: the launch itself belongs to the
    /// host's own lifecycle, and every step below names its requirement so a
    /// screen can show why it is not done yet.
    static func launchPlan(for assessment: Assessment) -> [LaunchStep] {
        var steps: [LaunchStep] = []
        if assessment.blocks.contains(.loaderUnavailable) {
            steps.append(LaunchStep(
                title: "Blocked: no tweak loader",
                detail: "A prebuilt TweakLoader.dylib must ship in the app bundle; "
                    + "the host cannot resolve guest entry points without it.",
                requirement: .bundledLoader))
        }
        steps.append(LaunchStep(
            title: "Map the guest image",
            detail: "dlopen(\"\(Layout.guestPath(bundleIdentifier: assessment.bundleIdentifier))/"
                + "\(assessment.metadata.executable)\", RTLD_NOW). The image was patched from "
                + "MH_EXECUTE to MH_DYLIB before signing, which is what makes this legal.",
            requirement: .guestPatched))
        steps.append(LaunchStep(
            title: "Resolve the entry point",
            detail: "dlsym(handle, \"\(Layout.entryPoint)\") must return a non-null pointer.",
            requirement: .guestPatched))
        steps.append(LaunchStep(
            title: "Redirect the container",
            detail: "Point NSHomeDirectory, NSTemporaryDirectory and the default "
                + "UserDefaults suite at \(Layout.dataPath(bundleIdentifier: assessment.bundleIdentifier)) "
                + "before calling the guest.",
            requirement: .containerRedirect))
        steps.append(LaunchStep(
            title: "Take over the run loop",
            detail: "Call the guest's entry point on the main thread; the UIApplicationMain "
                + "inside it becomes the process's application delegate loop.",
            requirement: .mainThreadEntry))
        steps.append(LaunchStep(
            title: "Swizzle the bundle identity",
            detail: "NSBundle.mainBundle, the URL-scheme handler and the document "
                + "interaction controller must answer as the guest while it runs.",
            requirement: .bundleSwizzling))
        return steps
    }

    /// One step and the platform fact it needs.
    struct LaunchStep: Equatable, Sendable {
        let title: String
        let detail: String
        let requirement: Requirement
    }

    /// What a step needs. Every case is a real prerequisite, not a label.
    enum Requirement: String, CaseIterable, Hashable, Sendable {
        case bundledLoader
        case guestPatched
        case containerRedirect
        case mainThreadEntry
        case bundleSwizzling

        var message: String {
            switch self {
            case .bundledLoader:
                return "A signed TweakLoader.dylib in the app bundle."
            case .guestPatched:
                return "A guest image patched to MH_DYLIB and signed ad-hoc."
            case .containerRedirect:
                return "A container path the host can redirect at launch."
            case .mainThreadEntry:
                return "The main thread, before the host's own run loop starts."
            case .bundleSwizzling:
                return "Runtime swizzling of the bundle and scheme entry points."
            }
        }
    }
}
