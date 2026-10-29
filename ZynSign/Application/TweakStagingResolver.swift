import Foundation

/// Resolved staging artifacts from a `TweakInjectionPlan`, supporting `.dylib`,
/// `.deb` (unpacked via `DebArchiveParser`), and zipped `.framework`, `.bundle`,
/// and `.appex` entries without altering legacy `.dylib`-only `stagedTweaks(for:)`.
struct TweakResolvedStagingSet: Equatable, Sendable {
    var dylibs: [SideloadStagedTweak]
    var bundlePayloads: [SideloadStagedBundlePayload]
    var autoRecommendedSubstrateRewrite: Bool
    var autoRecommendedArm64eFix: Bool
}

/// Port for storing per-tweak Auto-Inject rules.
protocol TweakAutoInjectRuleStore: Sendable {
    func allRules() throws -> [TweakAutoInjectRule]
    func saveRule(_ rule: TweakAutoInjectRule) throws
    func removeRule(tweakID: UUID) throws
}

extension TweakLibraryService {

    /// Resolves any combination of `.dylib`, `.deb`, `.framework`, `.bundle`,
    /// and `.appex` items in `plan` into concrete `SideloadSigningOptions` payloads.
    func prepareFullStagingArtifacts(for plan: TweakInjectionPlan) throws -> TweakResolvedStagingSet {
        var dylibs: [SideloadStagedTweak] = []
        var bundles: [SideloadStagedBundlePayload] = []
        var needsSubstrateRewrite = false
        var needsArm64eFix = false

        for descriptor in plan.entries {
            guard let rawBytes = try payload(for: descriptor.id) else {
                throw StagingRefusal.payloadMissing(descriptor.name)
            }
            switch descriptor.kind {
            case .dynamicLibrary:
                let analysis = TweakMachOAnalyzer.analyze(rawBytes)
                if analysis.requiresRpathSubstrateRewrite { needsSubstrateRewrite = true }
                if analysis.hasLegacyArm64eSlice { needsArm64eFix = true }
                dylibs.append(SideloadStagedTweak(fileName: descriptor.fileName, bytes: rawBytes))
            case .debPackage:
                let unpacked = try unpackDebForStaging(rawBytes)
                for dylib in unpacked.dylibs {
                    let analysis = TweakMachOAnalyzer.analyze(dylib.bytes)
                    if analysis.requiresRpathSubstrateRewrite { needsSubstrateRewrite = true }
                    if analysis.hasLegacyArm64eSlice { needsArm64eFix = true }
                }
                dylibs.append(contentsOf: unpacked.dylibs)
                bundles.append(contentsOf: unpacked.bundles)
            case .framework:
                if let bundle = try unpackZippedBundlePayload(rawBytes, expectedName: descriptor.fileName, type: .framework) {
                    bundles.append(bundle)
                }
            case .resourceBundle:
                if let bundle = try unpackZippedBundlePayload(rawBytes, expectedName: descriptor.fileName, type: .resourceBundle) {
                    bundles.append(bundle)
                }
            case .appExtension:
                if let bundle = try unpackZippedBundlePayload(rawBytes, expectedName: descriptor.fileName, type: .appExtension) {
                    bundles.append(bundle)
                }
            case .other:
                if let unpacked = try? unpackDebForStaging(rawBytes) {
                    dylibs.append(contentsOf: unpacked.dylibs)
                    bundles.append(contentsOf: unpacked.bundles)
                }
            }
        }
        return TweakResolvedStagingSet(
            dylibs: dylibs,
            bundlePayloads: bundles,
            autoRecommendedSubstrateRewrite: needsSubstrateRewrite,
            autoRecommendedArm64eFix: needsArm64eFix
        )
    }

    /// Unpacks a `.deb` archive and imports each discovered `.dylib`, `.framework`,
    /// or `.bundle` into the Tweak Library as an individually toggleable record.
    func importUnpackedDebPayloads(
        _ debBytes: Data,
        sourceName: String,
        group: String? = nil
    ) throws -> (control: DebArchiveParser.ControlMetadata, imported: [TweakDescriptor]) {
        let unpacked = try DebArchiveParser.unpack(debBytes)
        let effectiveGroup = group ?? unpacked.control.name ?? Self.displayName(forFileName: sourceName)
        var imported: [TweakDescriptor] = []

        var groupedBundles: [String: [DebArchiveParser.ExtractedPayload]] = [:]
        for item in unpacked.payloads {
            switch item.kind {
            case .dylib:
                if case .success(let out) = try importPayload(item.bytes, fileName: item.topLevelName, group: effectiveGroup) {
                    imported.append(out.descriptor)
                }
            case .framework, .bundle:
                groupedBundles[item.topLevelName, default: []].append(item)
            }
        }
        for (bundleName, items) in groupedBundles.sorted(by: { $0.key < $1.key }) {
            if let zipped = try? zipExtractedBundleItems(items),
               case .success(let out) = try importPayload(zipped, fileName: bundleName, group: effectiveGroup) {
                imported.append(out.descriptor)
            }
        }
        return (unpacked.control, imported)
    }

