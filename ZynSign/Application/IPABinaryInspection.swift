import Foundation

/// The bounds binary inspection works within, chosen by the composition root.
struct BinaryInspectionLimits: Equatable {

    /// The largest executable read for inspection. The default matches the
    /// bounded Mach-O parser's own input ceiling, so nothing is read that the
    /// parser would then refuse.
    let maximumExecutableBytes: Int

    /// The most nested executables inspected in one pass.
    let maximumNestedTargets: Int

    /// The largest nested Info.plist read to learn an executable's name.
    let maximumBundleInformationBytes: Int

    /// The largest resource seal (`CodeResources`) read.
    let maximumResourceSealBytes: Int

    /// The largest single sealed file re-hashed on demand.
    let maximumSealedFileBytes: Int

    static let `default` = BinaryInspectionLimits(
        maximumExecutableBytes: 256 * 1_024 * 1_024,
        maximumNestedTargets: 128,
        maximumBundleInformationBytes: 1 * 1_024 * 1_024,
        maximumResourceSealBytes: 16 * 1_024 * 1_024,
        maximumSealedFileBytes: 256 * 1_024 * 1_024
    )
}

/// Where the executables being inspected come from.
enum BinaryInspectionSource: Equatable, Hashable {
    /// A package the library holds, by record.
    case libraryRecord(ApplicationRecordIdentifier)
    /// A signed package ZynSign wrote to `Documents/Signed`.
    case signedPackage(URL)
}

/// One step of a bundle inspection, delivered as it happens so the interface
/// can show structure before verification finishes.
enum BinaryInspectionEvent: Equatable {
    /// The bundle's executables were found.
    case discovered(BinaryBundleOverview)
    /// ZynSign began reading one executable.
    case targetStarted(targetID: String)
    /// The executable's structure is known; verification is running.
    case structureReady(BinaryInspectionReport)
    /// Pages hashed so far, of the total.
    case verificationProgress(targetID: String, completed: Int, total: Int)
    /// Structure and verification are complete.
    case completed(BinaryInspectionReport)
    /// The executable could not be inspected.
    case unavailable(targetID: String, limitation: BinaryTargetLimitation)
}

/// The result of inspecting one target outside a bundle pass.
enum BinaryTargetOutcome: Equatable {
    case inspected(BinaryInspectionReport)
    case unavailable(BinaryTarget, BinaryTargetLimitation)
    /// The package holds no executable matching the requested target.
    case notFound
}

/// A package the interface can compare the current one with.
struct BinaryComparisonCandidate: Equatable, Identifiable {
    enum Kind: String, Equatable {
        case libraryRecord
        case signedPackage
    }

    let kind: Kind
    let source: BinaryInspectionSource
    let name: String
    let bundleIdentifier: String?
    let version: String?
    let date: Date?
    let byteCount: Int?

    var id: String {
        switch source {
        case .libraryRecord(let id): return "record:\(id.rawValue)"
        case .signedPackage(let url): return "signed:\(url.lastPathComponent)"
        }
    }
}

/// The Binary & Signature Inspector use case.
///
/// It opens one package through the existing archive boundary, finds the
/// executables in its application bundle, and for each one — the main
/// executable first — reads the executable within an explicit bound, parses
/// it with the bounded Mach-O parser, decodes its load commands, summarises
/// its code signature, and then verifies that signature on this device.
/// Results stream out as they are established: structure first, verification
/// after, so a large executable is readable while its pages are still being
/// hashed.
///
/// Four properties are deliberate.
///
/// **It is read-only.** Nothing is extracted to a filesystem, nothing is
/// written into the package or the library, and no signature is changed.
///
/// **It is bounded.** Executables above `maximumExecutableBytes` are not read
/// and are reported as not inspected; nested bundles beyond
/// `maximumNestedTargets` are counted, not read. One executable's bytes are
/// held at a time and released before the next is read.
///
/// **It concludes only what it checked.** Verification re-computes hashes and
/// checks the CMS signature's mathematics; certificate trust, provisioning,
/// and installability are never evaluated, and a check that could not be
/// completed says why.
///
/// **It fails with typed errors.** A record that is gone, a package that is
/// missing or changed, or a container with no single application bundle
/// reaches the caller as a `ZynSignError`; anything else is normalised into
/// one.
struct IPABinaryInspection {

