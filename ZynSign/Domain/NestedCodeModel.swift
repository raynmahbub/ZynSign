/// The vocabulary ZynSign's nested-code discovery speaks.
///
/// Nested code is the executable content an application bundle carries inside
/// itself: the application's own main executable, framework bundles, bundled
/// dynamic libraries, and application extensions. Discovery answers two
/// questions about that content — where it is, and in which order a later
/// stage would have to finalize it — and answers nothing else. Every value in
/// this file is descriptive: nothing here states that a binary is well formed
/// beyond the structure that was parsed, that an existing signature is valid
/// or trusted, that the application is installable, or that any platform would
/// accept a signature produced for it.
///
/// Two boundaries are deliberate.
///
/// **Paths stay inside the managed bundle.** Every location is a `BundlePath`
/// relative to the managed application bundle, so an item cannot name a
/// location above that bundle, a filesystem location, or the package that
/// carries it. The archive-level location of the bundle is the caller's
/// knowledge and is not part of a plan.
///
/// **The application is not a child of itself.** The root item stands for the
/// application bundle and carries the main executable's location; nested
/// items are the code inside it. The dependency model then expresses the
/// established relationship — nested code is finalized before the container
/// that seals it — without the root ever appearing as a nested component.

/// One code-bearing kind ZynSign recognizes inside a managed application
/// bundle.
///
/// The kinds are location-based, not content-based: a `.framework` directory
/// under a supported `Frameworks` directory is a framework because that is
/// what the bundle structure makes it, and a Mach-O file directly in that
/// directory is a dynamic library for the same reason. Mach-O inspection
/// confirms that a location holds a Mach-O image and describes how that image
/// is structured; it does not reassign the kind, and no kind is inferred from
/// a file name that the structure does not place at a code location.
enum NestedCodeKind: String, CaseIterable, Hashable {

    /// The managed application bundle itself. It is the root of every plan
    /// and is never a nested component of another item.
    case application

    /// A `.framework` bundle inside a supported `Frameworks` directory.
    case framework

    /// A Mach-O file directly inside a supported `Frameworks` directory. The
    /// location's established role is a bundled dynamic library; ZynSign
    /// records the location's role and does not interpret the image's
    /// declared file type.
    case dynamicLibrary

    /// An `.appex` bundle inside a supported extension directory — `PlugIns`,
    /// or `Extensions` in the layouts the bundle-entry role vocabulary
    /// already recognizes as holding extensions.
    case applicationExtension

    /// A short name for diagnostics and presentation.
    var displayName: String {
        switch self {
        case .application: return "Application"
        case .framework: return "Framework"
        case .dynamicLibrary: return "Dynamic library"
        case .applicationExtension: return "Application extension"
        }
    }

    /// Whether the kind is represented by a bundle directory of its own, so
    /// that the item has a container whose contents discovery may traverse.
    var isBundleBacked: Bool {
        switch self {
        case .application, .framework, .applicationExtension: return true
        case .dynamicLibrary: return false
        }
    }
}

/// How a container's executable location was established.
///
/// The provenance is recorded rather than resolved away, because a name the
/// bundle declared and a name ZynSign inferred from a convention are different
/// kinds of statement. Neither is evidence that the file is a usable
/// executable; the Mach-O observation is what establishes that.
enum NestedCodeExecutableProvenance: String, CaseIterable, Hashable {

    /// The container's own information file declared the executable name
    /// (`CFBundleExecutable`).
    case declared

    /// No declaration was available, and the file is named after the
    /// container's own directory, the platform's established convention.
    case bundleNameConvention

    /// A short name for diagnostics.
    var displayName: String {
        switch self {
        case .declared: return "declared by the bundle"
        case .bundleNameConvention: return "inferred from the bundle name"
        }
    }
}

/// A structural summary of one Mach-O image, derived from the existing
/// read-only parser.
///
/// The summary exists so that a plan stays a value even though parsing
/// produced a much larger tree: it keeps the container form and the per-slice
/// header facts, and drops hashes, blobs, and group content. A summary says
/// only how the bytes are arranged. It is not a statement that the image is
/// loadable, that its declared file type is honoured by any platform, or that
/// anything about it is signed.
struct NestedCodeMachOSummary: Equatable {

    /// The form of the Mach-O container.
    enum Container: String, CaseIterable, Hashable {

        /// A single-architecture image.
        case thin

        /// A universal (fat) image with one or more architecture slices.
        case universal
    }

