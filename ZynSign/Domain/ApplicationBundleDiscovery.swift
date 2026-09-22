/// Where an application package's bundles were found, and what that means.
///
/// Discovery is a deterministic rule over a container's entry table. It never
/// chooses between candidates: an archive that admits more than one primary
/// application bundle is reported as ambiguous, and the caller decides what to
/// do with that report. Guessing which of two applications the user meant is
/// exactly the silent resolution the domain refuses to perform.
struct ApplicationBundleDiscovery: Equatable, Hashable {

    /// Whether the archive carries the expected top-level payload directory.
    let payloadPresent: Bool

    /// Application bundle directories found directly inside the payload
    /// directory, sorted by path. Zero, one, or more.
    let bundleCandidates: [ArchivePath]

    /// Application bundle directories found anywhere other than directly
    /// inside the payload directory, sorted by path. These are observations,
    /// not candidates: nested bundles inside an application are ordinary, and
    /// a bundle at some other archive location is unusual but worth naming in
    /// a diagnostic rather than discarding.
    let misplacedBundleDirectories: [ArchivePath]

    /// Entries directly inside the payload directory that carry an application
    /// bundle name but are not directories, sorted by path.
    let nonDirectoryApplicationNames: [ArchivePath]

    /// What the discovery establishes about the primary application bundle.
    var outcome: ApplicationBundleDiscoveryOutcome {
        if !payloadPresent {
            return .missingPayloadDirectory
        }
        switch bundleCandidates.count {
        case 0:
            return .none
        case 1:
            return .exactlyOne(bundleCandidates[0])
        default:
            return .ambiguous(bundleCandidates)
        }
    }

    /// Discovers application bundles in a container's entry table.
    ///
    /// A bundle directory counts as present when the container records it as a
    /// directory entry, or when the container records content beneath it and
    /// omits the directory entry itself — containers differ on whether they
    /// carry directory entries, and refusing an otherwise well-formed package
    /// over that difference would be a defect in ZynSign, not in the package.
    ///
    /// Entries whose recorded name failed ZynSign's safety rules are not
    /// considered here; they are reported by structural validation.
    static func discover(in entryTable: [ArchiveEntry]) -> ApplicationBundleDiscovery {
        let payloadRoot = IPALayout.payloadDirectory
        var payloadPresent = false
        var explicitDirectories = Set<ArchivePath>()
        var impliedDirectories = Set<ArchivePath>()
        var nonDirectoryApplicationNames = Set<ArchivePath>()

        for entry in entryTable {
            guard let path = entry.path else { continue }

            if let payloadRoot = payloadRoot, IPALayout.isPayloadRoot(path) || path.isWithin(payloadRoot) {
                payloadPresent = true
            }
            if entry.kind == .directory {
                explicitDirectories.insert(path)
            }
            var ancestor = path.parent
            while let current = ancestor {
                impliedDirectories.insert(current)
                ancestor = current.parent
            }
            if IPALayout.isDirectChildOfPayload(path),
               IPALayout.namesApplicationBundle(path.lastComponent),
               entry.kind != .directory {
                nonDirectoryApplicationNames.insert(path)
            }
        }

        var bundleCandidates: [ArchivePath] = []
        var misplacedBundleDirectories: [ArchivePath] = []

        for path in explicitDirectories.union(impliedDirectories) {
            guard IPALayout.namesApplicationBundle(path.lastComponent) else { continue }
            if IPALayout.isDirectChildOfPayload(path) {
                bundleCandidates.append(path)
            } else {
                misplacedBundleDirectories.append(path)
            }
        }

        return ApplicationBundleDiscovery(
            payloadPresent: payloadPresent,
            bundleCandidates: bundleCandidates.sortedByPath(),
            misplacedBundleDirectories: misplacedBundleDirectories.sortedByPath(),
            nonDirectoryApplicationNames: nonDirectoryApplicationNames.sortedByPath()
        )
    }
}

/// What discovery established about the primary application bundle.
enum ApplicationBundleDiscoveryOutcome: Equatable, Hashable {

    /// The archive carries no top-level payload directory, so the expected
    /// package layout is absent.
    case missingPayloadDirectory

    /// The payload directory is present but holds no application bundle.
    case none

    /// Exactly one application bundle was found in the expected location.
    case exactlyOne(ArchivePath)

    /// More than one application bundle was found in the expected location.
    /// ZynSign supports a single primary application bundle per package, and
    /// the limitation is reported rather than resolved by choosing one.
    case ambiguous([ArchivePath])
}

private extension Array where Element == ArchivePath {

    /// Sorts paths by their canonical string form, so discovery is
    /// deterministic whatever order the container recorded its entries in.
    func sortedByPath() -> [ArchivePath] {
        sorted { $0.rawValue < $1.rawValue }
    }
}
