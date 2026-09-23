import Foundation

/// The seam where nested-code discovery obtains the content-derived facts it
/// cannot read itself.
///
/// Discovery is a pure rule over a package's entry table: it decides which
/// locations the bundle structure proposes, and it asks this source what is at
/// exactly those locations. It never opens an archive, never reads a file,
/// never resolves a path against a filesystem, and never reaches above the
/// managed bundle — the locations it asks about are `ArchivePath` values that
/// were built from the bundle's own location and a `BundlePath` inside it.
///
/// The implementation belongs to the application layer, which composes the
/// existing `ArchiveReader` and the existing read-only Mach-O parser behind
/// this protocol. That keeps the reading policy — bounds, resource limits, and
/// the refusal to follow links — where the archive boundary already enforces
/// it, and keeps the rule in the domain where it can be tested exhaustively
/// without a container.
protocol NestedCodeInspectionSource {

    /// What is recorded at the root of one container bundle: its information
    /// file's declared identity, or why that declaration could not be used.
    ///
    /// `path` is the container bundle directory, relative to the package.
    /// `maximumBytes` bounds the content a conforming implementation may
    /// produce; an implementation that cannot produce the file within that
    /// bound reports `.unreadable` rather than truncating it.
    func bundleInformation(
        ofContainerAt path: ArchivePath,
        maximumBytes: Int
    ) -> NestedCodeBundleInformation

    /// What is recorded at one proposed executable location.
    ///
    /// `declaredByteCount` is the size the container's own metadata declares
    /// for the entry, when it declares one; an implementation may use it to
    /// refuse a read it already knows cannot succeed within `maximumBytes`.
    /// Nothing is read from a location discovery does not ask about.
    func binary(
        at path: ArchivePath,
        declaredByteCount: Int?,
        maximumBytes: Int
    ) -> NestedCodeBinaryInspection
}

/// What one inspection of a candidate binary established.
///
/// The two facts are kept apart because they answer different questions: the
/// observation says whether the bytes are a Mach-O image and how they are
/// arranged, and the signature observation says what signature data was
/// found. Neither is a validity, trust, or platform-acceptance claim.
struct NestedCodeBinaryInspection: Equatable {

    /// The structural observation.
    let observation: NestedCodeBinaryObservation

    /// The existing-signature observation, `.notEvaluated` when no image was
    /// parsed.
    let existingSignature: NestedCodeExistingSignature

    init(
        observation: NestedCodeBinaryObservation,
        existingSignature: NestedCodeExistingSignature = .notEvaluated
    ) {
        self.observation = observation
        self.existingSignature = existingSignature
    }

    /// An inspection that established nothing, used when no content was
    /// requested or obtained.
    static let unevaluated = NestedCodeBinaryInspection(
        observation: .notRequested,
        existingSignature: .notEvaluated
    )
}

/// What the caller has already established about the managed application.
///
/// The application bundle's own location and declared identity come from the
/// library record the import stage produced; discovery does not re-read the
/// application's information file, because the metadata stage already read it
/// and recorded what it declared. A declaration is all it is: a bundle
/// identifier here is not authorization, and discovery reaches no conclusion
/// from it.
struct NestedCodeDiscoveryRequest: Equatable, Hashable {

    /// The application bundle's location inside the package.
    let bundlePath: ArchivePath

    /// The identity the application record holds.
    let applicationIdentity: NestedCodeBundleIdentity

    init(bundlePath: ArchivePath, applicationIdentity: NestedCodeBundleIdentity) {
        self.bundlePath = bundlePath
        self.applicationIdentity = applicationIdentity
    }
}

/// Discovery of the executable content inside one managed application bundle,
/// and the deterministic signing order for it.
///
/// ## What it does
///
/// It walks the bundle structure once, from the entry table the archive
/// boundary already produced: the application's own executable, the code
/// bundles and standalone Mach-O files inside each supported `Frameworks` and
/// `PlugIns` directory, and — by name only, for a bounded depth — code-shaped
/// objects outside those locations, so that unexpected placement is reported
/// rather than missed. For every location the structure proposes it obtains
/// one bounded observation, then builds a dependency graph, validates it, and
/// derives the order.
///
/// ## What it refuses
///
/// It refuses to guess. Ambiguity — several plausible executables, a bundle
/// whose contents differ from its declaration — is reported, never resolved
/// by choosing. It refuses to follow a symbolic link or to plan around an
/// entry form it cannot establish inside the bundle. It refuses to order a
/// graph that contradicts itself: a cycle, a self-dependency, a duplicate
/// item, a duplicate executable location, a missing dependency, a conflict
/// between declared bundle identifiers, or a location that cannot lie inside
/// the managed bundle each end discovery with a structured failure rather
/// than with an order ZynSign cannot justify.
///
/// ## What it does not do
///
/// It does not sign, modify, extract, or repackage anything. It reads content
/// only where a code location proposes a candidate, through the existing
/// archive boundary, within the configured bounds, and it never reads the
/// whole bundle: no directory tree is enumerated byte by byte, and no file is
/// classified from its name, permissions, or extension. Whether a file is
/// code is decided by Mach-O structure at a code location — and a file that is
/// not Mach-O is not nested code, whatever it is called.
///
/// It also establishes nothing about cryptographic validity, certificate
/// trust, provisioning authorization, or installability. An existing signature
/// is reported in the same terms the read-only parser uses, and "a signature
/// is present" is never treated as "the signature is valid".
enum NestedCodeDiscovery {

    /// The greatest number of diagnostics recorded for any one code.
    ///
    /// This bounds the size of a plan's report rather than the strictness of
    /// discovery: one violated structural rule is already reported, so
    /// itemising every further instance would only enlarge the diagnostic. A
    /// hostile bundle cannot inflate a report past this bound.
    static let maximumDiagnosticsPerCode = 8

