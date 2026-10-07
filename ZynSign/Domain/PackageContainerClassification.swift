import Foundation

/// A package found inside a ZIP archive, offered to the user for import.
///
/// A candidate is only a name and the sizes the archive records for it. It
/// is untrusted in every respect: its bytes are extracted into a fresh,
/// isolated working copy under a name ZynSign chooses — never under the
/// name the archive gives — and then examined exactly like any package the
/// user picked directly.
struct NestedPackageCandidate: Equatable, Hashable, Sendable, Identifiable {

    /// The candidate's path inside the archive.
    let path: ArchivePath

    /// The size the archive records for the candidate once extracted.
    let byteCount: Int

    /// The size the candidate occupies inside the archive.
    let compressedByteCount: Int

    var id: String { path.rawValue }

    /// The candidate's own file name, for display.
    var fileName: String { path.lastComponent }

    /// The folder the candidate sits in inside the archive, if any, for
    /// display.
    var folder: String? { path.parent?.rawValue }
}

/// What a staged container turned out to be, decided from its entry table
/// alone — before any entry is extracted.
///
/// The classification is how the Import Hub treats `.ipa` and `.zip` files
/// the same way: whatever the file is called, its *content* decides whether
/// it is an application package, an archive of packages, or something
/// ZynSign must refuse with an explanation.
enum PackageContainerClassification: Equatable, Sendable {

    /// The container has the application package layout (a top-level
    /// `Payload` folder). The package inspections decide whether it is a
    /// *valid* one.
    case applicationPackage

    /// The container is an archive holding one or more `.ipa` / `.tipa`
    /// packages, in the order they should be offered.
    case packageCollection([NestedPackageCandidate])

    /// The container holds neither an application package nor any package
    /// file.
    case noPackages

    /// The container holds something recognisable that ZynSign does not
    /// import.
    case unsupportedLayout(UnsupportedLayout)

    /// The container is refused outright: at least one entry could not be
    /// handled safely.
    case unsafe(UnsafeReason)

    /// Recognisable layouts ZynSign does not import, each with its own
    /// explanation.
    enum UnsupportedLayout: Equatable, Sendable {
        /// An Xcode archive (`.xcarchive`), which must be exported as an
        /// `.ipa` first.
        case xcodeArchive
        /// A bare `.app` bundle outside a `Payload` folder.
        case bareApplicationBundle
        /// ZIP archives nested inside the archive, which ZynSign does not
        /// open recursively.
        case nestedArchives
        /// A bundle of certificate material — `.p12` / `.pfx` identities
        /// and `.mobileprovision` profiles — the way certificates are
        /// commonly distributed. Certificates & Profiles imports those
        /// files directly, so the archive is explained rather than
        /// reported as simply holding nothing importable.
        case certificateMaterial
    }

    /// Why a container was refused outright.
    enum UnsafeReason: Equatable, Sendable {
        /// An entry name that could escape the extraction location or is
        /// otherwise unusable (absolute, `..`, backslashes, NUL, …).
        case unsafeEntryName(String)
        /// Two entries claim the same location.
        case duplicateEntries(String)
        /// A package-named entry that is a link or special file rather
        /// than a regular file.
        case linkedPackage(String)
    }

    /// Path extensions that name a package inside an archive.
    static let packagePathExtensions = ["ipa", "tipa"]

