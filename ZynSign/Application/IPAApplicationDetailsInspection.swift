import Foundation
import CoreFoundation

/// Read-only, bounded inspection for the App Details screen.
///
/// The use case re-reads the same archive boundary used during import, then
/// combines the established structural validator, metadata reader, bundle
/// tree, and a bounded Mach-O parse of the declared main executable. It does
/// not extract files, mutate the package, verify a code signature, evaluate
/// certificate trust, or decide whether a profile authorizes installation.
struct IPAApplicationDetailsInspection {

    /// The greatest number of extension Info.plists inspected in one pass.
    /// A package may contain more extensions; the remainder stay visible in
    /// the bundle tree and are called out as not inspected.
    static let maximumExtensionMetadataReads = 64

    private static let maximumInfoPlistRows = 500
    private static let maximumInfoPlistValueLength = 240

    private let library: ApplicationLibrary
    private let readerProvider: any ArtifactArchiveReaderProvider
    private let limits: ArchiveLimits
    private let maximumExecutableReadBytes: Int
    private let maximumExtensionMetadataReads: Int
    private let machOInspection: MachOInspection

    /// Creates the inspector with the library, archive boundary, and bounded
    /// read policies chosen by the composition root.
    init(
        library: ApplicationLibrary,
        readerProvider: any ArtifactArchiveReaderProvider,
        limits: ArchiveLimits = .default,
        maximumExecutableReadBytes: Int = 32 * 1_024 * 1_024,
        maximumExtensionMetadataReads: Int = Self.maximumExtensionMetadataReads,
        machOInspection: MachOInspection = MachOInspection()
    ) {
        self.library = library
        self.readerProvider = readerProvider
        self.limits = limits
        self.maximumExecutableReadBytes = max(0, maximumExecutableReadBytes)
        self.maximumExtensionMetadataReads = max(0, maximumExtensionMetadataReads)
        self.machOInspection = machOInspection
    }

