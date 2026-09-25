/// How the IPA explorer presents one bundle entry, recognized from its
/// location, name, and recorded kind.
///
/// Recognition is a label for orientation and for choosing a read-only
/// preview. It does not open the entry, and it does not decide that a file
/// is a well-formed Mach-O image, a valid signature, or an installable
/// bundle. Content inspection, when the user asks for it, is a separate
/// bounded read. Unknown entries stay visible as generic files: the explorer
/// never hides a name it cannot classify.
enum BundleFileClassification: String, Equatable, Hashable, CaseIterable {

    /// `Info.plist`, or the bundle-information role, at any depth the role
    /// vocabulary already names.
    case metadata

    /// A `.mobileprovision` file. Presence is not a profile evaluation.
    case provisioningProfile

    /// A declared executable, a conventional framework or extension
    /// executable, or a `.dylib`. A header read may still find a Mach-O
    /// image in a file this classification calls generic.
    case executable

    /// A `.framework` directory.
    case framework

    /// An `.appex` directory.
    case appExtension

    /// A file whose extension is a common image type.
    case image

    /// JSON, XML, and other text resources the explorer can show as text.
    case text

    /// A property list that is not the bundle information file.
    case propertyList

    /// A `.lproj` directory.
    case localization

    /// A compiled asset catalog (`.car`).
    case assetCatalog

    /// A directory with no more specific label.
    case folder

    /// A symbolic link. The explorer lists it and does not follow it.
    case symbolicLink

    /// An entry form the package records and ZynSign does not model.
    case unsupported

    /// A file with no more specific label. It is still listed.
    case generic

    /// Classifies `entry` from its recorded kind, name, and location.
    ///
    /// Bundle type suffixes (`.framework`, `.appex`, `.lproj`) are matched
    /// exactly, because an application bundle is destined for a
    /// case-sensitive filesystem. Image, text, and property-list extensions
    /// are matched without case so that `Icon.PNG` is still offered as an
    /// image. `Info.plist` is metadata only when the name matches exactly;
    /// `info.plist` is a different file.
    static func recognize(_ entry: BundleEntry) -> BundleFileClassification {
        switch entry.kind {
        case .symbolicLink:
            return .symbolicLink
        case .unsupported:
            return .unsupported
        case .directory:
            return directoryClassification(name: entry.name)
        case .regularFile:
            return fileClassification(entry)
        }
    }

    /// A short label for rows, inspectors, and VoiceOver.
    var displayName: String {
        switch self {
        case .metadata: return "Metadata"
        case .provisioningProfile: return "Profile"
        case .executable: return "Executable"
        case .framework: return "Framework"
        case .appExtension: return "Extension"
        case .image: return "Image"
        case .text: return "Text"
        case .propertyList: return "Property list"
        case .localization: return "Localization"
        case .assetCatalog: return "Asset catalog"
        case .folder: return "Folder"
        case .symbolicLink: return "Symbolic link"
        case .unsupported: return "Unsupported entry"
        case .generic: return "Generic file"
        }
    }

    /// Whether a directory of this classification has its own inspector page.
    var hasBundlePage: Bool {
        switch self {
        case .framework, .appExtension: return true
        default: return false
        }
    }

    private static func directoryClassification(name: String) -> BundleFileClassification {
        if hasBundleSuffix(name, ".framework") { return .framework }
        if hasBundleSuffix(name, ".appex") { return .appExtension }
        if hasBundleSuffix(name, ".lproj") { return .localization }
        return .folder
    }

    private static func fileClassification(_ entry: BundleEntry) -> BundleFileClassification {
        if entry.role == .bundleInformation || entry.name == IPALayout.bundleInformationFileName {
            return .metadata
        }
        if entry.role == .embeddedProvisioningProfile
            || entry.name == IPALayout.embeddedProvisioningProfileFileName
            || fileExtension(entry.name) == "mobileprovision" {
            return .provisioningProfile
        }
        if entry.role == .executable || isConventionalNestedExecutable(entry) || fileExtension(entry.name) == "dylib" {
            return .executable
        }
        switch fileExtension(entry.name) {
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "webp":
            return .image
        case "json", "xml", "txt", "text", "strings", "html", "htm", "css", "js", "md", "entitlements", "stringsdict", "xcprivacy", "svg":
            return .text
        case "plist":
            return .propertyList
        case "car":
            return .assetCatalog
        default:
            return .generic
        }
    }

