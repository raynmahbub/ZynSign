/// The result of structural examination of one imported package.
///
/// Both parts are reported together because they describe one outcome: the
/// bundle ZynSign established, and the findings behind the classification. A
/// `nil` bundle alongside a non-`valid` classification is the honest shape of
/// every rejecting examination; a bundle alongside a `valid` classification is
/// the only shape that permits later workflow stages.
struct IPAStructureInspection: Equatable, Hashable {

    /// The single application bundle examination established, or `nil` when
    /// examination found none or refused to choose between several.
    let bundle: ApplicationBundle?

    /// The structural findings and their classification.
    let validation: ValidationResult

    /// Whether examination established a bundle and passed every rule it
    /// checked. This is a structural statement only: it says nothing about
    /// signatures, entitlements, trust, or installability.
    var isValid: Bool {
        bundle != nil && validation.isValid
    }
}

/// Structural examination of an imported package's archive layout.
///
/// The validator is pure: it reads a container's entry table and produces
/// findings. It performs no I/O, opens nothing, and extracts nothing — an
/// ordinary package is classified without a single entry being written to a
/// filesystem or expanded in memory. Content-level examination (reading and
/// interpreting a bundle's information file, resolving its executable) belongs
/// to later stages that consume the same entry table through the
/// `ArchiveReader` boundary.
///
/// A `valid` classification means the archive structure satisfied the rules
/// checked here. It is never evidence that the package is signed, trusted, or
/// installable.
struct IPAStructureValidator {

    /// The greatest number of findings recorded for any one issue code.
    ///
    /// This bounds the size of a report, not the strictness of examination:
    /// a single violating entry already rejects the package, so itemising
    /// every further violation would only enlarge the diagnostic. A hostile
    /// container cannot inflate the report past this bound.
    static let maximumFindingsPerIssue = 8

    /// The resource policy applied while examining the entry table.
    let limits: ArchiveLimits

    /// Creates a validator with the given resource policy.
    init(limits: ArchiveLimits = .default) {
        self.limits = limits
    }

    /// Examines a container's entry table and reports what it establishes.
    func validate(entryTable: [ArchiveEntry]) -> IPAStructureInspection {
        var findings = FindingCollector(limit: Self.maximumFindingsPerIssue)

        examineEntryCount(entryTable.count, into: &findings)
        let kindsByPath = examineEntries(entryTable, into: &findings)
        let bundle = examineLayout(entryTable, kindsByPath: kindsByPath, into: &findings)

        let classification = Self.classification(for: findings.findings)
        return IPAStructureInspection(
            bundle: bundle,
            validation: ValidationResult(classification: classification, findings: findings.findings)
        )
    }

    /// The classification that follows a set of findings.
    ///
    /// Precedence is deliberate. Definitively broken structure is reported as
    /// `invalid` even when the same archive is also ambiguous or uses an
    /// unsupported feature, because that is the outcome the user can act on.
    /// Where nothing is broken, ambiguity outranks unsupported features: a
    /// choice ZynSign will not make is more specific than a capability it does
    /// not offer.
    static func classification(for findings: [ValidationFinding]) -> ValidationClassification {
        let errors = findings.filter { $0.severity == .error }
        if errors.isEmpty {
            return .valid
        }
        if errors.contains(where: { $0.category == .invalidInput }) {
            return .invalid
        }
        if errors.contains(where: { $0.category == .ambiguousInput }) {
            return .ambiguous
        }
        return .unsupported
    }

    // MARK: - Examination steps

    private func examineEntryCount(_ count: Int, into findings: inout FindingCollector) {
        guard count > limits.maximumEntryCount else { return }
        findings.add(
            severity: .error,
            code: .resourceLimitExceeded,
            detail: "The archive records \(count) entries, which exceeds the accepted maximum of \(limits.maximumEntryCount)."
        )
    }