    // MARK: - Helpers

    private func unpackDebForStaging(
        _ debBytes: Data
    ) throws -> (dylibs: [SideloadStagedTweak], bundles: [SideloadStagedBundlePayload]) {
        let unpacked = try DebArchiveParser.unpack(debBytes)
        var dylibs: [SideloadStagedTweak] = []
        var grouped: [String: (DebArchiveParser.ExtractedPayload.PayloadKind, [SideloadStagedBundlePayload.StagedBundleFile])] = [:]

        for item in unpacked.payloads {
            switch item.kind {
            case .dylib:
                dylibs.append(SideloadStagedTweak(fileName: item.topLevelName, bytes: item.bytes))
            case .framework, .bundle:
                let file = SideloadStagedBundlePayload.StagedBundleFile(
                    relativePath: item.relativePath,
                    bytes: item.bytes,
                    isExecutable: item.isExecutable
                )
                var current = grouped[item.topLevelName] ?? (item.kind, [])
                current.1.append(file)
                grouped[item.topLevelName] = current
            }
        }

        var bundles: [SideloadStagedBundlePayload] = []
        for (topName, entry) in grouped.sorted(by: { $0.key < $1.key }) {
            let pType: SideloadStagedBundlePayload.PayloadType = entry.0 == .framework ? .framework : .resourceBundle
            let execSubpath = pType == .framework ? resolveFrameworkExecutableSubpath(topName: topName, files: entry.1) : nil
            bundles.append(SideloadStagedBundlePayload(
                topLevelName: topName,
                payloadType: pType,
                linkedFrameworkExecutableSubpath: execSubpath,
                files: entry.1
            ))
        }
        return (dylibs, bundles)
    }

    private func unpackZippedBundlePayload(
        _ bytes: Data,
        expectedName: String,
        type: SideloadStagedBundlePayload.PayloadType
    ) throws -> SideloadStagedBundlePayload? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZynTweakBundle-\(UUID().uuidString).zip")
        try bytes.write(to: tempURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let reader = ZipArchiveReader(location: tempURL)
        defer { reader.close() }
        guard let entries = try? reader.readEntryTable() else { return nil }

        var files: [SideloadStagedBundlePayload.StagedBundleFile] = []
        for entry in entries where entry.kind == .regularFile {
            guard let entryPath = entry.path,
                  let content = try? reader.readEntryData(at: entryPath, maximumBytes: 64 * 1024 * 1024) else {
                continue
            }
            let relPath: String
            if let first = entryPath.components.first, first.lowercased() == expectedName.lowercased() {
                relPath = entryPath.components.joined(separator: "/")
            } else {
                relPath = ([expectedName] + entryPath.components).joined(separator: "/")
            }
            files.append(SideloadStagedBundlePayload.StagedBundleFile(
                relativePath: relPath,
                bytes: content,
                isExecutable: ((entry.unixMode ?? 0) & 0o111) != 0
            ))
        }
        guard !files.isEmpty else { return nil }
        let execSubpath = type == .framework
            ? resolveFrameworkExecutableSubpath(topName: expectedName, files: files)
            : nil
        return SideloadStagedBundlePayload(
            topLevelName: expectedName,
            payloadType: type,
            linkedFrameworkExecutableSubpath: execSubpath,
            files: files
        )
    }

    private func resolveFrameworkExecutableSubpath(
        topName: String,
        files: [SideloadStagedBundlePayload.StagedBundleFile]
    ) -> String? {
        let infoPath = "\(topName)/Info.plist".lowercased()
        if let infoItem = files.first(where: { $0.relativePath.lowercased() == infoPath }),
           let plist = try? PropertyListSerialization.propertyList(from: infoItem.bytes, options: [], format: nil),
           let dict = plist as? [String: Any],
           let exec = dict["CFBundleExecutable"] as? String, !exec.isEmpty {
            return "Frameworks/\(topName)/\(exec)"
        }
        let stem = (topName as NSString).deletingPathExtension
        let fallback = "\(topName)/\(stem)".lowercased()
        if files.contains(where: { $0.relativePath.lowercased() == fallback }) {
            return "Frameworks/\(topName)/\(stem)"
        }
        return nil
    }