    /// The extension without the leading dot, lowercased, or an empty string
    /// when the name has no extension. A leading dotfile such as `.gitignore`
    /// has no extension. Several dots keep the final component
    /// (`archive.tar.gz` → `gz`).
    static func fileExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        let suffix = name[name.index(after: dot)...]
        guard !suffix.isEmpty else { return "" }
        return String(suffix).lowercased()
    }

    private static func hasBundleSuffix(_ name: String, _ suffix: String) -> Bool {
        name.count > suffix.count && name.hasSuffix(suffix)
    }

    /// Whether `entry` is the conventional executable of a `.framework` or
    /// `.appex` directory: the file whose name is the bundle name without
    /// the suffix. This is a naming convention, not a Mach-O verdict.
    private static func isConventionalNestedExecutable(_ entry: BundleEntry) -> Bool {
        guard let parentName = entry.path.parent?.name else { return false }
        for suffix in [".framework", ".appex"] {
            guard hasBundleSuffix(parentName, suffix) else { continue }
            if entry.name == String(parentName.dropLast(suffix.count)) {
                return true
            }
        }
        return false
    }
}

/// Which resource-browser group an entry belongs to, if any.
///
/// The browser is a filtered view of the same tree. It does not read file
/// bytes. An entry that matches nothing here is still listed in the tree.
enum ExplorerResourceFilter {

    /// Why `entry` belongs in the resource browser, or `nil` when it does not.
    static func reason(for entry: BundleEntry) -> String? {
        switch BundleFileClassification.recognize(entry) {
        case .image:
            return "Image"
        case .localization:
            return "Localization"
        case .assetCatalog:
            return "Asset catalog"
        case .text:
            switch BundleFileClassification.fileExtension(entry.name) {
            case "json": return "JSON"
            case "xml": return "XML"
            default: break
            }
        default:
            break
        }
        if isLaunchOrIconAsset(entry.name) {
            return "Launch asset"
        }
        return nil
    }

    /// Launch screens, app icons, and iTunes artwork, recognized by name.
    /// A name match is not evidence the file is a valid image.
    static func isLaunchOrIconAsset(_ name: String) -> Bool {
        if name.contains("Launch") || name.contains("AppIcon") { return true }
        return name == "iTunesArtwork" || name.hasPrefix("iTunesArtwork@")
    }
}

/// The kind of application extension a point identifier conventionally names.
///
/// The identifier is a declaration from the extension's information file.
/// Recognizing it does not mean the extension is signed, entitled, or
/// installable.
enum ExplorerExtensionKind: Equatable, Hashable {

    case share
    case widget
    case notification
    case other(pointIdentifier: String?)

    /// Maps a declared `NSExtensionPointIdentifier`, or `nil` when none was
    /// declared. Matching is exact.
    static func recognize(pointIdentifier: String?) -> ExplorerExtensionKind {
        switch pointIdentifier {
        case "com.apple.share-services":
            return .share
        case "com.apple.widgetkit-extension", "com.apple.widget-extension":
            return .widget
        case "com.apple.usernotifications.content-extension", "com.apple.usernotifications.service":
            return .notification
        default:
            return .other(pointIdentifier: pointIdentifier)
        }
    }

    /// A short label for the extension page.
    var displayName: String {
        switch self {
        case .share: return "Share Extension"
        case .widget: return "Widget"
        case .notification: return "Notification Extension"
        case .other: return "Other Extension"
        }
    }

    /// The declared point identifier, when the page has one to show.
    var pointIdentifier: String? {
        if case .other(let identifier) = self { return identifier }
        switch self {
        case .share: return "com.apple.share-services"
        case .widget: return "com.apple.widgetkit-extension"
        case .notification: return "com.apple.usernotifications.content-extension"
        case .other: return nil
        }
    }
}

/// Package-relative locations the explorer shows.
///
/// These are display names — `Payload/Example.app/Info.plist` — not
/// filesystem paths and not archive handles. Copying one copies this text.
enum ExplorerLocation {

    /// The location of `entry` as the user sees it, starting at `Payload`.
    static func displayPath(bundleName: String, entry: BundlePath) -> String {
        let payload = IPALayout.payloadDirectoryName
        if entry.isRoot {
            return "\(payload)/\(bundleName)"
        }
        return "\(payload)/\(bundleName)/\(entry.rawValue)"
    }

    /// The payload directory's own display name.
    static var payloadPath: String { IPALayout.payloadDirectoryName }
}