    private let library: ApplicationLibrary
    private let readerProvider: any ArtifactArchiveReaderProvider
    private let makePackageReader: (URL) -> any ArchiveReader
    private let signedPackagesDirectory: URL?
    private let parser: any MachOParsing
    private let decoder: any MachOLoadCommandDecoding
    private let verifier: BinarySignatureVerifier
    private let digest: any MessageDigest
    private let limits: BinaryInspectionLimits
    private let now: () -> Date

    init(
        library: ApplicationLibrary,
        readerProvider: any ArtifactArchiveReaderProvider,
        makePackageReader: @escaping (URL) -> any ArchiveReader,
        signedPackagesDirectory: URL?,
        parser: any MachOParsing,
        decoder: any MachOLoadCommandDecoding,
        verifier: BinarySignatureVerifier,
        digest: any MessageDigest,
        limits: BinaryInspectionLimits = .default,
        now: @escaping () -> Date = { Date() }
    ) {
        self.library = library
        self.readerProvider = readerProvider
        self.makePackageReader = makePackageReader
        self.signedPackagesDirectory = signedPackagesDirectory
        self.parser = parser
        self.decoder = decoder
        self.verifier = verifier
        self.digest = digest
        self.limits = limits
        self.now = now
    }

    // MARK: - Bundle pass

    /// Inspects every executable of the package `source` names.
    ///
    /// The stream delivers `discovered` once, then for each target
    /// `targetStarted`, `structureReady`, any number of
    /// `verificationProgress`, and `completed` — or `unavailable`. It finishes
    /// after the last target, or throws a typed error when the package cannot
    /// be opened. Ending the iteration cancels the work, and the reader is
    /// closed on every path.
    func inspectBundle(_ source: BinaryInspectionSource) -> AsyncThrowingStream<BinaryInspectionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await self.runBundlePass(source) { event in
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.normalized(error))
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func runBundlePass(
        _ source: BinaryInspectionSource,
        emit: @escaping (BinaryInspectionEvent) -> Void
    ) async throws {
        let package = try await open(source)
        defer { package.reader.close() }
        try Task.checkCancellation()

        emit(.discovered(package.overview))
        for target in package.overview.targets {
            try Task.checkCancellation()
            emit(.targetStarted(targetID: target.id))
            switch try inspect(target, in: package, emit: emit) {
            case .inspected:
                break
            case .unavailable(_, let limitation):
                emit(.unavailable(targetID: target.id, limitation: limitation))
            case .notFound:
                emit(.unavailable(targetID: target.id, limitation: .missingExecutable))
            }
        }
    }

    // MARK: - Single target

    /// Inspects, in the package `source` names, the executable that
    /// corresponds to `target`: the main executable for a main executable,
    /// otherwise the executable at the same location. Used for comparison.
    func inspectTarget(matching target: BinaryTarget, in source: BinaryInspectionSource) async throws -> BinaryTargetOutcome {
        do {
            let package = try await open(source)
            defer { package.reader.close() }
            let match: BinaryTarget?
            if target.kind == .mainExecutable {
                match = package.overview.mainTarget
            } else {
                match = package.overview.targets.first { $0.executablePath == target.executablePath }
            }
            guard let match else { return .notFound }
            return try inspect(match, in: package, emit: { _ in })
        } catch {
            throw Self.normalized(error)
        }
    }

    // MARK: - Sealed resources

