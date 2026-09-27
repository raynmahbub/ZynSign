import Foundation

/// Validates one imported container before the signing engine signs anything.
///
/// Validation runs on the source container, through the ordinary read-only
/// archive boundary, after the run has created its working copy and before a
/// single byte is signed. It answers the questions a signing run must not
/// discover halfway through: is the container structurally a package this
/// build signs, does the bundle carry an information file and the executable
/// that file declares, is every nested bundle readable, and does the container
/// use a layout this build supports.
///
/// What validation is not: it is not a trust evaluation, not an authorization
/// check, and not an installability claim. A passing report means the run can
/// proceed without meeting a structural surprise; it says nothing about who
/// signed anything before, whether any certificate is trusted, or whether a
/// platform would accept the result.
struct SigningEngineBundleValidator {

    private let makeReader: (URL) -> any ArchiveReader
    private let limits: ArchiveLimits
    private let parser: any MachOParsing
    private let discoveryLimits: NestedCodeDiscoveryLimits

    init(
        makeReader: @escaping (URL) -> any ArchiveReader = { ZipArchiveReader(location: $0) },
        limits: ArchiveLimits = .default,
        parser: any MachOParsing = ReadOnlyMachOParser(),
        discoveryLimits: NestedCodeDiscoveryLimits = .default
    ) {
        self.makeReader = makeReader
        self.limits = limits
        self.parser = parser
        self.discoveryLimits = discoveryLimits
    }