    /// Produces an inspection report for the application record `id`.
    ///
    /// Only the bundle's Info.plist, a bounded number of extension Info.plists,
    /// and a main executable below the explicit inspection limit are read.
    /// Every read remains inside the archive reader's configured policy.
    func inspect(recordWithID id: ApplicationRecordIdentifier) async throws -> ApplicationDetailsInspectionReport {
        do {
            try Task.checkCancellation()

            guard let entry = try await library.entry(withID: id) else {
                throw ZynSignError.libraryRecordNotFound(
                    diagnosticDetail: "No record '\(id.rawValue)' exists to inspect."
                )
            }
            switch entry.artifactAvailability {
            case .available:
                break
            case .missing:
                throw ZynSignError.bundleArtifactMissing(
                    diagnosticDetail: "The library holds no artifact '\(entry.record.artifact.artifactID.rawValue)' for record '\(id.rawValue)'."
                )
            case .inconsistent(let recorded, let observed):
                throw ZynSignError.bundleArtifactInconsistent(
                    diagnosticDetail: "Artifact '\(entry.record.artifact.artifactID.rawValue)' holds \(observed) bytes; record '\(id.rawValue)' expects \(recorded)."
                )
            }

            let record = entry.record
            let reader = try readerProvider.archiveReader(for: record.artifact.artifactID)
            defer { reader.close() }

            let table = try reader.readEntryTable()
            try Task.checkCancellation()

            let structure = IPAStructureValidator(limits: limits).validate(entryTable: table)
            var validationFindings = structure.validation.findings
            var extraDiagnostics: [ApplicationInspectionDiagnostic] = []
            var metadata: ApplicationMetadata?
            var infoPlistEntries: [InfoPlistKeyValue] = []
            var omittedInfoPlistEntryCount = 0
            var bundleType: String?
            var supportedPlatforms: [String] = []
            var omittedSupportedPlatformCount = 0
            var bundleContents: BundleContents?
            var components = ApplicationBundleComponentSummary.empty
            var executableInspection: MainExecutableInspection?

            if let bundle = structure.bundle {
                let informationPath = IPALayout.bundleInformationPath(within: bundle.bundlePath)
                var infoPlistData: Data?

                if let informationPath {
                    switch Self.recordedKind(of: informationPath, in: table) {
                    case .some(.regularFile):
                        do {
                            infoPlistData = try reader.readEntryData(
                                at: informationPath,
                                maximumBytes: limits.maximumInspectionReadBytes
                            )
                        } catch {
                            validationFindings.append(ValidationFinding(
                                severity: .error,
                                code: .unreadableInfoPlist,
                                detail: "The bundle information file could not be read within the inspection policy.",
                                location: informationPath
                            ))
                        }
                    case .none, .some(_):
                        // The structural validator already records a missing
                        // or wrongly typed Info.plist finding.
                        break
                    }
                } else {
                    validationFindings.append(ValidationFinding(
                        severity: .error,
                        code: .missingInfoPlist,
                        detail: "The bundle information file has no safe location inside the application bundle."
                    ))
                }

                if let infoPlistData {
                    let examination = ApplicationMetadataReader.read(from: infoPlistData)
                    metadata = examination.metadata
                    validationFindings.append(contentsOf: examination.findings.map {
                        ValidationFinding(
                            severity: $0.severity,
                            code: $0.code,
                            detail: $0.detail,
                            location: informationPath
                        )
                    })

                    let snapshot = Self.propertyListSnapshot(from: infoPlistData)
                    infoPlistEntries = snapshot?.entries ?? []
                    omittedInfoPlistEntryCount = snapshot?.omittedEntryCount ?? 0
                    bundleType = snapshot?.bundleType
                    supportedPlatforms = snapshot?.supportedPlatforms ?? []
                    omittedSupportedPlatformCount = snapshot?.omittedSupportedPlatformCount ?? 0
                }

                let declaredExecutableName = metadata?.executableName ?? record.executableName
                let contents = BundleContents(
                    entryTable: table,
                    bundlePath: bundle.bundlePath,
                    declaredExecutableName: declaredExecutableName
                )
                bundleContents = contents

                if let metadata, metadata.identity != record.identity {
                    extraDiagnostics.append(ApplicationInspectionDiagnostic(
                        code: "record.metadata-mismatch",
                        title: "Library metadata differs from the archive",
                        detail: "The current Info.plist declarations do not match the identity saved when this package entered the library.",
                        severity: .error
                    ))
                    validationFindings.append(ValidationFinding(
                        severity: .error,
                        code: .inconsistentMetadata,
                        detail: "The application identity read from Info.plist does not match the identity captured by the library record."
                    ))
                }

                let componentInspection = inspectComponents(
                    in: contents,
                    bundlePath: bundle.bundlePath,
                    table: table,
                    reader: reader
                )
                components = componentInspection.summary
                extraDiagnostics.append(contentsOf: componentInspection.diagnostics)

                let executableResult = inspectMainExecutable(
                    named: declaredExecutableName,
                    bundlePath: bundle.bundlePath,
                    bundleContents: contents,
                    reader: reader
                )
                executableInspection = executableResult.inspection
                extraDiagnostics.append(contentsOf: executableResult.diagnostics)
                if executableResult.inspection.signatureState == .notInspected(.missingExecutable) {
                    validationFindings.append(ValidationFinding(
                        severity: .error,
                        code: .missingExecutable,
                        detail: "The bundle's declared main executable is absent or is not a regular file."
                    ))
                }

            } else if structure.validation.findings.isEmpty {
                validationFindings.append(ValidationFinding(
                    severity: .error,
                    code: .missingApplicationBundle,
                    detail: "No application bundle was established inside the package payload."
                ))
            }

            try Task.checkCancellation()

            let classification = IPAStructureValidator.classification(for: validationFindings)
            var diagnostics = validationFindings.map(Self.diagnostic(for:))
            diagnostics.append(contentsOf: extraDiagnostics)
            if classification == .valid,
               !diagnostics.contains(where: { $0.severity == .error || $0.severity == .unsupported }) {
                diagnostics.insert(ApplicationInspectionDiagnostic(
                    code: "inspection.valid",
                    title: "Inspection passed",
                    detail: "The archive structure and required application metadata passed ZynSign's read-only inspection.",
                    severity: .success
                ), at: 0)
            }

            return ApplicationDetailsInspectionReport(
                bundlePath: structure.bundle?.bundlePath,
                bundleContents: bundleContents,
                metadata: metadata,
                infoPlistEntries: infoPlistEntries,
                omittedInfoPlistEntryCount: omittedInfoPlistEntryCount,
                bundleType: bundleType,
                supportedPlatforms: supportedPlatforms,
                omittedSupportedPlatformCount: omittedSupportedPlatformCount,
                archive: Self.archiveSummary(for: table),
                components: components,
                executable: executableInspection,
                validationClassification: classification,
                diagnostics: diagnostics
            )
        } catch {
            throw Self.normalized(error)
        }
    }