    /// The header facts of one inspected slice.
    struct Slice: Equatable {

        /// The CPU family the slice declares.
        let cpu: MachOCPU

        /// The CPU subtype, preserved verbatim including capability bits.
        let cpuSubtype: Int32

        /// The declared file type, preserved verbatim. ZynSign assigns no
        /// semantics to it here and does not use it to classify the item.
        let fileType: UInt32

        /// The header word size.
        let wordSize: MachOWordSize

        /// The header byte order.
        let byteOrder: MachOByteOrder
    }

    let container: Container

    /// One entry per inspected slice, in container order.
    let slices: [Slice]

    /// How many slices the image carries.
    var architectureCount: Int { slices.count }

    /// Whether the image is a universal container.
    var isUniversal: Bool { container == .universal }
}

/// What discovery established about a candidate's existing code signature.
///
/// The states mirror the existing read-only inspection vocabulary and add
/// nothing to it: no state means "signed", "valid", "trusted", or "accepted".
/// A structurally parseable signature is a statement about the bytes being
/// arranged as a SuperBlob; whether the signature verifies, whether its
/// certificate chain is trusted, and whether a platform would accept it are
/// separate questions this discovery does not ask and cannot answer.
enum NestedCodeExistingSignature: Equatable {

    /// No signature state was evaluated, because the binary's content was
    /// never obtained or was not a Mach-O image.
    case notEvaluated

    /// The image carries no `LC_CODE_SIGNATURE` command in any slice.
    case absent

    /// Every slice carries a structurally parseable embedded signature.
    case structurallyParsed(signedSliceCount: Int)

    /// Some slices carry a signature and some do not.
    case incompleteSlices(totalSliceCount: Int, signedSliceCount: Int)

    /// Signature data is present but structurally unusable; the parser's
    /// state identifies where it failed.
    case malformed(MachOExistingCodeSignatureState)

    /// Signature data is present and recognized, but uses a form this build
    /// does not model.
    case unsupported(MachOExistingCodeSignatureState)
}

/// The identity a bundle declares about itself, as far as discovery reads it.
///
/// Every field is a declaration, preserved as declared. Carrying an identifier
/// says nothing about authorisation, entitlement, team, or which signature may
/// be applied to the bundle; discovery deliberately cannot reach those
/// questions, and a later stage must not read a declared identifier as
/// permission to sign anything.
struct NestedCodeBundleIdentity: Equatable, Hashable {

    /// The declared bundle identifier, when one was declared and accepted.
    let bundleIdentifier: BundleIdentifier?

    /// The declared executable name, when one was declared.
    let executableName: String?

    /// The declared bundle package type (`CFBundlePackageType`), preserved
    /// verbatim, when one was declared.
    let packageType: String?

    /// The declared marketing version, when one was declared.
    let shortVersionString: String?

    /// The declared build version, when one was declared.
    let buildVersion: String?

    /// Records declared identity values.
    init(
        bundleIdentifier: BundleIdentifier? = nil,
        executableName: String? = nil,
        packageType: String? = nil,
        shortVersionString: String? = nil,
        buildVersion: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.executableName = executableName
        self.packageType = packageType
        self.shortVersionString = shortVersionString
        self.buildVersion = buildVersion
    }

    /// Records the identity an already-read metadata record declared.
    init(metadata: ApplicationMetadata, packageType: String? = nil) {
        self.init(
            bundleIdentifier: metadata.identity.bundleIdentifier,
            executableName: metadata.executableName,
            packageType: packageType,
            shortVersionString: metadata.identity.shortVersionString,
            buildVersion: metadata.identity.buildVersion
        )
    }
}

/// What discovery established about a container bundle's information file.
///
/// A nested container is read because nothing else in ZynSign has read it: the
/// managed application's own metadata is established by the import and
/// metadata stages, and is not re-read here. The states separate "the bundle
/// declares nothing" from "the declaration could not be used", because only
/// the second is a defect in the bundle rather than an ordinary omission.
enum NestedCodeBundleInformation: Equatable {

    /// The container records no information file at its own root.
    case notPresent

    /// The information file was read and its declared identity parsed.
    case read(NestedCodeBundleIdentity)

    /// An information file is recorded but its content could not be produced
    /// within the read bound, or is not a regular file.
    case unreadable

    /// An information file was read but its declared metadata did not satisfy
    /// the existing metadata rules.
    case malformed

