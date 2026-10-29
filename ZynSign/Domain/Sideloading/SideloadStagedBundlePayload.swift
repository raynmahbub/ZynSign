import Foundation

/// One bundle-structured tweak payload staged into the target `.app` working copy
/// before nested signing: a `.framework`, `.bundle`, or `.appex` directory tree
/// (either imported directly, unpacked from a `.zip`, or extracted from a `.deb`).
struct SideloadStagedBundlePayload: Codable, Equatable, Hashable, Sendable, Identifiable {

    enum PayloadType: String, Codable, Equatable, Hashable, Sendable {
        case framework
        case resourceBundle
        case appExtension

        var targetSubdirectory: String {
            switch self {
            case .framework: return "Frameworks"
            case .resourceBundle: return ""
            case .appExtension: return "PlugIns"
            }
        }
    }

    struct StagedBundleFile: Codable, Equatable, Hashable, Sendable {
        /// Path relative to the top-level bundle folder, e.g. `CydiaSubstrate.framework/CydiaSubstrate`.
        let relativePath: String
        let bytes: Data
        let isExecutable: Bool
    }

    /// Deterministic identifier derived from `topLevelName` and `payloadType`.
    var id: String { "\(payloadType.rawValue):\(topLevelName)" }

    /// Top-level folder name, e.g. `CydiaSubstrate.framework`, `Assets.bundle`, `Share.appex`.
    let topLevelName: String
    let payloadType: PayloadType
    /// Optional binary inside `.framework` to link into the main executable's load commands
    /// (e.g. `Frameworks/CydiaSubstrate.framework/CydiaSubstrate`).
    let linkedFrameworkExecutableSubpath: String?
    let files: [StagedBundleFile]

    init(
        topLevelName: String,
        payloadType: PayloadType,
        linkedFrameworkExecutableSubpath: String? = nil,
        files: [StagedBundleFile]
    ) {
        self.topLevelName = topLevelName
        self.payloadType = payloadType
        self.linkedFrameworkExecutableSubpath = linkedFrameworkExecutableSubpath
        self.files = files
    }

    var totalBytes: Int {
        files.reduce(0) { $0 + $1.bytes.count }
    }
}