    /// Discovers the nested code of the application bundle `request` names,
    /// inside the container `entryTable` was read from.
    ///
    /// The traversal is deterministic: directories are visited in a fixed
    /// order, their children are compared as strings and visited in that
    /// order, and the plan's items, dependencies, steps, unsupported items,
    /// and diagnostics are all produced in an order that depends only on the
    /// recorded structure. Two runs over the same table produce equal plans.
    ///
    /// The source is consulted only for locations the structure proposes, and
    /// only within the resource policy; the traversal stops at the first
    /// rejection, so a rejected bundle produces no plan and no further reads.
    static func discover(
        entryTable: [ArchiveEntry],
        request: NestedCodeDiscoveryRequest,
        limits: NestedCodeDiscoveryLimits = .default,
        source: any NestedCodeInspectionSource
    ) -> NestedCodeDiscoveryOutcome {
        var traversal = NestedCodeTraversal(
            entryTable: entryTable,
            request: request,
            limits: limits,
            source: source
        )

        if let failure = traversal.run() {
            return .rejected(failure)
        }

        let graph = NestedCodeDependencyGraph.structural(
            items: traversal.items,
            rootItemID: traversal.rootItemID
        )
        if case .rejected(let error) = graph.validated() {
            return .rejected(error)
        }

        let ordered = graph.orderedItemIDs()
        guard ordered.count == graph.items.count else {
            return .rejected(NestedCodeDiscoveryError(
                .dependencyCycle,
                detail: "Discovery produced a dependency graph that could not be ordered."
            ))
        }
        guard let root = graph.items.first(where: { $0.id == traversal.rootItemID }) else {
            return .rejected(NestedCodeDiscoveryError(
                .invalidApplicationBundle,
                detail: "Discovery produced a graph without the application bundle it was asked about."
            ))
        }

        let steps = ordered.enumerated().map { index, itemID in
            NestedCodeSigningStep(order: index + 1, itemID: itemID)
        }
        return .plan(NestedCodeSigningPlan(
            root: root,
            nestedItems: graph.items.filter { $0.id != root.id },
            dependencies: graph.dependencies,
            steps: steps,
            unsupportedItems: traversal.unsupportedItems,
            diagnostics: traversal.diagnostics
        ))
    }
}

// MARK: - Structural vocabulary

/// The names and suffixes nested-code discovery recognizes, beyond the names
/// `IPALayout` already declares for the bundle explorer.
///
/// These are structure names, not content claims. A name places an object in
/// the bundle's structure; whether the object is code is established by
/// Mach-O inspection at a code location, and a name outside a code location
/// is only ever used to report that something code-shaped is somewhere
/// ZynSign does not traverse.
enum NestedCodeLocation {

    /// The suffix of a framework bundle directory.
    static let frameworkSuffix = ".framework"

    /// The suffix of an application-extension bundle directory.
    static let extensionSuffix = ".appex"

    /// The suffix of a loadable bundle directory. A resource bundle shares
    /// this suffix, so the role of a `.bundle` directory is ambiguous until
    /// its content is read — which discovery deliberately does not do.
    static let loadableBundleSuffix = ".bundle"

    /// The suffix of a service bundle directory. The form is established on
    /// another Apple platform and is not established on iOS/iPadOS, so
    /// discovery reports it rather than traversing it.
    static let serviceSuffix = ".xpc"

    /// Suffixes of files that are code-shaped by name. Used only to describe
    /// objects outside the traversed structure; a name never makes a file an
    /// item and never causes its content to be read.
    static let codeFileSuffixes = [".dylib", ".so"]

    /// The suffixes of bundle directories that are code-bearing by structure.
    /// A directory with one of these suffixes is code wherever it is
    /// recorded, which is why an unexpected location is reported rather than
    /// ignored.
    static let codeBundleSuffixes = [frameworkSuffix, extensionSuffix, serviceSuffix]

    /// Whether `name` ends with `suffix` and has a non-empty base name, so
    /// that a directory called exactly `.framework` is not mistaken for a
    /// framework bundle.
    static func hasSuffix(_ name: String, _ suffix: String) -> Bool {
        name.count > suffix.count && name.hasSuffix(suffix)
    }

    /// The base name of a bundle directory: its own name without the bundle
    /// suffix, which is the name the platform's convention gives its
    /// executable. Empty when the name carries no recognized suffix.
    static func baseName(ofBundleNamed name: String) -> String {
        for suffix in [IPALayout.applicationBundleSuffix] + codeBundleSuffixes
        where hasSuffix(name, suffix) {
            return String(name.dropLast(suffix.count))
        }
        return ""
    }

    /// Whether a file name is code-shaped for diagnostic purposes only.
    static func looksLikeCodeFile(_ name: String) -> Bool {
        codeFileSuffixes.contains { hasSuffix(name, $0) }
    }
}

// MARK: - Observations from parsed content

extension NestedCodeMachOSummary {

    /// Summarizes a parsed image, keeping the container form and the header
    /// facts of each slice and dropping everything else the parser produced.
    init(image: MachOImage) {
        var isUniversal = false
        if case .universal = image.container {
            isUniversal = true
        }
        self.init(slices: image.slices, isUniversal: isUniversal)
    }

    /// Summarizes inspected slices directly, for callers that hold the slices
    /// a read-only inspection produced rather than the image it parsed.
    init(slices: [MachOSlice], isUniversal: Bool) {
        self.container = isUniversal ? .universal : .thin
        self.slices = slices.map { slice in
            Slice(
                cpu: slice.header.cpu,
                cpuSubtype: slice.header.cpuSubtype,
                fileType: slice.header.fileType,
                wordSize: slice.header.wordSize,
                byteOrder: slice.header.byteOrder
            )
        }
    }
}

extension NestedCodeExistingSignature {

    /// Records the signature state of a parsed image, derived from which of
    /// its slices carry an embedded signature.
    ///
    /// A slice whose signature is present is a slice whose signature data
    /// parsed; this initializer runs only for images that parsed completely,
    /// because a signature failure is reported as a malformed state instead.
    init(image: MachOImage) {
        let states: [MachOExistingCodeSignatureState] = image.slices.map { slice in
            if let signature = slice.embeddedSignature {
                return .valid(signature)
            }
            return .absent
        }
        self.init(states: states)
    }

    /// Records the signature states the existing read-only inspector reported
    /// for the slices of one image.
    init(states: [MachOExistingCodeSignatureState]) {
        let total = states.count
        let signed = states.filter { state in
            if case .valid = state {
                return true
            }
            return false
        }.count
        if signed == 0 {
            self = .absent
        } else if signed == total {
            self = .structurallyParsed(signedSliceCount: signed)
        } else {
            self = .incompleteSlices(totalSliceCount: total, signedSliceCount: signed)
        }
    }

    /// Records a signature failure the read-only inspector classified.
    ///
    /// A signature whose CodeDirectory version this build does not model is
    /// reported as unsupported rather than malformed: the data is recognized,
    /// and saying otherwise would blame the bundle for a capability limit.
    static func failure(_ state: MachOExistingCodeSignatureState) -> NestedCodeExistingSignature {
        if let error = state.parsingError, error.reason == .unsupportedCodeDirectoryVersion {
            return .unsupported(state)
        }
        return .malformed(state)
    }
}