    /// Validates one container.
    ///
    /// - Parameters:
    ///   - containerURL: The container to validate. Read but never modified.
    ///   - existingSignaturePolicy: How existing signatures are treated by
    ///     the run that follows. Under the default policy a binary that
    ///     already carries a signature is an unsupported layout, so the run
    ///     refuses it here instead of at the first signing step.
    /// - Returns: Every check's outcome, in the fixed order they ran.
    /// - Throws: A typed `ZynSignError` only when the container itself cannot
    ///   be read: an unreadable container is an infrastructure fact, not a
    ///   finding about the bundle. Structural findings are returned as failed
    ///   checks.
    func validate(
        containerURL: URL,
        existingSignaturePolicy: MachOExistingCodeSignaturePolicy = .rejectExistingSignature
    ) throws -> BundleValidationReport {
        let reader = makeReader(containerURL)
        defer { reader.close() }
        let table = try reader.readEntryTable()
        var checks: [BundleValidationCheck] = []

        // 1. Payload structure.
        let inspection = IPAStructureValidator(limits: limits).validate(entryTable: table)
        guard inspection.isValid,
              let bundle = inspection.bundle,
              let bundleName = bundle.bundlePath.components.last,
              IPALayout.namesApplicationBundle(bundleName) else {
            checks.append(BundleValidationCheck(
                identifier: .payloadStructure,
                passed: false,
                detail: "The container does not carry a single application bundle under Payload/."
            ))
            return BundleValidationReport(checks: checks, bundlePath: nil, nestedTargetCount: 0)
        }
        let bundlePath = bundle.bundlePath
        checks.append(BundleValidationCheck(
            identifier: .payloadStructure,
            passed: true,
            detail: "Payload/\(bundleName) with \(table.count) recorded entries."
        ))

        // 2. Information file.
        let informationPath = IPALayout.bundleInformationPath(within: bundlePath)
        var metadata: ApplicationMetadata?
        if let informationPath,
           let bytes = try? reader.readEntryData(at: informationPath, maximumBytes: limits.maximumInspectionReadBytes) {
            let examination = ApplicationMetadataReader.read(from: bytes)
            if examination.isValid, let read = examination.metadata {
                metadata = read
                checks.append(BundleValidationCheck(
                    identifier: .informationFile,
                    passed: true,
                    detail: "\(bundleName)/Info.plist declares \(read.identity.bundleIdentifier.rawValue) and executable \(read.executableName ?? "—")."
                ))
            } else {
                checks.append(BundleValidationCheck(
                    identifier: .informationFile,
                    passed: false,
                    detail: "\(bundleName)/Info.plist could not be read as bundle metadata."
                ))
            }
        } else {
            checks.append(BundleValidationCheck(
                identifier: .informationFile,
                passed: false,
                detail: "\(bundleName)/Info.plist is missing or unreadable."
            ))
        }

        guard let metadata, let executableName = metadata.executableName else {
            checks.append(BundleValidationCheck(
                identifier: .executableFile,
                passed: false,
                detail: "No declared executable could be established."
            ))
            checks.append(BundleValidationCheck(
                identifier: .requiredFiles,
                passed: false,
                detail: "The bundle's required files could not be established."
            ))
            checks.append(BundleValidationCheck(
                identifier: .nestedBundles,
                passed: false,
                detail: "Nested bundles could not be inspected without an established executable."
            ))
            checks.append(BundleValidationCheck(
                identifier: .supportedLayout,
                passed: false,
                detail: "The container's layout could not be established."
            ))
            return BundleValidationReport(checks: checks, bundlePath: bundlePath, nestedTargetCount: 0)
        }

        let executablePath = bundlePath.appending(component: executableName)

        // 3. Executable file.
        var mainExecutableBytes: Data?
        let executableEntries = table.filter { $0.path == executablePath }
        if executablePath == nil || executableEntries.isEmpty {
            checks.append(BundleValidationCheck(
                identifier: .executableFile,
                passed: false,
                detail: "The declared executable \(executableName) is not recorded in the bundle."
            ))
        } else if executableEntries.count > 1 || executableEntries[0].kind != .regularFile {
            checks.append(BundleValidationCheck(
                identifier: .executableFile,
                passed: false,
                detail: "The declared executable \(executableName) is not exactly one regular file."
            ))
        } else if let path = executablePath,
                 let bytes = try? reader.readEntryData(at: path, maximumBytes: limits.maximumEntryBytes) {
            mainExecutableBytes = bytes
            let verdict = Self.machOForm(of: bytes, parser: parser)
            checks.append(BundleValidationCheck(
                identifier: .executableFile,
                passed: verdict.isSignableForm,
                detail: verdict.detail(prefixedWith: "The main executable")
            ))
        } else {
            checks.append(BundleValidationCheck(
                identifier: .executableFile,
                passed: false,
                detail: "The declared executable \(executableName) could not be read."
            ))
        }

        // 4. Required files.
        var requiredDetail = "\(bundleName)/Info.plist and \(bundleName)/\(executableName) are present exactly once."
        var requiredPassed = true
        if let informationPath {
            let informationEntries = table.filter { $0.path == informationPath }
            if informationEntries.count != 1 || informationEntries[0].kind != .regularFile {
                requiredPassed = false
                requiredDetail = "\(bundleName)/Info.plist is not exactly one regular file."
            }
        } else {
            requiredPassed = false
            requiredDetail = "The bundle information location cannot be named."
        }
        if requiredPassed, executableEntries.count != 1 {
            requiredPassed = false
            requiredDetail = "\(bundleName)/\(executableName) is not exactly one entry."
        }
        checks.append(BundleValidationCheck(
            identifier: .requiredFiles,
            passed: requiredPassed,
            detail: requiredDetail
        ))

        // 5. Nested bundles, through the same discovery the signing run uses.
        let discovery = NestedCodeDiscovery.discover(
            entryTable: table,
            request: NestedCodeDiscoveryRequest(
                bundlePath: bundlePath,
                applicationIdentity: NestedCodeBundleIdentity(metadata: metadata)
            ),
            limits: discoveryLimits,
            source: ArchiveNestedCodeInspectionSource(reader: reader, limits: limits)
        )
        var signedPlan: NestedCodeSigningPlan?
        var nestedTargetCount = 0
        switch discovery {
        case .rejected(let error):
            checks.append(BundleValidationCheck(
                identifier: .nestedBundles,
                passed: false,
                detail: error.detail
            ))
        case .plan(let plan):
            signedPlan = plan
            nestedTargetCount = plan.nestedItems.count
            var unreadable: String?
            for item in plan.nestedItems {
                guard let itemExecutable = item.executablePath else {
                    unreadable = "\(item.bundlePath.rawValue) declares no executable discovery could establish"
                    break
                }
                let containerInformation = Self.archivePath(
                    within: bundlePath,
                    relative: item.bundlePath.appending(component: IPALayout.bundleInformationFileName) ?? item.bundlePath
                )
                let readable = containerInformation.flatMap { path in
                    try? reader.readEntryData(at: path, maximumBytes: limits.maximumInspectionReadBytes)
                }
                let executableRecorded = Self.archivePath(within: bundlePath, relative: itemExecutable).map { path in
                    table.contains { $0.path == path && $0.kind == .regularFile }
                } ?? false
                if readable == nil {
                    unreadable = "\(item.bundlePath.rawValue)/Info.plist could not be read"
                    break
                }
                if !executableRecorded {
                    unreadable = "\(itemExecutable.rawValue) is not recorded as a regular file"
                    break
                }
            }
            checks.append(BundleValidationCheck(
                identifier: .nestedBundles,
                passed: unreadable == nil,
                detail: unreadable ?? (plan.nestedItems.isEmpty
                    ? "The bundle carries no nested bundles."
                    : "\(plan.nestedItems.count) nested container(s) read, every information file and executable present.")
            ))
        }

        // 6. Supported layout.
        var layoutDetail = "No existing signature and no unsupported container form was found."
        var layoutPassed = true
        if case .plan(let plan) = discovery, !plan.unsupportedItems.isEmpty {
            layoutPassed = false
            let first = plan.unsupportedItems[0]
            layoutDetail = "\(first.path.rawValue) is \(first.reason.displayName), which this build does not sign."
        }
        if layoutPassed, case .rejected(let error) = discovery {
            layoutPassed = false
            layoutDetail = error.detail
        }
        if layoutPassed, let bytes = mainExecutableBytes, let signature = Self.existingSignature(of: bytes, parser: parser),
           signature.isPresent {
            layoutPassed = false
            layoutDetail = existingSignaturePolicy == .rejectExistingSignature
                ? "The main executable already carries a code signature, which this run does not replace."
                : "The main executable already carries a code signature, and signature replacement is unsupported."
        }
        if layoutPassed, let plan = signedPlan {
            for item in plan.nestedItems {
                guard let itemExecutable = item.executablePath,
                      let path = Self.archivePath(within: bundlePath, relative: itemExecutable),
                      let bytes = try? reader.readEntryData(at: path, maximumBytes: limits.maximumEntryBytes) else {
                    continue
                }
                if let signature = Self.existingSignature(of: bytes, parser: parser), signature.isPresent {
                    layoutPassed = false
                    layoutDetail = "\(itemExecutable.rawValue) already carries a code signature, which this run does not replace."
                    break
                }
            }
        }
        checks.append(BundleValidationCheck(
            identifier: .supportedLayout,
            passed: layoutPassed,
            detail: layoutDetail
        ))

        return BundleValidationReport(
            checks: checks,
            bundlePath: bundlePath,
            nestedTargetCount: nestedTargetCount
        )
    }

