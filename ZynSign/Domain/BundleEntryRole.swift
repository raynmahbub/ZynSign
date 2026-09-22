/// The bundle-internal names the explorer recognizes, in addition to the
/// package-level names `IPALayout` already declares.
///
/// These are conventional locations inside an application bundle. Naming
/// them lets the explorer label an entry for orientation; it does not make
/// any of them required, and a bundle that lacks one is not thereby wrong.
extension IPALayout {

    /// The provisioning profile an application may carry at its bundle root.
    static let embeddedProvisioningProfileFileName = "embedded.mobileprovision"

    /// The directory in which a code signature keeps its resource records.
    static let codeSignatureDirectoryName = "_CodeSignature"

    /// The resource record inside the code signature directory.
    static let codeResourcesFileName = "CodeResources"

    /// The directory bundled frameworks and dynamic libraries are kept in.
    static let frameworksDirectoryName = "Frameworks"

    /// The directory application extensions and plug-in bundles are kept in.
    static let plugInsDirectoryName = "PlugIns"

    /// A directory some applications use for extension bundles.
    static let extensionsDirectoryName = "Extensions"
}

/// A descriptive label for a bundle entry at a conventionally significant
/// location.
///
/// A role is recognized from an entry's location, its name, and its kind —
/// nothing else. It is presentation metadata: it tells the user what a
/// file at that location conventionally is, so that `Info.plist` or
/// `_CodeSignature` can be found among hundreds of resources. It draws no
/// conclusion. Recognizing an embedded provisioning profile does not read
/// it; recognizing a code signature directory does not mean the application
/// is signed, that any signature is valid, or that the application is
/// trusted or installable. Those questions belong to later stages with
/// their own vocabularies, and nothing here answers them.
///
/// Names are matched exactly. The bundle is destined for a case-sensitive
/// filesystem, where `info.plist` is not the bundle information file.
enum BundleEntryRole: String, CaseIterable, Hashable {

    /// The bundle information file at the bundle root.
    case bundleInformation

    /// The regular file at the bundle root whose name the bundle's declared
    /// metadata names as the executable.
    case executable

    /// The provisioning profile at the bundle root.
    case embeddedProvisioningProfile

    /// The code signature directory at the bundle root.
    case codeSignatureDirectory

    /// The resource record inside the code signature directory.
    case codeResources

    /// The frameworks directory at the bundle root.
    case frameworksDirectory

    /// The plug-ins directory at the bundle root.
    case plugInsDirectory

    /// The extensions directory at the bundle root.
    case extensionsDirectory

    /// Recognizes the role of an entry, or returns `nil` when the entry is at
    /// no conventionally significant location.
    ///
    /// `declaredExecutableName` is the executable name the bundle's metadata
    /// declared, when known. It is a declaration: the entry it names is
    /// labelled as the executable, and nothing is opened to confirm that.
    static func recognize(
        path: BundlePath,
        kind: ArchiveEntryKind,
        declaredExecutableName: String? = nil
    ) -> BundleEntryRole? {
        let components = path.components
        switch (components.count, kind) {
        case (1, .regularFile):
            let name = components[0]
            if name == IPALayout.bundleInformationFileName {
                return .bundleInformation
            }
            if name == IPALayout.embeddedProvisioningProfileFileName {
                return .embeddedProvisioningProfile
            }
            if let executable = declaredExecutableName, !executable.isEmpty, name == executable {
                return .executable
            }
            return nil

        case (1, .directory):
            switch components[0] {
            case IPALayout.codeSignatureDirectoryName: return .codeSignatureDirectory
            case IPALayout.frameworksDirectoryName: return .frameworksDirectory
            case IPALayout.plugInsDirectoryName: return .plugInsDirectory
            case IPALayout.extensionsDirectoryName: return .extensionsDirectory
            default: return nil
            }

        case (2, .regularFile):
            if components[0] == IPALayout.codeSignatureDirectoryName,
               components[1] == IPALayout.codeResourcesFileName {
                return .codeResources
            }
            return nil

        default:
            return nil
        }
    }

    /// A short label for presentation.
    var displayName: String {
        switch self {
        case .bundleInformation: return "Bundle information file"
        case .executable: return "Declared executable"
        case .embeddedProvisioningProfile: return "Embedded provisioning profile"
        case .codeSignatureDirectory: return "Code signature directory"
        case .codeResources: return "Code signature resource record"
        case .frameworksDirectory: return "Frameworks directory"
        case .plugInsDirectory: return "Plug-ins directory"
        case .extensionsDirectory: return "Extensions directory"
        }
    }

    /// A description of what an entry at this location conventionally is,
    /// written to state what this build does and does not do with it.
    var explanation: String {
        switch self {
        case .bundleInformation:
            return "The property list in which the application declares its identifier, names, versions, and executable. ZynSign reads it during import; what it declares remains untrusted."
        case .executable:
            return "The file the bundle's information file names as the application's executable. ZynSign lists it and does not open, load, or run it."
        case .embeddedProvisioningProfile:
            return "A provisioning profile embedded in the bundle. This build does not read or evaluate profiles, and the file's presence says nothing about whether the application can be installed."
        case .codeSignatureDirectory:
            return "The directory in which a code signature keeps its resource records. Its presence is a filesystem observation, not evidence that the application is signed or that any signature is valid."
        case .codeResources:
            return "The record a code signature keeps of the bundle's sealed resources. This build does not read or verify it; its presence does not mean the application is signed or that its signature is valid."
        case .frameworksDirectory:
            return "The directory in which frameworks and dynamic libraries bundled with the application are kept."
        case .plugInsDirectory:
            return "The directory in which application extensions and other plug-in bundles are kept."
        case .extensionsDirectory:
            return "A directory some applications use for extension bundles."
        }
    }
}