    // MARK: - Executable and architecture inspection

    private func inspectMainExecutable(
        named name: String?,
        bundlePath: ArchivePath,
        bundleContents: BundleContents,
        reader: any ArchiveReader
    ) -> (inspection: MainExecutableInspection, diagnostics: [ApplicationInspectionDiagnostic]) {
        guard let name, let path = bundlePath.appending(component: name),
              let relativePath = BundlePath(path, relativeTo: bundlePath),
              let entry = bundleContents.entry(at: relativePath),
              entry.kind == .regularFile else {
            let inspection = MainExecutableInspection(
                signatureState: .notInspected(.missingExecutable),
                architectureNames: [],
                unsupportedArchitectureNames: [],
                hasDeviceArchitecture: false
            )
            return (inspection, [ApplicationInspectionDiagnostic(
                code: ValidationIssueCode.missingExecutable.rawValue,
                title: "Missing executable",
                detail: name.map { "The declared executable '\($0)' is missing or is not a regular file inside the app bundle." }
                    ?? "The app's Info.plist does not declare CFBundleExecutable.",
                severity: .error
            )])
        }

        guard let declaredSize = entry.declaredByteCount else {
            let inspection = MainExecutableInspection(
                signatureState: .notInspected(.missingExecutable),
                architectureNames: [],
                unsupportedArchitectureNames: [],
                hasDeviceArchitecture: false
            )
            return (inspection, [ApplicationInspectionDiagnostic(
                code: ValidationIssueCode.missingExecutable.rawValue,
                title: "Missing executable",
                detail: "The declared executable has no regular-file size in the bundle entry table.",
                severity: .error
            )])
        }
        guard declaredSize > 0 else {
            let inspection = MainExecutableInspection(
                signatureState: .notInspected(.unreadable),
                architectureNames: [],
                unsupportedArchitectureNames: [],
                hasDeviceArchitecture: false
            )
            return (inspection, [ApplicationInspectionDiagnostic(
                code: "executable.empty",
                title: "Executable is empty",
                detail: "The declared main executable has no bytes to inspect.",
                severity: .error
            )])
        }
        guard declaredSize <= maximumExecutableReadBytes else {
            let inspection = MainExecutableInspection(
                signatureState: .notInspected(.exceedsReadLimit),
                architectureNames: [],
                unsupportedArchitectureNames: [],
                hasDeviceArchitecture: false
            )
            return (inspection, [ApplicationInspectionDiagnostic(
                code: "executable.read-limit",
                title: "Executable inspection limit reached",
                detail: "The main executable was not loaded because it exceeds the \(ByteCountFormatter.string(fromByteCount: Int64(maximumExecutableReadBytes), countStyle: .file)) read limit.",
                severity: .unsupported
            )])
        }

        let archivePath = path
        let bytes: Data
        do {
            bytes = try reader.readEntryData(at: archivePath, maximumBytes: maximumExecutableReadBytes)
        } catch {
            let inspection = MainExecutableInspection(
                signatureState: .notInspected(.unreadable),
                architectureNames: [],
                unsupportedArchitectureNames: [],
                hasDeviceArchitecture: false
            )
            return (inspection, [ApplicationInspectionDiagnostic(
                code: "executable.unreadable",
                title: "Executable could not be read",
                detail: "The bounded archive reader refused the declared executable; no signature conclusion was reached.",
                severity: .error
            )])
        }

        let image: MachOImage
        do {
            image = try machOInspection.inspect(bytes: bytes)
        } catch let error as MachOParsingError {
            if MachOExistingCodeSignatureState.classify(error) != nil {
                let inspection = MainExecutableInspection(
                    signatureState: .malformed,
                    architectureNames: [],
                    unsupportedArchitectureNames: [],
                    hasDeviceArchitecture: false
                )
                return (inspection, [ApplicationInspectionDiagnostic(
                    code: "signature.malformed",
                    title: "Malformed signature structure",
                    detail: "The executable declares signature data that the bounded Mach-O parser could not interpret safely.",
                    severity: .error
                )])
            }
            let reason: MainExecutableInspectionLimit = error.reason == .unsupportedFormat
                ? .notMachO
                : .malformedMachO
            let inspection = MainExecutableInspection(
                signatureState: .notInspected(reason),
                architectureNames: [],
                unsupportedArchitectureNames: [],
                hasDeviceArchitecture: false
            )
            let severity: ApplicationInspectionDiagnosticSeverity = error.reason == .unsupportedFormat ? .unsupported : .error
            return (inspection, [ApplicationInspectionDiagnostic(
                code: "executable.invalid-macho",
                title: error.reason == .unsupportedFormat ? "Unsupported executable format" : "Malformed executable",
                detail: reason.explanation,
                severity: severity
            )])
        } catch {
            let inspection = MainExecutableInspection(
                signatureState: .notInspected(.malformedMachO),
                architectureNames: [],
                unsupportedArchitectureNames: [],
                hasDeviceArchitecture: false
            )
            return (inspection, [ApplicationInspectionDiagnostic(
                code: "executable.invalid-macho",
                title: "Malformed executable",
                detail: MainExecutableInspectionLimit.malformedMachO.explanation,
                severity: .error
            )])
        }

        let slices = image.slices
        let signedCount = slices.filter { $0.embeddedSignature != nil }.count
        let state: MainExecutableSignatureState
        if signedCount == 0 {
            state = .unsigned
        } else if signedCount == slices.count {
            state = .signed
        } else {
            state = .partiallySigned
        }

        let architectureNames = slices.map { Self.architectureName(for: $0.header.cpu) }
        let deviceArchitectures = slices.filter {
            switch $0.header.cpu {
            case .arm, .arm64: return true
            case .x86, .x86_64, .other: return false
            }
        }
        let unsupportedArchitectures = slices.compactMap { slice -> String? in
            switch slice.header.cpu {
            case .arm, .arm64: return nil
            case .x86, .x86_64, .other: return Self.architectureName(for: slice.header.cpu)
            }
        }
        let inspection = MainExecutableInspection(
            signatureState: state,
            architectureNames: architectureNames,
            unsupportedArchitectureNames: unsupportedArchitectures,
            hasDeviceArchitecture: !deviceArchitectures.isEmpty
        )

        var diagnostics: [ApplicationInspectionDiagnostic] = []
        if state == .partiallySigned {
            diagnostics.append(ApplicationInspectionDiagnostic(
                code: "signature.partial",
                title: "Partially signed executable",
                detail: "Some Mach-O architecture slices contain signature structures and others do not.",
                severity: .warning
            ))
        }
        if !inspection.hasDeviceArchitecture {
            diagnostics.append(ApplicationInspectionDiagnostic(
                code: "architecture.unsupported",
                title: "Unsupported architecture",
                detail: architectureNames.isEmpty
                    ? "No executable architecture could be established."
                    : "The executable contains \(architectureNames.joined(separator: ", ")) but no ARM device architecture was found. Device compatibility is not established.",
                severity: .unsupported
            ))
        }
        return (inspection, diagnostics)
    }