extension MachOExistingCodeSignatureState {

    /// The parser failure a malformed state carries, when it carries one.
    var parsingError: MachOParsingError? {
        switch self {
        case .absent, .valid:
            return nil
        case .malformedCommand(let error),
             .invalidRegionOffset(let error),
             .invalidRegionSize(let error),
             .malformedRegion(let error):
            return error
        }
    }
}

extension NestedCodeBinaryObservation {

    /// Classifies one parser failure, using the parser's own reason and
    /// boundary rather than a summary of them.
    ///
    /// An unrecognized magic is not a Mach-O image at all. A CodeDirectory
    /// version this build does not model, and a policy bound the parser
    /// enforces, are recognized forms outside this build's capability.
    /// Everything else — a truncated header, an inconsistent load-command
    /// table, a malformed signature blob — is a Mach-O image that cannot be
    /// used as one.
    static func classifying(_ error: MachOParsingError) -> NestedCodeBinaryObservation {
        if error.reason == .unsupportedFormat, error.boundary == .magic {
            return .notMachO
        }
        switch error.reason {
        case .unsupportedCodeDirectoryVersion, .resourceLimitExceeded:
            return .unsupported(error)
        default:
            return .malformed(error)
        }
    }

    /// The reason this observation does not establish code, or `nil` when it
    /// does.
    var notEstablishedReason: NestedCodeNotEstablished? {
        switch self {
        case .machO:
            return nil
        case .notRequested:
            return .binaryNotInspected
        case .notMachO:
            return .binaryNotMachO
        case .malformed(let error):
            return .binaryMalformed(error)
        case .unsupported(let error):
            return .binaryUnsupported(error)
        case .beyondInspectionBound(let declaredByteCount):
            return .binaryBeyondInspectionBound(declaredByteCount: declaredByteCount)
        case .unreadable:
            return .binaryUnreadable
        }
    }
}

// MARK: - The traversal

/// One container whose nested code is being examined.
private struct NestedCodeContainer {

    let kind: NestedCodeKind

    /// The container's own directory, relative to the managed bundle.
    let bundlePath: BundlePath

    /// How many container levels below the application this container sits.
    /// The application itself is zero.
    let depth: Int

    let parentID: NestedCodeItemID?

    let itemID: NestedCodeItemID

    /// The identity the caller established for this container, when it
    /// established one. Only the application's is taken from the library
    /// record; nested containers declare their own, and discovery reads it.
    let declaredIdentity: NestedCodeBundleIdentity?

    /// Whether the container's information file was already read by the
    /// caller, so that discovery must not read it again.
    let informationWasReadByCaller: Bool
}

/// How a container's executable location resolved.
private enum NestedCodeExecutableResolution {

    case established(path: BundlePath, provenance: NestedCodeExecutableProvenance)

    /// No executable could be established.
    case missing

    /// Several plausible executables exist and nothing chooses between them.
    /// The names are recorded for the diagnostic, bounded by the policy.
    case ambiguous([String])

    /// A symbolic link or unmodelled entry form sits at a candidate location.
    /// The target is never read and never followed.
    case unsafe(path: BundlePath, form: String)
}

/// The recorded structure of one bundle, derived once from the entry table.
private struct NestedCodeEntryIndex {

    private let kinds: [BundlePath: ArchiveEntryKind]
    private let declaredByteCounts: [BundlePath: Int]
    private let directories: Set<BundlePath>
    private let children: [BundlePath: [String]]

    /// How many entries the container recorded with names that failed
    /// ZynSign's safety rules, so that they could not be attributed to any
    /// bundle location.
    let unattributableEntryCount: Int

    /// How many locations the container recorded more than once with
    /// differing kinds. The package inspection stage refuses such a table
    /// before an artifact is admitted, so this can only be non-zero for a
    /// table discovery was handed directly; it is counted rather than
    /// assumed away so that a contradiction is reported instead of silently
    /// resolved.
    let conflictingKindEntryCount: Int

    init(entryTable: [ArchiveEntry], bundlePath: ArchivePath) {
        var kinds: [BundlePath: ArchiveEntryKind] = [:]
        var declaredByteCounts: [BundlePath: Int] = [:]
        var directories: Set<BundlePath> = [.root]
        var childrenByDirectory: [BundlePath: [String]] = [:]
        var unattributable = 0
        var conflictingKinds = 0

        for entry in entryTable {
            guard let archiveEntryPath = entry.path else {
                unattributable += 1
                continue
            }
            guard let path = BundlePath(archiveEntryPath, relativeTo: bundlePath),
                  let name = path.name else {
                continue
            }
            // The package validator refuses duplicate and conflicting paths
            // before an artifact is admitted, so the first recorded entry at a
            // location describes it; the rule is kept deterministic anyway,
            // and a differing repeat is counted so that it can be reported.
            if let recordedKind = kinds[path] {
                if recordedKind != entry.kind {
                    conflictingKinds += 1
                }
            } else {
                kinds[path] = entry.kind
                declaredByteCounts[path] = entry.uncompressedSize
            }
            if entry.kind == .directory {
                directories.insert(path)
            }
            if let parent = path.parent {
                childrenByDirectory[parent, default: []].append(name)
            }
            var ancestor = path.parent
            while let current = ancestor, !current.isRoot {
                directories.insert(current)
                ancestor = current.parent
            }
        }

        self.kinds = kinds
        self.declaredByteCounts = declaredByteCounts
        self.directories = directories
        self.unattributableEntryCount = unattributable
        self.conflictingKindEntryCount = conflictingKinds
        self.children = childrenByDirectory.mapValues { names in
            Array(Set(names)).sorted()
        }
    }

    /// The recorded kind at a location, treating a directory the container
    /// did not record but whose content it did as a directory.
    func kind(of path: BundlePath) -> ArchiveEntryKind? {
        if let kind = kinds[path] {
            return kind
        }
        return directories.contains(path) ? .directory : nil
    }

    func isDirectory(_ path: BundlePath) -> Bool {
        kind(of: path) == .directory
    }

    func isRegularFile(_ path: BundlePath) -> Bool {
        kind(of: path) == .regularFile
    }

    /// The byte count the container declares for a regular file, or `nil` for
    /// any other location. A declaration by untrusted metadata.
    func declaredByteCount(of path: BundlePath) -> Int? {
        kind(of: path) == .regularFile ? declaredByteCounts[path] : nil
    }