    /// Examines each entry's own safety, kind, uniqueness, and declared sizes,
    /// and returns the recorded kind of each accepted path.
    private func examineEntries(
        _ entryTable: [ArchiveEntry],
        into findings: inout FindingCollector
    ) -> [ArchivePath: ArchiveEntryKind] {
        var kindsByPath: [ArchivePath: ArchiveEntryKind] = [:]
        var totalUncompressedBytes = 0

        for entry in entryTable {
            guard let path = entry.path else {
                findings.add(
                    severity: .error,
                    code: .unsafePath,
                    detail: "The archive records an entry named '\(entry.diagnosticName)' that is not a safe relative path."
                )
                continue
            }

            examineEntryPath(path, kind: entry.kind, into: &findings)

            if let recorded = kindsByPath[path] {
                findings.add(
                    severity: .error,
                    code: .conflictingPaths,
                    detail: recorded == entry.kind
                        ? "The archive records the entry '\(path)' more than once."
                        : "The archive records '\(path)' twice, once as \(recorded.displayName) and once as \(entry.kind.displayName).",
                    location: path
                )
            } else {
                kindsByPath[path] = entry.kind
            }

            totalUncompressedBytes += entry.uncompressedSize
            examineEntrySizes(entry, path: path, into: &findings)
        }

        if limits.exceedsTotalUncompressedBytes(totalUncompressedBytes) {
            findings.add(
                severity: .error,
                code: .resourceLimitExceeded,
                detail: "The archive declares \(totalUncompressedBytes) bytes of expanded content, which exceeds the accepted maximum of \(limits.maximumTotalUncompressedBytes)."
            )
        }

        return kindsByPath
    }

    private func examineEntryPath(
        _ path: ArchivePath,
        kind: ArchiveEntryKind,
        into findings: inout FindingCollector
    ) {
        let depth = path.components.count
        if depth > limits.maximumPathDepth {
            findings.add(
                severity: .error,
                code: .resourceLimitExceeded,
                detail: "The entry '\(path)' is nested \(depth) levels deep, which exceeds the accepted maximum of \(limits.maximumPathDepth).",
                location: path
            )
        }
        if !kind.isUsable {
            findings.add(
                severity: .error,
                code: .unsupportedArchiveFeature,
                detail: "The entry '\(path)' is \(kind.displayName), which ZynSign does not process.",
                location: path
            )
        }
    }

    private func examineEntrySizes(
        _ entry: ArchiveEntry,
        path: ArchivePath,
        into findings: inout FindingCollector
    ) {
        if limits.exceedsEntryBytes(entry.uncompressedSize) {
            findings.add(
                severity: .error,
                code: .resourceLimitExceeded,
                detail: "The entry '\(path)' declares \(entry.uncompressedSize) expanded bytes, which exceeds the accepted maximum of \(limits.maximumEntryBytes).",
                location: path
            )
        }
        if limits.exceedsCompressionRatio(
            uncompressedSize: entry.uncompressedSize,
            compressedSize: entry.compressedSize
        ) {
            findings.add(
                severity: .error,
                code: .resourceLimitExceeded,
                detail: "The entry '\(path)' declares an expansion ratio beyond the accepted maximum of \(limits.maximumCompressionRatio) to 1.",
                location: path
            )
        }
    }