    /// The declared identity, when the information file was read.
    var identity: NestedCodeBundleIdentity? {
        if case .read(let identity) = self {
            return identity
        }
        return nil
    }
}

/// What Mach-O inspection established about one candidate location.
///
/// The states answer "are these bytes a Mach-O image, and how are they
/// arranged?" Nothing else. A file that is not Mach-O is not code, whatever
/// its name, permissions, or extension suggest; a file that is Mach-O at a
/// code location is code even when the parser could not finish reading it,
/// because the classification is made from structure rather than from a name.
enum NestedCodeBinaryObservation: Equatable {

    /// No content was requested for this location.
    case notRequested

    /// The bytes are a Mach-O image. The summary is absent when the parser
    /// established the container and header but the failure was confined to
    /// the image's signature region; the item is still Mach-O code, and the
    /// separate signature observation records what was wrong.
    case machO(summary: NestedCodeMachOSummary?)

    /// The bytes are not a Mach-O image in any recognized form.
    case notMachO

    /// The bytes begin like a Mach-O image but are structurally unusable.
    case malformed(MachOParsingError)

    /// The bytes are a recognized Mach-O form this build does not model.
    case unsupported(MachOParsingError)

    /// The container declares the entry larger than the configured
    /// inspection bound, so no content was requested for it.
    case beyondInspectionBound(declaredByteCount: Int)

    /// The content could not be produced, or could not be produced within the
    /// configured bound. The failure is in the package's content.
    case unreadable

    /// Whether this observation establishes Mach-O code at the location.
    var establishesMachO: Bool {
        if case .machO = self {
            return true
        }
        return false
    }
}

/// Why one located item could not be established as signable code.
///
/// The reasons are deliberately specific: "the executable is missing", "the
/// container does not say which file is executable", "the bytes are not
/// Mach-O", "the bytes are Mach-O but unreadable as one", "the content could
/// not be produced", and "the structure is outside what this build traverses"
/// lead to different remedies and must not be collapsed into a single failure.
enum NestedCodeNotEstablished: Equatable {

    /// No executable could be established for the container: the declared
    /// name is absent from the container and the bundle-name convention does
    /// not name a regular file either.
    case executableMissing

    /// The container records several possible executables and neither a
    /// declaration nor the bundle-name convention chooses between them.
    /// ZynSign does not guess; the candidate names are recorded for the
    /// caller to inspect.
    case ambiguousExecutable([String])

    /// The bytes at the executable's location are not a Mach-O image.
    case binaryNotMachO

    /// The bytes begin like a Mach-O image but are structurally unusable.
    case binaryMalformed(MachOParsingError)

    /// The bytes are a recognized Mach-O form this build does not model.
    case binaryUnsupported(MachOParsingError)

    /// The container declares the executable larger than the inspection
    /// bound, so its content was not read.
    case binaryBeyondInspectionBound(declaredByteCount: Int)

    /// The executable's content could not be produced.
    case binaryUnreadable

    /// The item is a code-bearing object at a location whose structure this
    /// build does not traverse, or is a structure whose role is ambiguous.
    case unsupportedStructure
}

/// What discovery established about one located item.
enum NestedCodeItemStatus: Equatable {

    /// The item's executable was established and inspected as Mach-O code.
    case established

    /// The item was located but could not be established as signable code.
    case notEstablished(NestedCodeNotEstablished)

    /// Whether the item may appear as an executable step in a plan.
    var isEstablished: Bool {
        if case .established = self {
            return true
        }
        return false
    }
}

/// The stable identity of one item: what kind of code it is and where it is,
/// relative to the managed application bundle.
///
/// Location and kind together are unique inside one bundle. The root
/// application's identity is the bundle root, so it can never collide with a
/// nested item's.
struct NestedCodeItemID: Hashable, CustomStringConvertible {

    let kind: NestedCodeKind

    /// The item's own location: the container bundle's directory for a
    /// bundle-backed item, the file for a standalone one. The bundle root
    /// for the application itself.
    let location: BundlePath

    /// A stable, log-safe rendering.
    var description: String {
        location.isRoot ? kind.rawValue : "\(kind.rawValue):\(location.rawValue)"
    }
}

/// One code item discovery located inside the managed application bundle.
///
/// An item is a description of a location and what was established about it.
/// It holds no bytes, no handle, no filesystem location, and no way to reach
/// either; the executable path is a `BundlePath` and cannot leave the bundle.
struct NestedCodeItem: Equatable {

    let id: NestedCodeItemID