    // MARK: - Nested bundle summaries

    private func inspectComponents(
        in contents: BundleContents,
        bundlePath: ArchivePath,
        table: [ArchiveEntry],
        reader: any ArchiveReader
    ) -> (summary: ApplicationBundleComponentSummary, diagnostics: [ApplicationInspectionDiagnostic]) {
        let allEntries = contents.allEntries
        let frameworks = allEntries.compactMap { entry -> ApplicationBundleComponent? in
            guard entry.isDirectory else { return nil }
            let lowered = entry.name.lowercased()
            guard lowered.hasSuffix(".framework") || lowered.hasSuffix(".xcframework") else { return nil }
            return ApplicationBundleComponent(path: entry.path, kind: .framework, extensionPointIdentifier: nil)
        }
        let dynamicLibraries = allEntries.compactMap { entry -> ApplicationBundleComponent? in
            guard entry.kind == .regularFile, entry.name.lowercased().hasSuffix(".dylib") else { return nil }
            return ApplicationBundleComponent(path: entry.path, kind: .dynamicLibrary, extensionPointIdentifier: nil)
        }
        let extensionPaths = allEntries
            .filter { $0.isDirectory && $0.name.lowercased().hasSuffix(".appex") }
            .map(\.path)
        let nestedApplications = allEntries.compactMap { entry -> ApplicationBundleComponent? in
            guard entry.isDirectory, entry.name.lowercased().hasSuffix(".app") else { return nil }
            return ApplicationBundleComponent(path: entry.path, kind: .nestedApplication, extensionPointIdentifier: nil)
        }

        var extensionPoints: [BundlePath: String] = [:]
        var diagnostics: [ApplicationInspectionDiagnostic] = []
        let pathsToInspect = Array(extensionPaths.prefix(maximumExtensionMetadataReads))

        for extensionPath in pathsToInspect {
            guard let infoPath = ArchivePath(rawValue: "\(bundlePath.rawValue)/\(extensionPath.rawValue)/Info.plist"),
                  let infoEntry = table.first(where: { $0.path == infoPath && $0.kind == .regularFile }) else {
                diagnostics.append(ApplicationInspectionDiagnostic(
                    code: "extension.info-plist-missing",
                    title: "Extension metadata missing",
                    detail: "\(extensionPath.rawValue) has no readable Info.plist entry.",
                    severity: .warning
                ))
                continue
            }
            guard infoEntry.uncompressedSize <= limits.maximumInspectionReadBytes else {
                diagnostics.append(ApplicationInspectionDiagnostic(
                    code: "extension.info-plist-limit",
                    title: "Extension metadata exceeds the read limit",
                    detail: "\(extensionPath.rawValue)/Info.plist was not opened because it exceeds the bounded metadata read.",
                    severity: .unsupported
                ))
                continue
            }
            do {
                let data = try reader.readEntryData(at: infoPath, maximumBytes: limits.maximumInspectionReadBytes)
                guard let dictionary = Self.propertyListDictionary(from: data) else {
                    diagnostics.append(ApplicationInspectionDiagnostic(
                        code: "extension.info-plist-malformed",
                        title: "Extension metadata malformed",
                        detail: "\(extensionPath.rawValue)/Info.plist is not a readable property-list dictionary.",
                        severity: .warning
                    ))
                    continue
                }
                if let point = Self.extensionPointIdentifier(in: dictionary) {
                    extensionPoints[extensionPath] = point
                } else {
                    diagnostics.append(ApplicationInspectionDiagnostic(
                        code: "extension.point-missing",
                        title: "Extension point not declared",
                        detail: "\(extensionPath.rawValue) does not declare an NSExtensionPointIdentifier; widget classification is unavailable.",
                        severity: .warning
                    ))
                }
            } catch {
                diagnostics.append(ApplicationInspectionDiagnostic(
                    code: "extension.info-plist-unreadable",
                    title: "Extension metadata unreadable",
                    detail: "\(extensionPath.rawValue)/Info.plist could not be read within the archive inspection policy.",
                    severity: .warning
                ))
            }
        }

        let uninspectedCount = max(0, extensionPaths.count - pathsToInspect.count)
        if uninspectedCount > 0 {
            diagnostics.append(ApplicationInspectionDiagnostic(
                code: "extension.inspection-limit",
                title: "Some extension metadata was not inspected",
                detail: "\(uninspectedCount) additional extension bundle(s) remain visible in the bundle tree but were not opened; ZynSign inspects at most \(maximumExtensionMetadataReads) extension Info.plists per pass.",
                severity: .unsupported
            ))
        }

        let appExtensions = extensionPaths.map { path in
            ApplicationBundleComponent(
                path: path,
                kind: .appExtension,
                extensionPointIdentifier: extensionPoints[path]
            )
        }
        return (
            ApplicationBundleComponentSummary(
                frameworks: frameworks,
                dynamicLibraries: dynamicLibraries,
                appExtensions: appExtensions,
                nestedApplications: nestedApplications,
                uninspectedExtensionCount: uninspectedCount
            ),
            diagnostics
        )
    }