    /// The names recorded directly inside a directory, deduplicated and
    /// sorted, so that one traversal always visits them in the same order.
    func childNames(of path: BundlePath) -> [String] {
        children[path] ?? []
    }
}

private struct NestedCodeTraversal {

    private let index: NestedCodeEntryIndex
    private let bundlePath: ArchivePath
    private let limits: NestedCodeDiscoveryLimits
    private let source: any NestedCodeInspectionSource

    private(set) var items: [NestedCodeItem] = []
    private(set) var unsupportedItems: [NestedCodeUnsupportedItem] = []
    private(set) var diagnostics: [NestedCodeDiagnostic] = []
    private(set) var rootItemID: NestedCodeItemID

    private var diagnosticCounts: [NestedCodeDiagnosticCode: Int] = [:]
    private var claimedPaths: Set<BundlePath> = []
    private var binaryReads = 0
    private var informationReads = 0
    private var visitedDirectories = 0

    private let applicationIdentity: NestedCodeBundleIdentity

    init(
        entryTable: [ArchiveEntry],
        request: NestedCodeDiscoveryRequest,
        limits: NestedCodeDiscoveryLimits,
        source: any NestedCodeInspectionSource
    ) {
        self.index = NestedCodeEntryIndex(entryTable: entryTable, bundlePath: request.bundlePath)
        self.bundlePath = request.bundlePath
        self.limits = limits
        self.source = source
        self.applicationIdentity = request.applicationIdentity
        self.rootItemID = NestedCodeItemID(kind: .application, location: .root)
    }

    /// Runs the whole traversal, returning the first rejection or `nil`.
    mutating func run() -> NestedCodeDiscoveryError? {
        let application = NestedCodeContainer(
            kind: .application,
            bundlePath: .root,
            depth: 0,
            parentID: nil,
            itemID: rootItemID,
            declaredIdentity: applicationIdentity,
            informationWasReadByCaller: true
        )

        if index.unattributableEntryCount > 0 {
            let count = index.unattributableEntryCount
            if let failure = addDiagnostic(
                severity: .warning,
                code: .unattributableEntryName,
                detail: "The package records \(count) entries whose names fail ZynSign's path safety rules, so they could not be attributed to any bundle location."
            ) {
                return failure
            }
        }

        if index.conflictingKindEntryCount > 0 {
            let count = index.conflictingKindEntryCount
            if let failure = addDiagnostic(
                severity: .warning,
                code: .conflictingEntryKind,
                detail: "The package records \(count) locations more than once with differing kinds; discovery keeps the first recorded kind for each and does not choose between them."
            ) {
                return failure
            }
        }

        return visit(application)
    }

    // MARK: - Containers

    private mutating func visit(_ container: NestedCodeContainer) -> NestedCodeDiscoveryError? {
        // 1. The container's own information file.
        var information: NestedCodeBundleInformation = .notPresent
        if container.informationWasReadByCaller {
            information = .read(container.declaredIdentity ?? NestedCodeBundleIdentity())
        } else if index.isRegularFile(bundleInformationPath(of: container.bundlePath)) {
            let relative = bundleInformationPath(of: container.bundlePath)
            guard let informationPath = archivePath(for: relative) else {
                return invalidPathError(at: relative)
            }
            guard informationReads < limits.maximumBundleInformationReads else {
                return resourceLimitError(
                    at: relative,
                    detail: "Reading one more nested information file would exceed the configured bound of \(limits.maximumBundleInformationReads) reads."
                )
            }
            informationReads += 1
            information = source.bundleInformation(
                ofContainerAt: informationPath,
                maximumBytes: limits.maximumBundleInformationBytes
            )
            switch information {
            case .unreadable:
                if let failure = admitUnsupportedItem(path: relative, reason: .unreadableBundleInformation) {
                    return failure
                }
                if let failure = addDiagnostic(
                    severity: .warning,
                    code: .bundleInformationUnavailable,
                    detail: "The information file recorded at '\(relative.rawValue)' could not be read within the configured bound.",
                    path: relative
                ) {
                    return failure
                }
            case .malformed:
                if let failure = admitUnsupportedItem(path: relative, reason: .malformedBundleInformation) {
                    return failure
                }
                if let failure = addDiagnostic(
                    severity: .warning,
                    code: .bundleInformationUnavailable,
                    detail: "The information file recorded at '\(relative.rawValue)' was read but its declared metadata did not satisfy ZynSign's metadata rules.",
                    path: relative
                ) {
                    return failure
                }
            case .notPresent, .read:
                break
            }
        }

        // 2. The container's own executable.
        let declaredName = container.declaredIdentity?.executableName ?? information.identity?.executableName
        let resolution = resolveExecutable(of: container, declaredName: declaredName)
        var executablePath: BundlePath?
        var provenance: NestedCodeExecutableProvenance?
        var notEstablished: NestedCodeNotEstablished?

        switch resolution {
        case .unsafe(let path, let form):
            return NestedCodeDiscoveryError(
                .pathSafetyViolation,
                at: path,
                detail: "The entry recorded at '\(path.rawValue)' is \(form); ZynSign never follows a link or plans around an entry form it cannot establish inside the managed bundle."
            )
        case .ambiguous(let names):
            notEstablished = .ambiguousExecutable(names)
        case .missing:
            notEstablished = .executableMissing
        case .established(let path, let executableProvenance):
            executablePath = path
            provenance = executableProvenance
            claimedPaths.insert(path)
            if executableProvenance == .bundleNameConvention {
                if let failure = addDiagnostic(
                    severity: .note,
                    code: .executableNameInferred,
                    detail: "No declared executable name was available for '\(container.bundlePath.rawValue)', so the file named after the container was used.",
                    path: path
                ) {
                    return failure
                }
            }
        }

        // 3. Mach-O inspection of the established executable, within bounds.
        var binary: NestedCodeBinaryObservation = .notRequested
        var signature: NestedCodeExistingSignature = .notEvaluated
        if let executablePath {
            let declaredByteCount = index.declaredByteCount(of: executablePath)
            if let declaredByteCount, declaredByteCount > limits.maximumBinaryBytes {
                binary = .beyondInspectionBound(declaredByteCount: declaredByteCount)
                notEstablished = .binaryBeyondInspectionBound(declaredByteCount: declaredByteCount)
            } else {
                guard let path = archivePath(for: executablePath) else {
                    return invalidPathError(at: executablePath)
                }
                guard binaryReads < limits.maximumBinaryReads else {
                    return resourceLimitError(
                        at: executablePath,
                        detail: "Inspecting one more binary would exceed the configured bound of \(limits.maximumBinaryReads) reads."
                    )
                }
                binaryReads += 1
                let inspection = source.binary(
                    at: path,
                    declaredByteCount: declaredByteCount,
                    maximumBytes: limits.maximumBinaryBytes
                )
                binary = inspection.observation
                signature = inspection.existingSignature
                if let reason = inspection.observation.notEstablishedReason {
                    notEstablished = reason
                }
            }
        }

        // 4. Record the item, or refuse the application's own structure.
        guard items.count < limits.maximumItems else {
            return resourceLimitError(
                at: container.bundlePath,
                detail: "Discovery located more code items than the configured bound of \(limits.maximumItems)."
            )
        }
        // An item is established only when discovery both located an
        // executable and observed Mach-O structure there. The two conditions
        // are checked separately so that no path can mark an item as code
        // without an observation that establishes code.
        let status: NestedCodeItemStatus
        if let reason = notEstablished {
            status = .notEstablished(reason)
        } else if binary.establishesMachO {
            status = .established
        } else {
            status = .notEstablished(.binaryNotInspected)
        }
        let item = NestedCodeItem(
            id: container.itemID,
            kind: container.kind,
            bundlePath: container.bundlePath,
            executablePath: executablePath,
            executableProvenance: provenance,
            bundleInformation: information,
            binary: binary,
            existingSignature: signature,
            parentID: container.parentID,
            status: status
        )
        items.append(item)
        if container.kind == .application {
            claimedPaths.insert(container.bundlePath)
        }

        if case .notEstablished(let reason) = status {
            if container.kind == .application {
                return applicationFailure(reason, at: executablePath)
            }
            if let failure = describeNotEstablished(reason, of: item) {
                return failure
            }
        }

        // 5. The container's own nested code, in the code directories the
        // bundle-entry role vocabulary already recognizes.
        for directoryName in [
            IPALayout.frameworksDirectoryName,
            IPALayout.plugInsDirectoryName,
            IPALayout.extensionsDirectoryName,
        ] {
            if let failure = examineCodeDirectory(directoryName, of: container) {
                return failure
            }
        }

        // 6. Code-shaped objects outside the traversed locations, by name.
        return examineUnsupportedLocations(of: container)
    }