    /// The item's kind, decided by its location in the bundle structure.
    let kind: NestedCodeKind

    /// The item's own container bundle directory, relative to the managed
    /// bundle. The bundle root for the application itself.
    let bundlePath: BundlePath

    /// The established executable's location, relative to the managed bundle,
    /// or `nil` when no executable could be established.
    let executablePath: BundlePath?

    /// How the executable's name was established, when one was.
    let executableProvenance: NestedCodeExecutableProvenance?

    /// What was established about the item's own information file, when the
    /// item is bundle-backed and discovery read one.
    let bundleInformation: NestedCodeBundleInformation

    /// What Mach-O inspection established about the executable's bytes.
    let binary: NestedCodeBinaryObservation

    /// What was established about an existing code signature.
    let existingSignature: NestedCodeExistingSignature

    /// The enclosing item's identity, or `nil` for the application itself.
    let parentID: NestedCodeItemID?

    let status: NestedCodeItemStatus

    /// The identity the item's own information file declared, when it declared
    /// one. A declaration only.
    var identity: NestedCodeBundleIdentity? {
        bundleInformation.identity
    }

    /// Whether this item is the managed application bundle itself.
    var isApplication: Bool {
        kind == .application
    }
}

/// One ordering constraint in a plan: `nestedCode` must be finalized before
/// `container` may be.
///
/// The direction is stated by the type's own vocabulary rather than by an
/// index into an ordered list, so a later stage cannot read it backwards. It
/// expresses one established relationship and nothing else: the code a
/// container seals must be signed before the container's own signature is
/// written. Discovery does not invent runtime dependencies between sibling
/// components, because the bundle structure does not establish them.
struct NestedCodeDependency: Equatable, Hashable {

    /// The item that must be finalized first.
    let nestedCode: NestedCodeItemID

    /// The item that must be finalized after it.
    let container: NestedCodeItemID
}

/// One step of a plan's signing order.
///
/// `order` is one-based and contiguous, so a caller can execute steps in
/// ascending order without re-deriving anything. A step names its item rather
/// than copying it, so the plan holds one description of each item.
struct NestedCodeSigningStep: Equatable, Hashable {

    /// The step's one-based position in the plan.
    let order: Int

    /// The item this step signs.
    let itemID: NestedCodeItemID
}

/// Why one located object is not part of a plan's executable steps.
///
/// An unsupported item is a statement about discovery's capability or about
/// the object's structure — never a claim that the object is malware, that it
/// is signed, or that it is invalid as an application. A plan that carries any
/// unsupported item is incomplete, and a later stage must not execute it.
enum NestedCodeUnsupportedReason: String, CaseIterable, Hashable {

    /// No executable could be established for the container.
    case executableNotEstablished

    /// Several possible executables exist and nothing chooses between them.
    case ambiguousExecutable

    /// The bytes at the executable's location are not a Mach-O image.
    case binaryNotMachO

    /// The bytes begin like a Mach-O image but are structurally unusable.
    case binaryMalformed

    /// The bytes are a recognized Mach-O form this build does not model.
    case binaryUnsupported

    /// The container declares the executable larger than the inspection bound.
    case binaryBeyondInspectionBound

    /// The executable's content could not be produced.
    case binaryUnreadable

    /// No content was obtained for the executable's location even though the
    /// structure proposes it.
    case binaryNotInspected

    /// The object is code-bearing content whose role or location this build
    /// does not traverse.
    case unsupportedStructure

    /// The container's information file is recorded but unusable.
    case unreadableBundleInformation

    /// The container's information file was read and rejected.
    case malformedBundleInformation

    /// A short name for diagnostics.
    var displayName: String {
        switch self {
        case .executableNotEstablished: return "no executable could be established"
        case .ambiguousExecutable: return "several possible executables"
        case .binaryNotMachO: return "not a Mach-O image"
        case .binaryMalformed: return "a malformed Mach-O image"
        case .binaryUnsupported: return "an unsupported Mach-O form"
        case .binaryBeyondInspectionBound: return "larger than the inspection bound"
        case .binaryUnreadable: return "content could not be read"
        case .binaryNotInspected: return "no content was inspected"
        case .unsupportedStructure: return "a structure this build does not traverse"
        case .unreadableBundleInformation: return "an unreadable information file"
        case .malformedBundleInformation: return "a rejected information file"
        }
    }
}

/// One located object that is not an executable step of the plan.
struct NestedCodeUnsupportedItem: Equatable, Hashable {

