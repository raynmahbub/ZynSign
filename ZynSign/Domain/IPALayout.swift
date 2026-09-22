/// The layout ZynSign expects of an application package, and the names it
/// recognizes within it.
///
/// These are the fixed, ZynSign-defined parts of package structure: the
/// top-level payload directory, the application bundle suffix, and the bundle
/// information file name. Nothing here names a particular application — bundle
/// names are discovered from the archive, never assumed.
///
/// Recognizing this layout says nothing about whether a package is genuine,
/// signed, or installable.
enum IPALayout {

    /// The top-level directory an application package is expected to carry.
    static let payloadDirectoryName = "Payload"

    /// The suffix that marks a directory as an application bundle. Matched
    /// case-insensitively, with a non-empty base name required.
    static let applicationBundleSuffix = ".app"

    /// The bundle information file every application bundle must carry.
    static let bundleInformationFileName = "Info.plist"

    /// The payload directory as a validated archive path. Optional because
    /// `ArchivePath` construction is the safety gate for every path in the
    /// domain, and no caller should be able to assume the gate was skipped.
    static var payloadDirectory: ArchivePath? {
        ArchivePath(rawValue: payloadDirectoryName)
    }

    /// Whether a path is the payload directory itself.
    static func isPayloadRoot(_ path: ArchivePath) -> Bool {
        path.rawValue == payloadDirectoryName
    }

    /// Whether a path is a direct child of the payload directory — the only
    /// place a primary application bundle is expected.
    static func isDirectChildOfPayload(_ path: ArchivePath) -> Bool {
        let components = path.components
        return components.count == 2 && components[0] == payloadDirectoryName
    }

    /// Whether a single path component names an application bundle: it ends
    /// with the application suffix, matched case-insensitively, and carries a
    /// base name. `.app` on its own is not a bundle name.
    static func namesApplicationBundle(_ component: String) -> Bool {
        component.count > applicationBundleSuffix.count
            && component.lowercased().hasSuffix(applicationBundleSuffix)
    }

    /// The location of a bundle's information file, given the bundle
    /// directory.
    static func bundleInformationPath(within bundlePath: ArchivePath) -> ArchivePath? {
        bundlePath.appending(component: bundleInformationFileName)
    }
}