    /// The application's own executable must be established, because a plan
    /// without it describes nothing a later stage could sign. The failure
    /// keeps the reason the item's own status carries, so "not a Mach-O
    /// image" never becomes "malformed Mach-O" and a capability limit never
    /// becomes a defect in the bundle.
    private func applicationFailure(
        _ reason: NestedCodeNotEstablished,
        at path: BundlePath?
    ) -> NestedCodeDiscoveryError {
        switch reason {
        case .executableMissing:
            return NestedCodeDiscoveryError(
                .invalidApplicationBundle,
                at: path ?? .root,
                detail: "The application bundle records no regular file at its executable location, so the main executable could not be established."
            )
        case .ambiguousExecutable(let names):
            return NestedCodeDiscoveryError(
                .ambiguousExecutable,
                at: .root,
                detail: "The application bundle records several possible executables (\(names.joined(separator: ", "))) and nothing chooses between them."
            )
        case .binaryNotMachO:
            return NestedCodeDiscoveryError(
                .notMachO,
                at: path,
                detail: "The application's main executable is not a Mach-O image."
            )
        case .binaryMalformed(let error):
            return NestedCodeDiscoveryError(
                .malformedMachO,
                at: path,
                detail: "The application's main executable is malformed (\(error.reason), at \(error.boundary))."
            )
        case .binaryUnsupported(let error):
            return NestedCodeDiscoveryError(
                .unsupportedMachO,
                at: path,
                detail: "The application's main executable uses a form this build does not support (\(error.reason), at \(error.boundary))."
            )
        case .binaryBeyondInspectionBound(let declaredByteCount):
            return resourceLimitError(
                at: path,
                detail: "The application's main executable declares \(declaredByteCount) bytes, beyond the configured inspection bound of \(limits.maximumBinaryBytes)."
            )
        case .binaryUnreadable:
            return NestedCodeDiscoveryError(
                .invalidApplicationBundle,
                at: path,
                detail: "The application's main executable could not be read within the configured bound."
            )
        case .binaryNotInspected:
            return NestedCodeDiscoveryError(
                .invalidApplicationBundle,
                at: path,
                detail: "The application's main executable location produced no structure to establish it."
            )
        case .unsupportedStructure:
            return NestedCodeDiscoveryError(
                .unsupportedNestedCode,
                at: path,
                detail: "The application's own structure is outside what this build traverses."
            )
        }
    }

    // MARK: - Code directories

    private mutating func examineCodeDirectory(
        _ directoryName: String,
        of container: NestedCodeContainer
    ) -> NestedCodeDiscoveryError? {
        guard let directoryPath = container.bundlePath.appending(component: directoryName) else {
            return invalidPathError(at: container.bundlePath)
        }
        guard index.isDirectory(directoryPath) else { return nil }
        visitedDirectories += 1
        guard visitedDirectories <= limits.maximumVisitedDirectories else {
            return resourceLimitError(
                at: directoryPath,
                detail: "Discovery enumerated more directories than the configured bound of \(limits.maximumVisitedDirectories)."
            )
        }
        claimedPaths.insert(directoryPath)

        for name in index.childNames(of: directoryPath) {
            guard let childPath = directoryPath.appending(component: name) else {
                return invalidPathError(at: directoryPath)
            }
            let kind = index.kind(of: childPath)
            switch kind {
            case .symbolicLink, .unsupported:
                return NestedCodeDiscoveryError(
                    .pathSafetyViolation,
                    at: childPath,
                    detail: "The entry recorded at '\(childPath.rawValue)' is \(kind?.displayName ?? "an unmodelled entry"); ZynSign never follows or plans around an entry form it cannot establish in a code location."
                )
            case .directory:
                if let failure = examineCodeDirectoryChild(name: name, directoryName: directoryName, path: childPath, of: container) {
                    return failure
                }
            case .regularFile:
                if let failure = examineCodeDirectoryFile(directoryName: directoryName, name: name, path: childPath, of: container) {
                    return failure
                }
            case .none:
                continue
            }
        }
        return nil
    }