    /// Examines the expected package layout and records the bundle it
    /// establishes, if any.
    private func examineLayout(
        _ entryTable: [ArchiveEntry],
        kindsByPath: [ArchivePath: ArchiveEntryKind],
        into findings: inout FindingCollector
    ) -> ApplicationBundle? {
        let discovery = ApplicationBundleDiscovery.discover(in: entryTable)

        if !discovery.payloadPresent {
            findings.add(
                severity: .error,
                code: .missingPayloadDirectory,
                detail: "The archive contains no top-level '\(IPALayout.payloadDirectoryName)' directory."
            )
        }

        var bundle: ApplicationBundle?

        switch discovery.outcome {
        case .missingPayloadDirectory:
            findings.add(
                severity: .error,
                code: .missingApplicationBundle,
                detail: discovery.bundleCandidates.isEmpty
                    ? "The archive contains no application bundle."
                    : "The archive contains no application bundle inside a top-level '\(IPALayout.payloadDirectoryName)' directory; application bundle directories were found at \(Self.pathList(discovery.bundleCandidates))."
            )

        case .none:
            findings.add(
                severity: .error,
                code: .missingApplicationBundle,
                detail: "The archive's payload directory contains no application bundle."
            )

        case .ambiguous(let candidates):
            findings.add(
                severity: .error,
                code: .multipleApplicationBundles,
                detail: "The archive contains \(candidates.count) application bundles: \(Self.pathList(candidates)). ZynSign examines a single application per package and does not choose between them."
            )

        case .exactlyOne(let bundlePath):
            examineBundleStructure(bundlePath, kindsByPath: kindsByPath, into: &findings)
            do {
                bundle = try ApplicationBundle(bundlePath: bundlePath)
            } catch {
                findings.add(
                    severity: .error,
                    code: .missingApplicationBundle,
                    detail: "The discovered path '\(bundlePath)' could not be recorded as an application bundle."
                )
            }
        }

        examineUnusualBundleLocations(discovery, chosen: bundle, into: &findings)
        return bundle
    }

    private func examineBundleStructure(
        _ bundlePath: ArchivePath,
        kindsByPath: [ArchivePath: ArchiveEntryKind],
        into findings: inout FindingCollector
    ) {
        guard let informationPath = IPALayout.bundleInformationPath(within: bundlePath) else {
            findings.add(
                severity: .error,
                code: .missingInfoPlist,
                detail: "The location of the bundle information file for '\(bundlePath)' is not a representable archive path.",
                location: nil
            )
            return
        }
        switch kindsByPath[informationPath] {
        case .none:
            findings.add(
                severity: .error,
                code: .missingInfoPlist,
                detail: "The application bundle at '\(bundlePath)' has no '\(IPALayout.bundleInformationFileName)'.",
                location: informationPath
            )
        case .some(let kind) where kind != .regularFile:
            findings.add(
                severity: .error,
                code: .missingInfoPlist,
                detail: "The bundle information file at '\(informationPath)' is \(kind.displayName) rather than a regular file.",
                location: informationPath
            )
        case .some:
            break
        }
    }

    private func examineUnusualBundleLocations(
        _ discovery: ApplicationBundleDiscovery,
        chosen bundle: ApplicationBundle?,
        into findings: inout FindingCollector
    ) {
        for path in discovery.misplacedBundleDirectories {
            if let bundle = bundle, path.isWithin(bundle.bundlePath) {
                continue
            }
            findings.add(
                severity: .warning,
                code: .inconsistentMetadata,
                detail: "An application bundle directory was found at '\(path)', outside the examined application bundle.",
                location: path
            )
        }
        for path in discovery.nonDirectoryApplicationNames {
            findings.add(
                severity: .warning,
                code: .inconsistentMetadata,
                detail: "'\(path)' carries an application bundle name but is not a directory.",
                location: path
            )
        }
    }

    private static func pathList(_ paths: [ArchivePath]) -> String {
        paths.map { "'\($0.rawValue)'" }.joined(separator: ", ")
    }
}

/// An accumulator that records findings while bounding how many are kept for
/// any one issue code.
fileprivate struct FindingCollector {

    let limit: Int

    fileprivate(set) var findings: [ValidationFinding] = []
    fileprivate var countsByCode: [ValidationIssueCode: Int] = [:]

    mutating func add(
        severity: ValidationSeverity,
        code: ValidationIssueCode,
        detail: String,
        location: ArchivePath? = nil
    ) {
        let recorded = countsByCode[code] ?? 0
        guard recorded < limit else { return }
        countsByCode[code] = recorded + 1
        findings.append(
            ValidationFinding(severity: severity, code: code, detail: detail, location: location)
        )
    }
}
