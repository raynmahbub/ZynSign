import Foundation

/// What the Import Hub learned about an application package right after it
/// passed validation, in addition to the identity it declares.
///
/// Every fact here is read from the package's own entry table and declared
/// information; nothing is executed, verified, or inferred. In particular
/// the signing state records whether a signature is *present* — ZynSign has
/// not checked it, and nothing on screen may call it valid.
///
/// The analysis is `Codable` so it can be cached next to the application's
/// icon; it is always recomputable from the package itself.
struct ApplicationAnalysis: Equatable, Hashable, Sendable, Codable {

    /// Whether the application bundle carries a code signature.
    enum SigningState: String, Equatable, Hashable, Sendable, Codable {

        /// The bundle has a `_CodeSignature/CodeResources` seal. Presence
        /// only: the signature has not been verified.
        case signaturePresent

        /// The bundle has no signature seal.
        case unsigned

        /// The label shown for the state.
        var displayName: String {
            switch self {
            case .signaturePresent: return "Signature present"
            case .unsigned: return "Not signed"
            }
        }

        /// A sentence stating exactly what the state means.
        var explanation: String {
            switch self {
            case .signaturePresent:
                return "The application carries a code signature. ZynSign has not verified it."
            case .unsigned:
                return "The application carries no code signature."
            }
        }

        /// The SF Symbol shown beside the state.
        var symbolName: String {
            switch self {
            case .signaturePresent: return "signature"
            case .unsigned: return "seal"
            }
        }
    }

    /// Whether the bundle carries a code signature.
    let signingState: SigningState

    /// Whether the bundle embeds a provisioning profile.
    let includesProvisioningProfile: Bool

    /// The number of `.framework` bundles in the application's
    /// `Frameworks` folder.
    let frameworkCount: Int

    /// The number of app extensions (`.appex`) in the application's
    /// `PlugIns` and `Extensions` folders.
    let extensionCount: Int

    /// The number of regular files in the package.
    let fileCount: Int

    /// The sum of the sizes the package records for its files once
    /// unpacked.
    let unpackedByteCount: Int

    /// The minimum operating system version the application declares.
    let minimumOSVersion: String?

    /// The device families the application declares, as display names.
    let supportedDevices: [String]

    init(
        signingState: SigningState,
        includesProvisioningProfile: Bool,
        frameworkCount: Int,
        extensionCount: Int,
        fileCount: Int,
        unpackedByteCount: Int,
        minimumOSVersion: String? = nil,
        supportedDevices: [String] = []
    ) {
        self.signingState = signingState
        self.includesProvisioningProfile = includesProvisioningProfile
        self.frameworkCount = max(0, frameworkCount)
        self.extensionCount = max(0, extensionCount)
        self.fileCount = max(0, fileCount)
        self.unpackedByteCount = max(0, unpackedByteCount)
        self.minimumOSVersion = minimumOSVersion
        self.supportedDevices = supportedDevices
    }

    // MARK: - Derivation

    /// The folder names, inside an application bundle, that hold app
    /// extensions.
    static let extensionFolderNames = ["PlugIns", "Extensions"]

    /// Derives the analysis from a package's entry table.
    ///
    /// `bundleRoot` is the application bundle's path inside the package;
    /// when it is unknown only the package-wide counts are filled in.
    /// `metadata`, when available, supplies the declared minimum OS and
    /// device families.
    static func derive(
        from entries: [ArchiveEntry],
        bundleRoot: ArchivePath?,
        metadata: ApplicationMetadata?
    ) -> ApplicationAnalysis {
        var fileCount = 0
        var unpackedByteCount = 0
        var frameworks: Set<String> = []
        var extensions: Set<String> = []
        var hasSignatureSeal = false
        var hasProfile = false

        let rootComponents = bundleRoot?.components
        let depth = rootComponents?.count ?? 0

        for entry in entries {
            guard let path = entry.path else { continue }
            if entry.kind == .regularFile {
                fileCount += 1
                let (sum, overflow) = unpackedByteCount.addingReportingOverflow(entry.uncompressedSize)
                unpackedByteCount = overflow ? Int.max : sum
            }

            guard let rootComponents else { continue }
            let components = path.components
            guard components.count > depth, components.prefix(depth).elementsEqual(rootComponents) else {
                continue
            }
            let relative = Array(components.dropFirst(depth))

            if relative.count >= 2, relative[0] == "Frameworks", hasSuffix(relative[1], ".framework") {
                frameworks.insert(relative[1])
            }
            if relative.count >= 2, extensionFolderNames.contains(relative[0]), hasSuffix(relative[1], ".appex") {
                extensions.insert(relative[0] + "/" + relative[1])
            }
            if entry.kind == .regularFile, relative == ["_CodeSignature", "CodeResources"] {
                hasSignatureSeal = true
            }
            if entry.kind == .regularFile, relative == ["embedded.mobileprovision"] {
                hasProfile = true
            }
        }

        return ApplicationAnalysis(
            signingState: hasSignatureSeal ? .signaturePresent : .unsigned,
            includesProvisioningProfile: hasProfile,
            frameworkCount: frameworks.count,
            extensionCount: extensions.count,
            fileCount: fileCount,
            unpackedByteCount: unpackedByteCount,
            minimumOSVersion: metadata?.minimumOSVersion,
            supportedDevices: (metadata?.deviceFamily ?? []).map(deviceName(for:))
        )
    }

    private static func hasSuffix(_ component: String, _ suffix: String) -> Bool {
        component.count > suffix.count && component.lowercased().hasSuffix(suffix)
    }

    private static func deviceName(for family: ApplicationDeviceFamily) -> String {
        switch family {
        case .phone: return "iPhone"
        case .pad: return "iPad"
        case .tv: return "Apple TV"
        case .watch: return "Apple Watch"
        case .visionOS: return "Apple Vision"
        case .unknown(let value): return "Device family \(value)"
        }
    }
}