    // MARK: - Property-list snapshot

    private static func propertyListSnapshot(from data: Data) -> PropertyListSnapshot? {
        guard let dictionary = propertyListDictionary(from: data) else { return nil }

        let keys = dictionary.keys.sorted()
        let entries = keys.prefix(maximumInfoPlistRows).compactMap { key -> InfoPlistKeyValue? in
            guard let value = dictionary[key] else { return nil }
            return InfoPlistKeyValue(
                key: safeText(key, limit: 128),
                valueDescription: formattedPropertyListValue(value, depth: 0)
            )
        }
        let rawPlatformValues = dictionary["CFBundleSupportedPlatforms"] as? [Any] ?? []
        var supportedPlatforms: [String] = []
        var supportedPlatformCount = 0
        for value in rawPlatformValues {
            guard let platform = value as? String else { continue }
            supportedPlatformCount += 1
            if supportedPlatforms.count < 32 {
                supportedPlatforms.append(safeText(platform, limit: 80))
            }
        }

        return PropertyListSnapshot(
            entries: entries,
            omittedEntryCount: max(0, keys.count - entries.count),
            bundleType: (dictionary["CFBundlePackageType"] as? String).map { safeText($0, limit: 80) },
            supportedPlatforms: supportedPlatforms,
            omittedSupportedPlatformCount: max(0, supportedPlatformCount - supportedPlatforms.count)
        )
    }