    /// The object's location, relative to the managed application bundle.
    let path: BundlePath

    let reason: NestedCodeUnsupportedReason
}

/// How seriously one discovery observation bears on a plan.
enum NestedCodeDiagnosticSeverity: String, CaseIterable, Hashable {

    /// A factual record of what discovery observed.
    case note

    /// An observation a later stage must consider before executing the plan.
    case warning
}

/// The machine-readable identity of one discovery observation.
///
/// Codes are the stable part of a diagnostic: presentation and diagnostics
/// switch on the code, then read the technical detail. They describe what
/// discovery observed about structure; none of them is a verdict on a binary,
/// a signature, a certificate, a profile, or an application.
enum NestedCodeDiagnosticCode: String, CaseIterable, Hashable {

    /// A regular file sits at a code location but is not a Mach-O image, so it
    /// is not nested code.
    case unclassifiedEntryInCodeLocation

    /// A code-shaped object sits outside the locations this build traverses.
    /// The observation is made from its name and location; no content was
    /// read and no Mach-O claim is made.
    case unsupportedCodeLocation

    /// A container's executable was named by a convention rather than by a
    /// declaration.
    case executableNameInferred

    /// A container's information file is recorded but unusable, or was
    /// rejected.
    case bundleInformationUnavailable

    /// Two bundles inside the managed application declare the same bundle
    /// identifier, so the plan's declaration record is contradictory.
    case conflictingBundleIdentifier

    /// A located item's executable could not be established.
    case executableNotEstablished

    /// A container records several possible executables and ZynSign does not
    /// choose between them.
    case ambiguousExecutable

    /// A located executable is not a Mach-O image, or is one this build
    /// cannot read or does not model.
    case binaryNotUsable

    /// A code-bearing object sits at a location whose structure this build
    /// does not traverse, so its contents were not inspected.
    case structureNotTraversed

    /// A symbolic link or unmodelled entry form sits where code would be
    /// expected. The target was not read and was not followed.
    case unsafeEntryInCodeLocation

    /// One location is recorded more than once with differing kinds, so the
    /// recorded structure contradicts itself. Discovery keeps the first
    /// recorded kind for that location, reports the contradiction, and does
    /// not choose between the recorded forms.
    case conflictingEntryKind

    /// A container recorded entries whose names failed ZynSign's safety rules,
    /// so they could not be attributed to any bundle location.
    case unattributableEntryName
}

/// One observation discovery recorded about a plan.
///
/// `detail` is technical diagnostic context written for logs and reports. It
/// names bundle-relative locations and structural facts only, and callers
/// remain responsible for the redaction rules: no key material, credentials,
/// profile bodies, device identifiers, or user data may be placed in it.
struct NestedCodeDiagnostic: Equatable, Hashable {

    let severity: NestedCodeDiagnosticSeverity
    let code: NestedCodeDiagnosticCode
    let detail: String

    /// The bundle-relative location the observation concerns, when it
    /// concerns exactly one.
    let path: BundlePath?
}

/// The resource policy nested-code discovery applies while reading a bundle.
///
/// The bounds are ZynSign policy, not platform limits. They exist so that an
/// untrusted bundle cannot make discovery read, allocate, or report without a
/// ceiling: every bound below, when exceeded, ends discovery with a structured
/// resource-limit failure rather than quietly truncating a plan.
struct NestedCodeDiscoveryLimits: Equatable, Hashable {

    /// The greatest number of code items one plan may locate, the application
    /// included.
    let maximumItems: Int

    /// The greatest number of candidate binaries discovery may inspect.
    let maximumBinaryReads: Int

    /// The greatest number of nested information files discovery may read.
    let maximumBundleInformationReads: Int

    /// The greatest byte count discovery accepts for one candidate binary.
    let maximumBinaryBytes: Int

    /// The greatest byte count discovery accepts for one nested information
    /// file.
    let maximumBundleInformationBytes: Int

    /// The greatest container nesting depth below the application. Zero would
    /// permit the application's own executable only.
    let maximumContainerDepth: Int

    /// The greatest number of directory levels discovery looks at below a
    /// visited container while looking for code-bearing names.
    let maximumDirectoryObservationDepth: Int

    /// The greatest number of directories one traversal may enumerate.
    let maximumVisitedDirectories: Int

    /// The greatest number of unsupported items one plan may carry. Together
    /// with the per-code bound on diagnostics, this bounds how large a plan's
    /// report can become whatever a container records.
    let maximumUnsupportedItems: Int

