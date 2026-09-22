/// One application bundle discovered inside an imported package.
///
/// An application bundle is a `.app` directory at a known archive location,
/// optionally carrying the identity it declares and the resolved location of
/// its executable. Identity and executable are optional because discovery
/// may find the directory without being able to read or trust what it
/// declares: a bundle without identity was located but not identified, and a
/// bundle without an executable path has no resolved executable. Those gaps
/// are reported through validation findings; they are never filled by
/// guessing.
///
/// The bundle path may sit anywhere in the archive: conventional placement
/// under `Payload/` is checked by validation rules, not enforced here, so
/// that unconventional structures stay representable for diagnosis instead
/// of the model refusing to hold them.
struct ApplicationBundle: Equatable, Hashable {

    /// The bundle directory's location within the archive.
    let bundlePath: ArchivePath

    /// The identity the bundle declares, or `nil` when its metadata is
    /// missing, unreadable, or failed validation.
    let identity: ApplicationIdentity?

    /// The resolved location of the declared executable, or `nil` when no
    /// executable has been resolved — because metadata is missing, the
    /// declaration is absent, or the file was not found.
    let executablePath: ArchivePath?

    /// Records a discovered bundle, throwing a typed domain error when the
    /// recorded locations contradict each other:
    ///
    /// - the bundle path must name a `.app` directory, matched
    ///   case-insensitively with a non-empty base name;
    /// - a recorded executable must sit strictly inside the bundle directory.
    init(
        bundlePath: ArchivePath,
        identity: ApplicationIdentity? = nil,
        executablePath: ArchivePath? = nil
    ) throws {
        let directoryName = bundlePath.lastComponent
        let namesApplicationDirectory = directoryName.count > ".app".count
            && directoryName.lowercased().hasSuffix(".app")
        guard namesApplicationDirectory else {
            throw ZynSignError.invalidArtifact(
                diagnosticDetail: "Candidate bundle path '\(bundlePath)' does not name a .app directory."
            )
        }
        if let executablePath = executablePath {
            guard executablePath.isWithin(bundlePath) else {
                throw ZynSignError.inconsistentArtifactMetadata(
                    diagnosticDetail: "Executable path '\(executablePath)' is not inside bundle path '\(bundlePath)'."
                )
            }
        }
        self.bundlePath = bundlePath
        self.identity = identity
        self.executablePath = executablePath
    }

    /// The bundle directory's own name, for example `Example.app`.
    var bundleName: String {
        bundlePath.lastComponent
    }

    /// Whether readable identity was recorded for this bundle.
    var isIdentified: Bool {
        identity != nil
    }
}