    private mutating func examineCodeDirectoryChild(
        name: String,
        directoryName: String,
        path: BundlePath,
        of container: NestedCodeContainer
    ) -> NestedCodeDiscoveryError? {
        if let nestedKind = supportedContainerKind(name: name, directoryName: directoryName) {
            guard container.depth + 1 <= limits.maximumContainerDepth else {
                return resourceLimitError(
                    at: path,
                    detail: "Container nesting below the application would exceed the configured bound of \(limits.maximumContainerDepth)."
                )
            }
            claimedPaths.insert(path)
            let nestedContainer = NestedCodeContainer(
                kind: nestedKind,
                bundlePath: path,
                depth: container.depth + 1,
                parentID: container.itemID,
                itemID: NestedCodeItemID(kind: nestedKind, location: path),
                declaredIdentity: nil,
                informationWasReadByCaller: false
            )
            return visit(nestedContainer)
        }

        if NestedCodeLocation.hasSuffix(name, IPALayout.applicationBundleSuffix) {
            return NestedCodeDiscoveryError(
                .unsupportedNestedCode,
                at: path,
                detail: "A nested application bundle is recorded at '\(path.rawValue)'. Its contents and its relationship to the enclosing application are outside the structure this build traverses."
            )
        }
        if NestedCodeLocation.codeBundleSuffixes.contains(where: { NestedCodeLocation.hasSuffix(name, $0) }) {
            return NestedCodeDiscoveryError(
                .unsupportedNestedCode,
                at: path,
                detail: "A code bundle is recorded at '\(path.rawValue)' in '\(directoryName)', which is not a supported location for that kind of bundle."
            )
        }
        if NestedCodeLocation.hasSuffix(name, NestedCodeLocation.loadableBundleSuffix) {
            // A loadable bundle and a resource bundle share this suffix and
            // only their content tells them apart, which discovery does not
            // read. The ambiguity is reported and leaves the plan incomplete.
            if let failure = admitUnsupportedItem(path: path, reason: .unsupportedStructure) {
                return failure
            }
            return addDiagnostic(
                severity: .warning,
                code: .structureNotTraversed,
                detail: "A bundle is recorded at '\(path.rawValue)'. ZynSign does not read a loadable bundle to tell it apart from a resource bundle, so it is not traversed and the plan stays incomplete.",
                path: path
            )
        }
        return nil
    }

    private mutating func examineCodeDirectoryFile(
        directoryName: String,
        name: String,
        path: BundlePath,
        of container: NestedCodeContainer
    ) -> NestedCodeDiscoveryError? {
        guard directoryName == IPALayout.frameworksDirectoryName else {
            // A plug-ins directory holds bundles. A loose file there is not
            // part of the structure, so it is reported by name and nothing
            // about its content is claimed or read.
            guard NestedCodeLocation.looksLikeCodeFile(name) else { return nil }
            if let failure = admitUnsupportedItem(path: path, reason: .unsupportedStructure) {
                return failure
            }
            return addDiagnostic(
                severity: .warning,
                code: .unsupportedCodeLocation,
                detail: "A file named like code is recorded at '\(path.rawValue)'. ZynSign does not traverse loose files in '\(directoryName)' and did not read it.",
                path: path
            )
        }

        let declaredByteCount = index.declaredByteCount(of: path)
        if let declaredByteCount, declaredByteCount > limits.maximumBinaryBytes {
            if let failure = admitUnsupportedItem(path: path, reason: .binaryBeyondInspectionBound) {
                return failure
            }
            if let failure = addDiagnostic(
                severity: .warning,
                code: .binaryNotUsable,
                detail: "The candidate at '\(path.rawValue)' declares \(declaredByteCount) bytes, beyond the configured inspection bound of \(limits.maximumBinaryBytes), so it was not read.",
                path: path
            ) {
                return failure
            }
            return nil
        }
        guard let archiveCandidate = archivePath(for: path) else {
            return invalidPathError(at: path)
        }
        guard binaryReads < limits.maximumBinaryReads else {
            return resourceLimitError(
                at: path,
                detail: "Inspecting one more binary would exceed the configured bound of \(limits.maximumBinaryReads) reads."
            )
        }
        claimedPaths.insert(path)
        binaryReads += 1
        let inspection = source.binary(
            at: archiveCandidate,
            declaredByteCount: declaredByteCount,
            maximumBytes: limits.maximumBinaryBytes
        )

        switch inspection.observation {
        case .machO:
            guard items.count < limits.maximumItems else {
                return resourceLimitError(
                    at: path,
                    detail: "Discovery located more code items than the configured bound of \(limits.maximumItems)."
                )
            }
            items.append(NestedCodeItem(
                id: NestedCodeItemID(kind: .dynamicLibrary, location: path),
                kind: .dynamicLibrary,
                bundlePath: container.bundlePath,
                executablePath: path,
                executableProvenance: nil,
                bundleInformation: .notPresent,
                binary: inspection.observation,
                existingSignature: inspection.existingSignature,
                parentID: container.itemID,
                status: .established
            ))
            return nil
        case .notMachO:
            // A regular file at a code location that is not Mach-O is not
            // nested code, whatever it is named, and it is not a signing
            // task either.
            return addDiagnostic(
                severity: .warning,
                code: .unclassifiedEntryInCodeLocation,
                detail: "The regular file recorded at '\(path.rawValue)' is not a Mach-O image, so it is not nested code.",
                path: path
            )
        default:
            if let reason = inspection.observation.notEstablishedReason {
                let item = NestedCodeItem(
                    id: NestedCodeItemID(kind: .dynamicLibrary, location: path),
                    kind: .dynamicLibrary,
                    bundlePath: container.bundlePath,
                    executablePath: path,
                    executableProvenance: nil,
                    bundleInformation: .notPresent,
                    binary: inspection.observation,
                    existingSignature: inspection.existingSignature,
                    parentID: container.itemID,
                    status: .notEstablished(reason)
                )
                guard items.count < limits.maximumItems else {
                    return resourceLimitError(
                        at: path,
                        detail: "Discovery located more code items than the configured bound of \(limits.maximumItems)."
                    )
                }
                items.append(item)
                return describeNotEstablished(reason, of: item)
            }
            return nil
        }
    }

    // MARK: - Locations outside the traversed structure