    /// Re-hashes every file the resource seal of `target`'s bundle lists and
    /// compares each with its recorded SHA-256.
    ///
    /// Symbolic links, nested code (verified as its own executable), unsafe
    /// paths, and entries without a SHA-256 digest are counted as skipped.
    /// Files above `maximumSealedFileBytes` are reported as unreadable rather
    /// than read. Files the bundle holds but the seal omits are not detected:
    /// that requires evaluating the seal's rules, which ZynSign does not do.
    func verifySealedResources(of target: BinaryTarget, in source: BinaryInspectionSource) async throws -> SealedResourceVerification {
        do {
            let package = try await open(source)
            defer { package.reader.close() }
            guard let container = target.containerPath,
                  let sealPath = container.appending(component: "_CodeSignature").flatMap({ $0.appending(component: "CodeResources") }),
                  case .available(let sealData) = readBundleFile(sealPath, in: package, limit: limits.maximumResourceSealBytes),
                  let manifest = SealedResourceManifest.read(sealData) else {
                return SealedResourceVerification(
                    checkedCount: 0, matchedCount: 0,
                    mismatchedPaths: [], mismatchCount: 0,
                    missingPaths: [], missingCount: 0,
                    unreadablePaths: [], unreadableCount: 0,
                    skippedCount: 0, omittedCount: 0,
                    verifiedAt: now()
                )
            }

            var checked = 0
            var matched = 0
            var mismatched: [String] = []
            var mismatchCount = 0
            var missing: [String] = []
            var missingCount = 0
            var unreadable: [String] = []
            var unreadableCount = 0
            let verifiable = manifest.verifiableFileEntries
            let skipped = manifest.entries.count - verifiable.count
            let listLimit = SealedResourceVerification.maximumListedPaths

            for (index, item) in verifiable.enumerated() {
                if index % 64 == 0 { try Task.checkCancellation() }
                guard let relative = item.path,
                      let expected = item.sha256,
                      let path = BundlePath(components: container.components + relative.components) else {
                    continue
                }
                guard let entry = package.contents.entry(at: path), entry.kind == .regularFile else {
                    if !item.isOptional {
                        missingCount += 1
                        if missing.count < listLimit { missing.append(item.recordedPath) }
                    }
                    continue
                }
                switch readBundleFile(path, in: package, limit: limits.maximumSealedFileBytes) {
                case .available(let data):
                    checked += 1
                    let computed = try digest.digest(data, algorithm: .sha256)
                    if computed.bytes == expected {
                        matched += 1
                    } else {
                        mismatchCount += 1
                        if mismatched.count < listLimit { mismatched.append(item.recordedPath) }
                    }
                case .missing:
                    if !item.isOptional {
                        missingCount += 1
                        if missing.count < listLimit { missing.append(item.recordedPath) }
                    }
                case .unreadable, .notApplicable:
                    unreadableCount += 1
                    if unreadable.count < listLimit { unreadable.append(item.recordedPath) }
                }
            }

            return SealedResourceVerification(
                checkedCount: checked,
                matchedCount: matched,
                mismatchedPaths: mismatched,
                mismatchCount: mismatchCount,
                missingPaths: missing,
                missingCount: missingCount,
                unreadablePaths: unreadable,
                unreadableCount: unreadableCount,
                skippedCount: skipped,
                omittedCount: manifest.omittedEntryCount,
                verifiedAt: now()
            )
        } catch {
            throw Self.normalized(error)
        }
    }

    // MARK: - Comparison candidates