    /// The greatest number of candidate names reported for one ambiguous
    /// executable.
    let maximumAmbiguityCandidates: Int

    /// The policy ZynSign applies unless the composition root chooses another.
    ///
    /// The numbers are conservative ceilings for an ordinary redistributable
    /// application, chosen so that a normal application is never refused and
    /// a hostile one cannot describe work far larger than itself.
    static let `default` = NestedCodeDiscoveryLimits(
        maximumItems: 512,
        maximumBinaryReads: 512,
        maximumBundleInformationReads: 512,
        maximumBinaryBytes: 32 * 1_024 * 1_024,
        maximumBundleInformationBytes: 1_024 * 1_024,
        maximumContainerDepth: 4,
        maximumDirectoryObservationDepth: 2,
        maximumVisitedDirectories: 4_096,
        maximumUnsupportedItems: 256,
        maximumAmbiguityCandidates: 8
    )
}

/// The outcome of nested-code discovery for one managed application bundle.
///
/// A plan is the ordinary outcome. A rejection is reserved for input that
/// cannot be modelled coherently at all — a graph that contradicts itself, a
/// security violation, a path that cannot be expressed inside the bundle, a
/// resource policy bound, an application whose own executable cannot be
/// established, or a structure discovery deliberately refuses to traverse.
/// Everything else is reported inside the plan, where a later stage can see
/// exactly what was and was not established.
enum NestedCodeDiscoveryOutcome: Equatable {

    /// A plan, complete or explicitly incomplete.
    case plan(NestedCodeSigningPlan)

    /// A structured rejection; no plan was produced.
    case rejected(NestedCodeDiscoveryError)

    /// The plan, when discovery produced one.
    var signingPlan: NestedCodeSigningPlan? {
        if case .plan(let plan) = self {
            return plan
        }
        return nil
    }
}

/// The signing plan for one managed application bundle.
///
/// The plan makes execution order explicit. `root` is the application bundle
/// and its main executable; `nestedItems` are the code inside it; `steps` is
/// the order a later stage would execute, which is derived from `dependencies`
/// rather than from a directory listing, and always ends with the application
/// itself. `unsupportedItems` records everything discovery located but could
/// not establish, and `diagnostics` records what it observed along the way.
///
/// Immutability is deliberate: every stored property is a `let`, and every
/// collection was assembled once, in a deterministic order, before the plan
/// was returned. Nothing in a plan can be signed, and nothing in it reaches
/// the archive, the filesystem, or a key.
struct NestedCodeSigningPlan: Equatable {

    /// The managed application bundle's item: its identity, its declared
    /// metadata, and its established main executable.
    let root: NestedCodeItem

    /// The nested items discovery located, ordered by location so that the
    /// same bundle always lists them the same way.
    let nestedItems: [NestedCodeItem]

    /// The ordering constraints the plan rests on, in deterministic order.
    let dependencies: [NestedCodeDependency]

    /// The signing order: one step per established item, ascending, with the
    /// application last.
    let steps: [NestedCodeSigningStep]

    /// Everything discovery located but could not establish as signable code,
    /// in deterministic order.
    let unsupportedItems: [NestedCodeUnsupportedItem]

    /// What discovery observed, in traversal order.
    let diagnostics: [NestedCodeDiagnostic]

    /// The root item together with every nested item, application first.
    var items: [NestedCodeItem] {
        [root] + nestedItems
    }

    /// The application's item identity.
    var rootItemID: NestedCodeItemID {
        root.id
    }

    /// The main executable's location, when discovery established it.
    var mainExecutablePath: BundlePath? {
        root.executablePath
    }

    /// Whether discovery established every located object and left nothing
    /// unsupported. A later stage must not execute a plan for which this is
    /// `false`.
    var isComplete: Bool {
        unsupportedItems.isEmpty && nestedItems.allSatisfy { $0.status.isEstablished }
    }

    /// The item order the steps describe.
    var orderedItemIDs: [NestedCodeItemID] {
        steps.map(\.itemID)
    }

    /// The item with the given identity, if the plan holds one.
    func item(withID id: NestedCodeItemID) -> NestedCodeItem? {
        if root.id == id {
            return root
        }
        return nestedItems.first { $0.id == id }
    }

    /// The step recorded for one item, if the item is an established one.
    func step(for itemID: NestedCodeItemID) -> NestedCodeSigningStep? {
        steps.first { $0.itemID == itemID }
    }
}