    /// Looks, by name only, for code-shaped objects outside the locations
    /// discovery traverses.
    ///
    /// The walk reads no content: it uses the entry table's recorded names and
    /// kinds, bounded by the configured directory depth and count. Its purpose
    /// is to report unexpected placement rather than to miss it — a nested
    /// application, a code bundle in the wrong directory, or a loose library
    /// somewhere else — and it never creates a signing task from a name.
    private mutating func examineUnsupportedLocations(
        of container: NestedCodeContainer
    ) -> NestedCodeDiscoveryError? {
        for name in index.childNames(of: container.bundlePath) {
            guard let childPath = container.bundlePath.appending(component: name) else {
                return invalidPathError(at: container.bundlePath)
            }
            if let failure = observeUnclaimedChild(name: name, path: childPath, depth: 0) {
                return failure
            }
        }
        return nil
    }

    private mutating func examineObservedDirectory(
        _ path: BundlePath,
        depth: Int
    ) -> NestedCodeDiscoveryError? {
        guard depth < limits.maximumDirectoryObservationDepth else { return nil }
        visitedDirectories += 1
        guard visitedDirectories <= limits.maximumVisitedDirectories else {
            return resourceLimitError(
                at: path,
                detail: "Discovery enumerated more directories than the configured bound of \(limits.maximumVisitedDirectories)."
            )
        }
        for name in index.childNames(of: path) {
            guard let childPath = path.appending(component: name) else {
                return invalidPathError(at: path)
            }
            if let failure = observeUnclaimedChild(name: name, path: childPath, depth: depth) {
                return failure
            }
        }
        return nil
    }

    /// Examines one location discovery has not already accounted for, using
    /// only its recorded name and entry kind.
    ///
    /// A directory is checked against the structure rules and, when the
    /// observation depth allows, descended into. A code-shaped name at any
    /// other entry kind is reported: a regular file named like code is named
    /// as unexpected placement, a symbolic link or unmodelled entry form is
    /// named as unsafe, and neither is ever read, followed, or turned into a
    /// signing task. Nothing about the content of a code-shaped name is
    /// claimed here, and a name that is not code-shaped is left alone — a
    /// resource is not code because of what it is called.
    private mutating func observeUnclaimedChild(
        name: String,
        path: BundlePath,
        depth: Int
    ) -> NestedCodeDiscoveryError? {
        guard !claimedPaths.contains(path) else { return nil }
        let kind = index.kind(of: path)

        switch kind {
        case .directory:
            if let failure = directoryStructureRule(name: name, path: path) {
                return failure
            }
            return examineObservedDirectory(path, depth: depth + 1)
        case .symbolicLink, .unsupported:
            guard NestedCodeLocation.looksLikeCodeFile(name) else { return nil }
            claimedPaths.insert(path)
            if let failure = admitUnsupportedItem(path: path, reason: .unsupportedStructure) {
                return failure
            }
            return addDiagnostic(
                severity: .warning,
                code: .unsafeEntryInCodeLocation,
                detail: "The entry recorded at '\(path.rawValue)' is \(kind?.displayName ?? "an unmodelled entry") and is named like code. ZynSign neither follows nor reads it, so the plan stays incomplete.",
                path: path
            )
        case .regularFile:
            guard NestedCodeLocation.looksLikeCodeFile(name) else { return nil }
            claimedPaths.insert(path)
            if let failure = admitUnsupportedItem(path: path, reason: .unsupportedStructure) {
                return failure
            }
            return addDiagnostic(
                severity: .warning,
                code: .unsupportedCodeLocation,
                detail: "A file named like code is recorded at '\(path.rawValue)', which is not a location ZynSign traverses; its content was not read.",
                path: path
            )
        case .none:
            return nil
        }
    }

    /// The structure rules applied to a directory discovery does not traverse.
    private func directoryStructureRule(
        name: String,
        path: BundlePath
    ) -> NestedCodeDiscoveryError? {
        if NestedCodeLocation.hasSuffix(name, IPALayout.applicationBundleSuffix) {
            return NestedCodeDiscoveryError(
                .unsupportedNestedCode,
                at: path,
                detail: "A nested application bundle is recorded at '\(path.rawValue)'. Its contents and its relationship to the enclosing application are outside the structure this build traverses."
            )
        }
        if NestedCodeLocation.codeBundleSuffixes.contains(where: { NestedCodeLocation.hasSuffix(name, $0) }) {
            return NestedCodeDiscoveryError(
                .unsupportedNestedCode,
                at: path,
                detail: "A code bundle is recorded at '\(path.rawValue)', which is not a supported location for that kind of bundle."
            )
        }
        return nil
    }

    // MARK: - Executable resolution

    /// Resolves a container's executable location.
    ///
    /// A declaration wins outright: when the container's own information file
    /// or the application's record names an executable, that name is the
    /// container's statement about itself, and discovery does not silently
    /// replace it with a guess when the named file is absent. The
    /// bundle-name convention is consulted only when there is no declaration,
    /// and it is recorded as inferred rather than declared.
    private func resolveExecutable(
        of container: NestedCodeContainer,
        declaredName: String?
    ) -> NestedCodeExecutableResolution {
        if let declaredName, !declaredName.isEmpty {
            guard BundlePath.isValidComponent(declaredName),
                  let candidate = container.bundlePath.appending(component: declaredName) else {
                return .unsafe(path: container.bundlePath, form: "named by a value that is not a safe single path component")
            }
            return resolution(for: candidate, provenance: .declared)
        }

        let containerName = container.bundlePath.isRoot
            ? bundlePath.lastComponent
            : (container.bundlePath.name ?? "")
        let convention = NestedCodeLocation.baseName(ofBundleNamed: containerName)
        if !convention.isEmpty, let candidate = container.bundlePath.appending(component: convention) {
            let resolution = resolution(for: candidate, provenance: .bundleNameConvention)
            if case .established = resolution {
                return resolution
            }
            if case .unsafe = resolution {
                return resolution
            }
        }

        let candidates = index.childNames(of: container.bundlePath).filter { name in
            guard name != IPALayout.bundleInformationFileName else { return false }
            guard let path = container.bundlePath.appending(component: name) else { return false }
            return index.isRegularFile(path)
        }
        if candidates.count >= 2 {
            return .ambiguous(Array(candidates.prefix(limits.maximumAmbiguityCandidates)))
        }
        return .missing
    }

    private func resolution(
        for candidate: BundlePath,
        provenance: NestedCodeExecutableProvenance
    ) -> NestedCodeExecutableResolution {
        switch index.kind(of: candidate) {
        case .regularFile:
            return .established(path: candidate, provenance: provenance)
        case .symbolicLink, .unsupported:
            return .unsafe(path: candidate, form: index.kind(of: candidate)?.displayName ?? "an unmodelled entry")
        case .directory, .none:
            return .missing
        }
    }