    /// The packages the current one can be compared with: other library
    /// records whose package is available, and signed packages in
    /// `Documents/Signed`. Nothing is opened to list them.
    func comparisonCandidates(excluding source: BinaryInspectionSource) async throws -> [BinaryComparisonCandidate] {
        var candidates: [BinaryComparisonCandidate] = []
        for entry in try await library.entries() where entry.isArtifactAvailable {
            let candidateSource = BinaryInspectionSource.libraryRecord(entry.record.id)
            guard candidateSource != source else { continue }
            let record = entry.record
            candidates.append(BinaryComparisonCandidate(
                kind: .libraryRecord,
                source: candidateSource,
                name: record.displayName ?? record.bundleIdentifier.rawValue,
                bundleIdentifier: record.bundleIdentifier.rawValue,
                version: record.identity.shortVersionString,
                date: record.importedAt,
                byteCount: record.artifact.byteCount
            ))
        }
        if let directory = signedPackagesDirectory,
           let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
           ) {
            for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where url.pathExtension.lowercased() == "ipa" {
                let candidateSource = BinaryInspectionSource.signedPackage(url)
                guard candidateSource != source else { continue }
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                candidates.append(BinaryComparisonCandidate(
                    kind: .signedPackage,
                    source: candidateSource,
                    name: url.deletingPathExtension().lastPathComponent,
                    bundleIdentifier: nil,
                    version: nil,
                    date: values?.contentModificationDate,
                    byteCount: values?.fileSize
                ))
            }
        }
        return candidates
    }

    // MARK: - Opening a package

    private struct OpenedPackage {
        let reader: any ArchiveReader
        let bundlePath: ArchivePath
        let contents: BundleContents
        let overview: BinaryBundleOverview
    }

    private func open(_ source: BinaryInspectionSource) async throws -> OpenedPackage {
        try Task.checkCancellation()
        let reader: any ArchiveReader
        var recordedExecutableName: String?
        switch source {
        case .libraryRecord(let id):
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
            reader = try readerProvider.archiveReader(for: entry.record.artifact.artifactID)
            recordedExecutableName = entry.record.executableName
        case .signedPackage(let url):
            guard isPermittedSignedPackage(url) else {
                throw ZynSignError.artifactNotAvailable(
                    diagnosticDetail: "The requested package is not a signed package ZynSign keeps."
                )
            }
            reader = makePackageReader(url)
        }

        do {
            let table = try reader.readEntryTable()
            try Task.checkCancellation()
            let bundlePath: ArchivePath
            switch ApplicationBundleDiscovery.discover(in: table).outcome {
            case .exactlyOne(let discovered):
                bundlePath = discovered
            case .ambiguous(let candidates):
                throw ZynSignError.ambiguousArtifact(
                    diagnosticDetail: "The package holds \(candidates.count) application bundles in its payload directory."
                )
            case .missingPayloadDirectory, .none:
                throw ZynSignError.missingApplicationBundle(
                    diagnosticDetail: "The package holds no application bundle in its payload directory."
                )
            }
            let contents = BundleContents(entryTable: table, bundlePath: bundlePath)
            let partial = OpenedPackage(
                reader: reader,
                bundlePath: bundlePath,
                contents: contents,
                overview: BinaryBundleOverview(bundleName: contents.bundleName, targets: [], omittedTargetCount: 0)
            )

            let appInfo = BundlePath.root.appending(component: "Info.plist")
                .map { readBundleFile($0, in: partial, limit: limits.maximumBundleInformationBytes) }
            var mainName = recordedExecutableName
            if case .some(.available(let data)) = appInfo, let declared = Self.executableName(inPropertyList: data) {
                mainName = declared
            }

            var declaredNames: [BundlePath: String] = [:]
            for container in BinaryTargetDiscovery.nestedContainers(in: contents).prefix(limits.maximumNestedTargets) {
                guard let infoPath = container.appending(component: "Info.plist"),
                      case .available(let data) = readBundleFile(infoPath, in: partial, limit: limits.maximumBundleInformationBytes),
                      let name = Self.executableName(inPropertyList: data) else { continue }
                declaredNames[container] = name
            }

            let overview = BinaryTargetDiscovery.discover(
                contents: contents,
                mainExecutableName: mainName,
                declaredExecutableNames: declaredNames,
                maximumNestedTargets: limits.maximumNestedTargets
            )
            return OpenedPackage(reader: reader, bundlePath: bundlePath, contents: contents, overview: overview)
        } catch {
            reader.close()
            throw error
        }
    }

    /// A signed package is opened only from the directory ZynSign writes
    /// signed output to, and only as an `.ipa` file directly inside it.
    private func isPermittedSignedPackage(_ url: URL) -> Bool {
        guard url.isFileURL, url.pathExtension.lowercased() == "ipa",
              let directory = signedPackagesDirectory else { return false }
        return url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path
    }

    // MARK: - Inspecting one target

    private func inspect(
        _ target: BinaryTarget,
        in package: OpenedPackage,
        emit: @escaping (BinaryInspectionEvent) -> Void
    ) throws -> BinaryTargetOutcome {
        guard let executableLocation = archivePath(for: target.executablePath, in: package),
              let entry = package.contents.entry(at: target.executablePath),
              entry.kind == .regularFile else {
            return .unavailable(target, .missingExecutable)
        }
        if let declared = entry.declaredByteCount, declared > limits.maximumExecutableBytes {
            return .unavailable(target, .exceedsReadLimit(limit: limits.maximumExecutableBytes, declared: declared))
        }

        let bytes: Data
        do {
            let read = try package.reader.readEntryData(at: executableLocation, maximumBytes: limits.maximumExecutableBytes)
            // Every range the parser reports is an offset from index zero.
            bytes = read.startIndex == 0 ? read : Data(read)
        } catch {
            return .unavailable(target, .unreadable)
        }
        try Task.checkCancellation()

        let image: MachOImage
        do {
            image = try parser.parse(bytes)
        } catch let error as MachOParsingError {
            if MachOExistingCodeSignatureState.classify(error) != nil {
                return .unavailable(target, .malformedSignature)
            }
            return .unavailable(target, error.reason == .unsupportedFormat ? .notMachO : .malformedMachO)
        } catch {
            return .unavailable(target, .malformedMachO)
        }

        let architectures = architectureReports(for: image, bytes: bytes)
        let containerKind: BinaryContainerKind
        if case .universal(let universal) = image.container {
            containerKind = .universal(architectureCount: universal.slices.count)
        } else {
            containerKind = .thin
        }
        let structure = BinaryInspectionReport(
            target: target,
            fileSize: bytes.count,
            container: containerKind,
            architectures: architectures,
            inspectedAt: now(),
            integrity: nil
        )
        emit(.structureReady(structure))

        let context = BinaryVerificationContext(
            architectureNames: Dictionary(uniqueKeysWithValues: architectures.map { ($0.index, $0.name) }),
            resources: boundResources(for: target, in: package),
            expectsEntitlements: target.kind == .mainExecutable
                || target.kind == .appExtension
                || target.kind == .nestedApplication
        )
        let targetID = target.id
        let integrity = try verifier.verify(image: image, bytes: bytes, context: context) { completed, total in
            emit(.verificationProgress(targetID: targetID, completed: completed, total: total))
        }
        let report = structure.withIntegrity(integrity)
        emit(.completed(report))
        return .inspected(report)
    }

    private func architectureReports(for image: MachOImage, bytes: Data) -> [BinaryArchitectureReport] {
        typealias Placement = (offset: Int, size: Int, alignment: UInt32?)
        let placements: [Placement]
        switch image.container {
        case .thin(let slice):
            let placement: Placement = (offset: slice.fileRange.lowerBound, size: slice.fileRange.count, alignment: nil)
            placements = [placement]
        case .universal(let universal):
            placements = universal.architectures.map { architecture -> Placement in
                (offset: architecture.fileRange.lowerBound, size: architecture.fileRange.count, alignment: architecture.alignmentExponent)
            }
        }
        return image.slices.enumerated().map { index, slice -> BinaryArchitectureReport in
            let fallback: Placement = (offset: slice.fileRange.lowerBound, size: slice.fileRange.count, alignment: nil)
            let placement: Placement = index < placements.count ? placements[index] : fallback
            return BinaryArchitectureReport(
                index: index,
                architecture: MachOArchitectureName(cpu: slice.header.cpu, cpuSubtype: slice.header.cpuSubtype),
                fileOffset: placement.offset,
                size: placement.size,
                alignmentExponent: placement.alignment,
                fileKind: MachOFileKind(rawValue: slice.header.fileType),
                headerFlags: MachOHeaderFlagTable.decode(slice.header.flags),
                loadCommands: decoder.decodeLoadCommands(of: slice, in: bytes),
                signature: CodeSignatureSummary.make(
                    slice: slice,
                    bytes: bytes,
                    codeDirectoryHashes: codeDirectoryHashes(of: slice, bytes: bytes)
                )
            )
        }
    }

    /// The CDHash of each CodeDirectory: the first 20 bytes of the digest of
    /// the CodeDirectory blob under its own hash type.
    private func codeDirectoryHashes(of slice: MachOSlice, bytes: Data) -> [UInt32: Data] {
        guard let entries = slice.embeddedSignature?.superBlob.entries else { return [:] }
        var hashes: [UInt32: Data] = [:]
        for entry in entries {
            guard let directory = entry.codeDirectory,
                  let algorithm = directory.hashType.digestAlgorithm,
                  entry.fileRange.upperBound <= bytes.endIndex,
                  let computed = try? digest.digest(bytes.subdata(in: entry.fileRange), algorithm: algorithm) else {
                continue
            }
            hashes[entry.slotNumber] = Data(computed.bytes.prefix(20))
        }
        return hashes
    }

    // MARK: - Bundle files

    private func boundResources(for target: BinaryTarget, in package: OpenedPackage) -> BinaryBoundResources {
        guard let container = target.containerPath else { return .notApplicable }
        let infoPlistPath = container.appending(component: "Info.plist")
        let sealPath = container.appending(component: "_CodeSignature").flatMap { $0.appending(component: "CodeResources") }
        let infoPlist: BoundResourceContent = infoPlistPath.map {
            readBundleFile($0, in: package, limit: limits.maximumBundleInformationBytes)
        } ?? .missing
        let codeResources: BoundResourceContent = sealPath.map {
            readBundleFile($0, in: package, limit: limits.maximumResourceSealBytes)
        } ?? .missing
        return BinaryBoundResources(infoPlist: infoPlist, codeResources: codeResources)
    }

    private func readBundleFile(_ path: BundlePath, in package: OpenedPackage, limit: Int) -> BoundResourceContent {
        guard let entry = package.contents.entry(at: path), entry.kind == .regularFile,
              let location = archivePath(for: path, in: package) else {
            return .missing
        }
        if let declared = entry.declaredByteCount, declared > limit {
            return .unreadable("\(path.rawValue) is larger than the \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)) ZynSign reads for this check.")
        }
        do {
            return .available(try package.reader.readEntryData(at: location, maximumBytes: limit))
        } catch {
            return .unreadable("\(path.rawValue) could not be read within the archive's inspection policy.")
        }
    }

    private func archivePath(for path: BundlePath, in package: OpenedPackage) -> ArchivePath? {
        var result = package.bundlePath
        for component in path.components {
            guard let next = result.appending(component: component) else { return nil }
            result = next
        }
        return result
    }

    private static func executableName(inPropertyList data: Data) -> String? {
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format),
              let dictionary = root as? [String: Any],
              let name = dictionary["CFBundleExecutable"] as? String,
              BundlePath.isValidComponent(name) else {
            return nil
        }
        return name
    }

    // MARK: - Errors

    /// Passes ZynSign's own errors and cancellation through unchanged and
    /// wraps anything else, so no platform error text is presented as a fact
    /// about the package.
    private static func normalized(_ error: any Error) -> any Error {
        if error is ZynSignError || error is CancellationError {
            return error
        }
        return ZynSignError.bundleInspectionFailure(
            diagnosticDetail: "Binary inspection failed with \(String(describing: type(of: error))).",
            underlyingError: error
        )
    }
}