    private func zipExtractedBundleItems(
        _ items: [DebArchiveParser.ExtractedPayload]
    ) throws -> Data {
        var writeEntries: [ArchiveWriteEntry] = []
        for item in items {
            guard let archPath = ArchivePath(rawValue: item.relativePath) else { continue }
            writeEntries.append(ArchiveWriteEntry(
                path: archPath,
                kind: .regularFile(isExecutable: item.isExecutable),
                content: item.bytes
            ))
        }
        var outBytes = Data()
        try ZipArchiveWriter().writeArchive(entries: writeEntries, policy: .default) { chunk in
            outBytes.append(chunk)
        }
        return outBytes
    }
}

/// Imports single tweak files, `.framework` / `.bundle` / `.appex` directories,
/// folder tweak packs, and `.zip` tweak packs into `TweakLibraryService`.
enum TweakPackImporter {

    struct ImportSummary: Equatable, Sendable {
        var importedCount: Int = 0
        var lastRefusalMessage: String?
    }

    static func importItem(at url: URL, into service: TweakLibraryService) async throws -> ImportSummary {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return ImportSummary(importedCount: 0, lastRefusalMessage: "The file could not be read.")
        }
        if isDir.boolValue {
            return try await importDirectory(at: url, into: service)
        }
        if url.pathExtension.lowercased() == "zip" {
            return try await importZipArchive(at: url, into: service)
        }
        let data = try Data(contentsOf: url)
        switch try service.importPayload(data, fileName: url.lastPathComponent) {
        case .success:
            return ImportSummary(importedCount: 1, lastRefusalMessage: nil)
        case .failure(let refusal):
            return ImportSummary(importedCount: 0, lastRefusalMessage: refusal.message)
        }
    }

    private static func importDirectory(at url: URL, into service: TweakLibraryService) async throws -> ImportSummary {
        let fm = FileManager.default
        if TweakKind.classify(fileName: url.lastPathComponent) != nil {
            let tempDir = fm.temporaryDirectory.appendingPathComponent("ZynTweakDir-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tempDir) }
            let zipURL = try await FileArchiveTools.packageDirectory(at: url, as: .zip, in: tempDir)
            let bytes = try Data(contentsOf: zipURL)
            switch try service.importPayload(bytes, fileName: url.lastPathComponent) {
            case .success:
                return ImportSummary(importedCount: 1, lastRefusalMessage: nil)
            case .failure(let refusal):
                return ImportSummary(importedCount: 0, lastRefusalMessage: refusal.message)
            }
        }
        let children = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var summary = ImportSummary()
        for child in children {
            let sub = try await importItem(at: child, into: service)
            summary.importedCount += sub.importedCount
            if let refusal = sub.lastRefusalMessage {
                summary.lastRefusalMessage = refusal
            }
        }
        return summary
    }

    private static func importZipArchive(at url: URL, into service: TweakLibraryService) async throws -> ImportSummary {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("ZynTweakZip-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }
        let extractedRoot = try await FileArchiveTools.extractArchive(at: url, in: tempDir)
        return try await importDirectory(at: extractedRoot, into: service)
    }
}

/// Discovers and extracts embedded `.dylib`, `.framework`, `.bundle`, and `.appex`
/// items from an imported Library `.ipa` directly into `TweakLibraryService`.
struct IPATweakExtractor: Sendable {

    struct Candidate: Equatable, Hashable, Sendable, Identifiable {
        var id: String { archivePrefix }
        let name: String
        let kind: TweakKind
        /// Prefix inside the `.ipa`, e.g. `Payload/App.app/Frameworks/Foo.dylib` or `Payload/App.app/Frameworks/Bar.framework`.
        let archivePrefix: String
        let byteSize: Int
    }

    private let makeReader: @Sendable (URL) -> any ArchiveReader

    init(makeReader: @escaping @Sendable (URL) -> any ArchiveReader = { ZipArchiveReader(location: $0) }) {
        self.makeReader = makeReader
    }

    func discoverExtractableItems(in ipaURL: URL) throws -> [Candidate] {
        let reader = makeReader(ipaURL)
        defer { reader.close() }
        let entries = try reader.readEntryTable()
        guard case .exactlyOne(let bundleArchivePath) = ApplicationBundleDiscovery.discover(in: entries).outcome else {
            return []
        }
        let appPrefix = bundleArchivePath.components

        var groupedSizes: [String: (String, TweakKind, Int)] = [:]
        for entry in entries where entry.kind == .regularFile {
            guard let entryPath = entry.path else { continue }
            let parts = entryPath.components
            guard parts.count > appPrefix.count,
                  Array(parts.prefix(appPrefix.count)) == appPrefix else { continue }
            let rel = Array(parts.dropFirst(appPrefix.count))
            if rel.count == 2, rel[0] == "Frameworks", rel[1].lowercased().hasSuffix(".dylib") {
                let key = (appPrefix + rel).joined(separator: "/")
                groupedSizes[key] = (rel[1], .dynamicLibrary, Int(clamping: entry.uncompressedSize))
            } else if rel.count >= 2, rel[0] == "Frameworks", rel[1].lowercased().hasSuffix(".framework") {
                let key = (appPrefix + [rel[0], rel[1]]).joined(separator: "/")
                let prev = groupedSizes[key]?.2 ?? 0
                groupedSizes[key] = (rel[1], .framework, prev + Int(clamping: entry.uncompressedSize))
            } else if rel.count >= 2, (rel[0] == "PlugIns" || rel[0] == "Extensions"),
                      rel[1].lowercased().hasSuffix(".appex") {
                let key = (appPrefix + [rel[0], rel[1]]).joined(separator: "/")
                let prev = groupedSizes[key]?.2 ?? 0
                groupedSizes[key] = (rel[1], .appExtension, prev + Int(clamping: entry.uncompressedSize))
            } else if rel.count >= 2, rel[0].lowercased().hasSuffix(".bundle") {
                let key = (appPrefix + [rel[0]]).joined(separator: "/")
                let prev = groupedSizes[key]?.2 ?? 0
                groupedSizes[key] = (rel[0], .resourceBundle, prev + Int(clamping: entry.uncompressedSize))
            }
        }

        return groupedSizes.map { key, info in
            Candidate(name: info.0, kind: info.1, archivePrefix: key, byteSize: info.2)
        }.sorted { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }
    }

    func extract(
        _ candidate: Candidate,
        from ipaURL: URL,
        into tweakLibrary: TweakLibraryService,
        group: String?
    ) throws -> Result<TweakImportOutcome, TweakImportRefusal> {
        let reader = makeReader(ipaURL)
        defer { reader.close() }
        let entries = try reader.readEntryTable()

        if candidate.kind == .dynamicLibrary {
            guard let path = ArchivePath(rawValue: candidate.archivePrefix) else {
                throw ZynSignError.invalidArtifact(diagnosticDetail: "Invalid archive path.")
            }
            let bytes = try reader.readEntryData(at: path, maximumBytes: 128 * 1024 * 1024)
            return try tweakLibrary.importPayload(bytes, fileName: candidate.name, group: group)
        }

        let prefixParts = candidate.archivePrefix.split(separator: "/").map(String.init)
        let matching = entries.filter { entry in
            guard let entryPath = entry.path else { return false }
            return entry.kind == .regularFile
                && entryPath.components.count > prefixParts.count
                && Array(entryPath.components.prefix(prefixParts.count)) == prefixParts
        }

        var writeEntries: [ArchiveWriteEntry] = []
        for entry in matching {
            guard let entryPath = entry.path else { continue }
            let subParts = [candidate.name] + Array(entryPath.components.dropFirst(prefixParts.count))
            let rel = subParts.joined(separator: "/")
            guard let archPath = ArchivePath(rawValue: rel) else { continue }
            let bytes = try reader.readEntryData(at: entryPath, maximumBytes: 64 * 1024 * 1024)
            let isExec = ((entry.unixMode ?? 0) & 0o111) != 0
            writeEntries.append(ArchiveWriteEntry(path: archPath, kind: .regularFile(isExecutable: isExec), content: bytes))
        }
        var zippedBytes = Data()
        try ZipArchiveWriter().writeArchive(entries: writeEntries, policy: .default) { chunk in
            zippedBytes.append(chunk)
        }
        return try tweakLibrary.importPayload(zippedBytes, fileName: candidate.name, group: group)
    }
}