    /// The file name the platform's convention gives a bundle's executable:
    /// the container's own directory name without its bundle suffix. For the
    /// application this is the `.app` directory's base name.
    // MARK: - Recording

    private mutating func describeNotEstablished(
        _ reason: NestedCodeNotEstablished,
        of item: NestedCodeItem
    ) -> NestedCodeDiscoveryError? {
        let path = item.executablePath ?? item.id.location
        let unsupportedReason: NestedCodeUnsupportedReason
        let diagnosticCode: NestedCodeDiagnosticCode
        let detail: String

        switch reason {
        case .executableMissing:
            unsupportedReason = .executableNotEstablished
            diagnosticCode = .executableNotEstablished
            detail = "No executable could be established for the container at '\(item.bundlePath.rawValue)'."
        case .ambiguousExecutable(let names):
            unsupportedReason = .ambiguousExecutable
            diagnosticCode = .ambiguousExecutable
            detail = "The container at '\(item.bundlePath.rawValue)' records several possible executables (\(names.joined(separator: ", "))) and nothing chooses between them."
        case .binaryNotMachO:
            unsupportedReason = .binaryNotMachO
            diagnosticCode = .binaryNotUsable
            detail = "The established executable at '\(path.rawValue)' is not a Mach-O image."
        case .binaryMalformed(let error):
            unsupportedReason = .binaryMalformed
            diagnosticCode = .binaryNotUsable
            detail = "The established executable at '\(path.rawValue)' is malformed (\(error.reason), at \(error.boundary))."
        case .binaryUnsupported(let error):
            unsupportedReason = .binaryUnsupported
            diagnosticCode = .binaryNotUsable
            detail = "The established executable at '\(path.rawValue)' uses a form this build does not support (\(error.reason), at \(error.boundary))."
        case .binaryBeyondInspectionBound(let declaredByteCount):
            unsupportedReason = .binaryBeyondInspectionBound
            diagnosticCode = .binaryNotUsable
            detail = "The established executable at '\(path.rawValue)' declares \(declaredByteCount) bytes, beyond the configured inspection bound."
        case .binaryUnreadable:
            unsupportedReason = .binaryUnreadable
            diagnosticCode = .binaryNotUsable
            detail = "The established executable at '\(path.rawValue)' could not be read within the configured bound."
        case .binaryNotInspected:
            unsupportedReason = .binaryNotInspected
            diagnosticCode = .binaryNotUsable
            detail = "No content was inspected at '\(path.rawValue)', so the item could not be established as code."
        case .unsupportedStructure:
            unsupportedReason = .unsupportedStructure
            diagnosticCode = .structureNotTraversed
            detail = "The container at '\(item.bundlePath.rawValue)' is outside the structure this build traverses."
        }

        var failure = admitUnsupportedItem(path: item.id.location, reason: unsupportedReason)
        if failure == nil {
            failure = addDiagnostic(severity: .warning, code: diagnosticCode, detail: detail, path: path)
        }
        return failure
    }

    /// Records an unsupported item, bounded by the policy.
    private mutating func admitUnsupportedItem(
        path: BundlePath,
        reason: NestedCodeUnsupportedReason
    ) -> NestedCodeDiscoveryError? {
        guard unsupportedItems.count < limits.maximumUnsupportedItems else {
            return resourceLimitError(
                at: path,
                detail: "Discovery located more unsupported items than the configured bound of \(limits.maximumUnsupportedItems)."
            )
        }
        let item = NestedCodeUnsupportedItem(path: path, reason: reason)
        guard !unsupportedItems.contains(item) else { return nil }
        unsupportedItems.append(item)
        return nil
    }

    /// Records one diagnostic, bounded per code.
    private mutating func addDiagnostic(
        severity: NestedCodeDiagnosticSeverity,
        code: NestedCodeDiagnosticCode,
        detail: String,
        path: BundlePath? = nil
    ) -> NestedCodeDiscoveryError? {
        guard path == nil || !claimedDiagnostics.contains(DiagnosticKey(code: code, path: path)) else {
            return nil
        }
        let recorded = diagnosticCounts[code] ?? 0
        guard recorded < NestedCodeDiscovery.maximumDiagnosticsPerCode else { return nil }
        diagnosticCounts[code] = recorded + 1
        diagnostics.append(NestedCodeDiagnostic(severity: severity, code: code, detail: detail, path: path))
        if let path {
            claimedDiagnostics.insert(DiagnosticKey(code: code, path: path))
        }
        return nil
    }

    private struct DiagnosticKey: Hashable {
        let code: NestedCodeDiagnosticCode
        let path: BundlePath?
    }

    private var claimedDiagnostics: Set<DiagnosticKey> = []

    // MARK: - Paths and failures

    /// The package-relative location of a bundle-relative path.
    ///
    /// A `BundlePath` is already a validated, traversal-free name, so this can
    /// only fail if a component were unsafe — which a `BundlePath` cannot
    /// contain. Callers treat `nil` as an invalid path rather than assuming.
    private func archivePath(for path: BundlePath) -> ArchivePath? {
        var result = bundlePath
        for component in path.components {
            guard let next = result.appending(component: component) else { return nil }
            result = next
        }
        return result
    }

    private func bundleInformationPath(of containerPath: BundlePath) -> BundlePath {
        containerPath.appending(component: IPALayout.bundleInformationFileName) ?? containerPath
    }

    private func invalidPathError(at path: BundlePath) -> NestedCodeDiscoveryError {
        NestedCodeDiscoveryError(
            .invalidPath,
            at: path,
            detail: "The location '\(path.rawValue)' is not representable inside the managed application bundle."
        )
    }

    private func resourceLimitError(at path: BundlePath?, detail: String) -> NestedCodeDiscoveryError {
        NestedCodeDiscoveryError(.resourceLimitExceeded, at: path, detail: detail)
    }

    /// The container kind a directory under a code directory represents, when
    /// the structure supports it.
    private func supportedContainerKind(name: String, directoryName: String) -> NestedCodeKind? {
        if directoryName == IPALayout.frameworksDirectoryName,
           NestedCodeLocation.hasSuffix(name, NestedCodeLocation.frameworkSuffix) {
            return .framework
        }
        if directoryName == IPALayout.plugInsDirectoryName || directoryName == IPALayout.extensionsDirectoryName,
           NestedCodeLocation.hasSuffix(name, NestedCodeLocation.extensionSuffix) {
            return .applicationExtension
        }
        return nil
    }
}