    private static func propertyListDictionary(from data: Data) -> [String: Any]? {
        var format = PropertyListSerialization.PropertyListFormat.openStep
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) else {
            return nil
        }
        return root as? [String: Any]
    }

    private static func extensionPointIdentifier(in dictionary: [String: Any]) -> String? {
        guard let extensionDictionary = dictionary["NSExtension"] as? [String: Any],
              let identifier = extensionDictionary["NSExtensionPointIdentifier"] as? String,
              !identifier.isEmpty else {
            return nil
        }
        return safeText(identifier, limit: 120)
    }

    private static func formattedPropertyListValue(_ value: Any, depth: Int) -> String {
        if let string = value as? String {
            return safeText(string, limit: maximumInfoPlistValueLength)
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return safeText(number.stringValue, limit: maximumInfoPlistValueLength)
        }
        if let date = value as? Date {
            return safeText(ISO8601DateFormatter().string(from: date), limit: maximumInfoPlistValueLength)
        }
        if let data = value as? Data {
            return "<data: \(data.count) bytes>"
        }
        if let array = value as? [Any] {
            guard depth < 2 else { return "[\(array.count) items]" }
            let parts = array.prefix(6).map { formattedPropertyListValue($0, depth: depth + 1) }
            let suffix = array.count > parts.count ? ", …" : ""
            return "[\(parts.joined(separator: ", "))\(suffix)]"
        }
        if let dictionary = value as? [String: Any] {
            guard depth < 2 else { return "{\(dictionary.count) keys}" }
            let keys = dictionary.keys.sorted()
            let parts = keys.prefix(6).compactMap { key -> String? in
                guard let nestedValue = dictionary[key] else { return nil }
                return "\(safeText(key, limit: 80)): \(formattedPropertyListValue(nestedValue, depth: depth + 1))"
            }
            let suffix = keys.count > parts.count ? ", …" : ""
            return "{\(parts.joined(separator: ", "))\(suffix)}"
        }
        return "<unsupported property-list value>"
    }

    private static func safeText(_ value: String, limit: Int) -> String {
        let sanitized = String(value.map { $0.isControl ? "\u{FFFD}" : $0 })
        guard sanitized.count > limit else { return sanitized }
        return String(sanitized.prefix(max(0, limit - 1))) + "…"
    }

    // MARK: - Summaries and diagnostics

    private static func archiveSummary(for table: [ArchiveEntry]) -> ArchiveCompressionSummary {
        ArchiveCompressionSummary(
            entryCount: table.count,
            compressedByteCount: saturatedSum(table.map(\.compressedSize)),
            uncompressedByteCount: saturatedSum(table.map(\.uncompressedSize))
        )
    }

    private static func saturatedSum(_ values: [Int]) -> Int {
        values.reduce(0) { total, value in
            let (sum, overflow) = total.addingReportingOverflow(max(0, value))
            return overflow ? Int.max : sum
        }
    }

    private static func recordedKind(of path: ArchivePath, in table: [ArchiveEntry]) -> ArchiveEntryKind? {
        table.first(where: { $0.path == path })?.kind
    }

    private static func architectureName(for cpu: MachOCPU) -> String {
        switch cpu {
        case .arm: return "ARM"
        case .arm64: return "ARM64"
        case .x86: return "x86"
        case .x86_64: return "x86_64"
        case .other(let value): return "CPU \(value)"
        }
    }

    private static func diagnostic(for finding: ValidationFinding) -> ApplicationInspectionDiagnostic {
        let severity: ApplicationInspectionDiagnosticSeverity
        if finding.severity == .warning {
            severity = .warning
        } else if finding.category == .unsupportedInput {
            severity = .unsupported
        } else {
            severity = .error
        }
        return ApplicationInspectionDiagnostic(
            code: finding.code.rawValue,
            title: diagnosticTitle(for: finding.code),
            detail: safeText(finding.detail, limit: 500),
            severity: severity
        )
    }

    private static func diagnosticTitle(for code: ValidationIssueCode) -> String {
        switch code {
        case .unreadableArchive: return "Archive could not be read"
        case .unsafePath: return "Unsafe archive path"
        case .conflictingPaths: return "Conflicting bundle paths"
        case .missingPayloadDirectory: return "Payload directory missing"
        case .missingApplicationBundle: return "Invalid bundle structure"
        case .multipleApplicationBundles: return "Multiple application bundles"
        case .missingInfoPlist: return "Info.plist missing"
        case .unreadableInfoPlist: return "Info.plist unreadable"
        case .malformedMetadata: return "Malformed metadata"
        case .missingRequiredMetadata: return "Required metadata missing"
        case .unsupportedMetadataFormat: return "Unsupported metadata format"
        case .inconsistentMetadata: return "Inconsistent metadata"
        case .missingExecutable: return "Missing executable"
        case .unsupportedArchiveFeature: return "Unsupported archive feature"
        case .resourceLimitExceeded: return "Inspection resource limit reached"
        }
    }

    private static func normalized(_ error: any Error) -> any Error {
        if error is ZynSignError || error is CancellationError {
            return error
        }
        return ZynSignError.bundleInspectionFailure(
            diagnosticDetail: "App details inspection failed with \(String(describing: type(of: error))).",
            underlyingError: error
        )
    }

    private struct PropertyListSnapshot {
        let entries: [InfoPlistKeyValue]
        let omittedEntryCount: Int
        let bundleType: String?
        let supportedPlatforms: [String]
        let omittedSupportedPlatformCount: Int
    }
}