    /// Classifies a container from its entry table.
    ///
    /// The checks run strictest first. Any unsafely named entry refuses
    /// the whole container, because an archive that tries to escape its
    /// extraction location is not trusted for any of its other entries
    /// either; so does any pair of entries that claim the same location.
    static func classify(_ entries: [ArchiveEntry]) -> PackageContainerClassification {
        // 1. Unsafe names anywhere refuse everything.
        if let unsafe = entries.first(where: { !$0.isSafelyNamed }) {
            return .unsafe(.unsafeEntryName(unsafe.diagnosticName))
        }
        let named = entries.compactMap { entry in entry.path.map { (path: $0, entry: entry) } }

        // 2. Two entries at the same location refuse everything.
        var seen: Set<String> = []
        for item in named {
            let inserted = seen.insert(item.path.rawValue).inserted
            if !inserted {
                return .unsafe(.duplicateEntries(item.path.rawValue))
            }
        }

        // 3. The application package layout — anything under a top-level
        //    `Payload` folder — wins over anything else the archive holds.
        //    Whether it is a *valid* package, with exactly one application
        //    bundle, is for the package inspections to say, in their own
        //    precise words.
        let hasPayload = named.contains { item in
            item.path.components.first == IPALayout.payloadDirectoryName
        }
        if hasPayload {
            return .applicationPackage
        }

        // 4. Package files inside an ordinary archive.
        var candidates: [NestedPackageCandidate] = []
        var candidateKeys: Set<String> = []
        for item in named where namesPackage(item.path) {
            guard item.entry.kind == .regularFile else {
                // A package-named directory is just a folder; a link or a
                // special file with a package name is refused outright.
                if item.entry.kind == .directory { continue }
                return .unsafe(.linkedPackage(item.path.rawValue))
            }
            // Names that differ only by case would collide on a
            // case-insensitive volume and are indistinguishable to the
            // person choosing between them.
            guard candidateKeys.insert(item.path.rawValue.lowercased()).inserted else {
                return .unsafe(.duplicateEntries(item.path.rawValue))
            }
            candidates.append(
                NestedPackageCandidate(
                    path: item.path,
                    byteCount: item.entry.uncompressedSize,
                    compressedByteCount: item.entry.compressedSize
                )
            )
        }
        if !candidates.isEmpty {
            let ordered = candidates.sorted {
                $0.path.rawValue.localizedStandardCompare($1.path.rawValue) == .orderedAscending
            }
            return .packageCollection(ordered)
        }

        // 5. Nothing importable: explain what was found instead.
        if named.contains(where: { $0.path.components.contains(where: isXcodeArchiveName) }) {
            return .unsupportedLayout(.xcodeArchive)
        }
        if named.contains(where: { $0.path.components.contains(where: IPALayout.namesApplicationBundle) }) {
            return .unsupportedLayout(.bareApplicationBundle)
        }
        if named.contains(where: { namesSigningMaterial($0.path) }) {
            return .unsupportedLayout(.certificateMaterial)
        }
        if named.contains(where: { !isMetadataNoise($0.path) && $0.path.lastComponent.lowercased().hasSuffix(".zip") }) {
            return .unsupportedLayout(.nestedArchives)
        }
        return .noPackages
    }

    // MARK: - Names

    /// Whether a path names a package file worth offering. Resource-fork
    /// shadows that macOS adds to archives (`__MACOSX/…`, `._Name.ipa`) and
    /// other hidden files are never candidates.
    static func namesPackage(_ path: ArchivePath) -> Bool {
        guard !isMetadataNoise(path) else { return false }
        let name = path.lastComponent
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let pathExtension = name[name.index(after: dot)...].lowercased()
        return packagePathExtensions.contains(pathExtension)
    }

    /// Whether a path names certificate material — a `.p12` / `.pfx`
    /// identity or a `.mobileprovision` profile — that Certificates &
    /// Profiles imports directly. Resource-fork shadows and hidden files
    /// are never it: `__MACOSX/._Signer.p12` is noise, not a certificate.
    static func namesSigningMaterial(_ path: ArchivePath) -> Bool {
        guard !isMetadataNoise(path) else { return false }
        let name = path.lastComponent
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let pathExtension = name[name.index(after: dot)...].lowercased()
        return SigningMaterialFileFormat.kind(forPathExtension: pathExtension) != nil
    }

    private static func isMetadataNoise(_ path: ArchivePath) -> Bool {
        if path.components.first == "__MACOSX" { return true }
        return path.lastComponent.hasPrefix(".")
    }

    private static func isXcodeArchiveName(_ component: String) -> Bool {
        component.lowercased().hasSuffix(".xcarchive") && component.count > ".xcarchive".count
    }
}