    // MARK: - Path helpers

    /// The container location of a bundle-relative path, or `nil` when it
    /// cannot be expressed inside the container.
    static func archivePath(within bundlePath: ArchivePath, relative: BundlePath) -> ArchivePath? {
        var path = bundlePath
        for component in relative.components {
            guard let next = path.appending(component: component) else { return nil }
            path = next
        }
        return path
    }

    // MARK: - Mach-O observations

    /// What kind of Mach-O container a binary holds, in the vocabulary the
    /// checks speak.
    enum MachOForm: Equatable {
        case signableThinArm64
        case universal(sliceCount: Int)
        case nonArm64(cpu: String)
        case notExecutable(fileType: UInt32)
        case unreadable

        var isSignableForm: Bool { self == .signableThinArm64 }

        func detail(prefixedWith prefix: String) -> String {
            switch self {
            case .signableThinArm64:
                return "\(prefix) is a thin arm64 Mach-O image."
            case .universal(let count):
                return "\(prefix) is a universal container with \(count) slices, which this build does not sign."
            case .nonArm64(let cpu):
                return "\(prefix) declares the CPU \(cpu), which this build does not sign."
            case .notExecutable(let fileType):
                return "\(prefix) declares the Mach-O file type \(fileType), which this build does not sign."
            case .unreadable:
                return "\(prefix) could not be read as a Mach-O image."
            }
        }
    }

    /// Classifies one binary's container form.
    static func machOForm(of bytes: Data, parser: any MachOParsing = ReadOnlyMachOParser()) -> MachOForm {
        guard let image = try? parser.parse(bytes) else { return .unreadable }
        switch image.container {
        case .universal(let universal):
            return .universal(sliceCount: universal.slices.count)
        case .thin(let slice):
            guard slice.header.wordSize == .bits64, slice.header.byteOrder == .littleEndian else {
                return .unreadable
            }
            guard slice.header.cpu == .arm64 else {
                return .nonArm64(cpu: "\(slice.header.cpu)")
            }
            guard slice.header.fileType == 2 else {
                return .notExecutable(fileType: slice.header.fileType)
            }
            return .signableThinArm64
        }
    }

    /// What an inspection established about an existing signature, collapsed
    /// to the three states the checks reason about.
    enum ExistingSignature: Equatable {
        case absent
        case present
        case malformed
        case unsupported

        var isPresent: Bool { self != .absent }
    }

    /// Reports whether a binary already carries a code signature.
    static func existingSignature(
        of bytes: Data,
        parser: any MachOParsing = ReadOnlyMachOParser()
    ) -> ExistingSignature? {
        switch MachOCodeSignatureInspector(parser: parser).inspect(bytes: bytes) {
        case .thin(let inspection):
            switch inspection.existingSignature {
            case .absent: return .absent
            case .valid: return .present
            case .malformedCommand, .invalidRegionOffset, .invalidRegionSize, .malformedRegion:
                return .malformed
            default: return .unsupported
            }
        case .universal(let inspections):
            if inspections.contains(where: { inspection in
                if case .valid = inspection.existingSignature { return true }
                return false
            }) {
                return .present
            }
            return .absent
        case .malformedSignature(_, let state):
            switch state {
            case .absent: return .absent
            case .valid: return .present
            default: return .malformed
            }
        case .malformedMachO:
            return nil
        }
    }
}
