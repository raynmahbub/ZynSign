import Foundation

/// Filesystem-backed `NestedCodeInspectionSource` over an extracted `<Name>.app`
/// working directory after `SideloadPackageEditor` mutates nested bundles,
/// `PlugIns/`, or `Frameworks/` (injected `.dylib`, `.framework`, `.bundle`, `.appex`).
struct DirectoryNestedCodeInspectionSource: NestedCodeInspectionSource {

    private let workingRoot: URL
    private let parser: any MachOParsing
    private let signatureInspector: MachOCodeSignatureInspector
    private let limits: ArchiveLimits

    init(
        workingRoot: URL,
        parser: any MachOParsing = ReadOnlyMachOParser(),
        limits: ArchiveLimits = .default
    ) {
        self.workingRoot = workingRoot
        self.parser = parser
        self.limits = limits
        self.signatureInspector = MachOCodeSignatureInspector(parser: parser)
    }

    /// Synthesizes a deterministic `ArchiveEntry` table over `workingRoot` for
    /// `NestedCodeDiscovery.discover`.
    static func buildEntryTable(at workingRoot: URL, bundlePath: ArchivePath) throws -> [ArchiveEntry] {
        let fm = FileManager.default
        var appDir = workingRoot
        for component in bundlePath.components {
            appDir.appendPathComponent(component, isDirectory: true)
        }
        guard let enumerator = fm.enumerator(
            at: appDir,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        ) else {
            return []
        }

        var entries: [ArchiveEntry] = []
        if let rootArchivePath = ArchivePath(rawValue: bundlePath.rawValue) {
            entries.append(ArchiveEntry(path: rootArchivePath, kind: .directory))
        }
        let basePrefix = appDir.standardizedFileURL.path + "/"
        for case let itemURL as URL in enumerator {
            let fullPath = itemURL.standardizedFileURL.path
            guard fullPath.hasPrefix(basePrefix) else { continue }
            let relative = String(fullPath.dropFirst(basePrefix.count))
            guard !relative.isEmpty else { continue }
            let combined = bundlePath.rawValue + "/" + relative
            guard let archivePath = ArchivePath(rawValue: combined) else { continue }

            let vals = try itemURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            if vals.isSymbolicLink == true {
                entries.append(ArchiveEntry(path: archivePath, kind: .symbolicLink))
            } else if vals.isDirectory == true {
                entries.append(ArchiveEntry(path: archivePath, kind: .directory))
            } else if vals.isRegularFile == true {
                let sz = vals.fileSize ?? 0
                entries.append(ArchiveEntry(path: archivePath, kind: .regularFile, uncompressedSize: sz, compressedSize: sz))
            }
        }
        entries.sort { $0.rawName < $1.rawName }
        return entries
    }

    func bundleInformation(
        ofContainerAt path: ArchivePath,
        maximumBytes: Int
    ) -> NestedCodeBundleInformation {
        guard let infoPath = IPALayout.bundleInformationPath(within: path) else {
            return .unreadable
        }
        guard let bytes = readBounded(at: infoPath, maximumBytes: maximumBytes) else {
            return .unreadable
        }
        guard let metadata = ApplicationMetadataReader.read(from: bytes).metadata else {
            return .malformed
        }
        return .read(NestedCodeBundleIdentity(metadata: metadata))
    }

    func binary(
        at path: ArchivePath,
        declaredByteCount: Int?,
        maximumBytes: Int
    ) -> NestedCodeBinaryInspection {
        let cap = max(1, min(maximumBytes, limits.maximumInspectionReadBytes))
        if let declaredByteCount, declaredByteCount > cap {
            return NestedCodeBinaryInspection(
                observation: .beyondInspectionBound(declaredByteCount: declaredByteCount)
            )
        }
        guard let bytes = readBounded(at: path, maximumBytes: cap) else {
            return NestedCodeBinaryInspection(observation: .unreadable)
        }
        switch signatureInspector.inspect(bytes: bytes) {
        case .thin(let slice):
            return NestedCodeBinaryInspection(
                observation: .machO(summary: NestedCodeMachOSummary(slices: [slice.slice], isUniversal: false)),
                existingSignature: NestedCodeExistingSignature(states: [slice.existingSignature])
            )
        case .universal(let slices):
            return NestedCodeBinaryInspection(
                observation: .machO(summary: NestedCodeMachOSummary(slices: slices.map(\.slice), isUniversal: true)),
                existingSignature: NestedCodeExistingSignature(states: slices.map(\.existingSignature))
            )
        case let .malformedSignature(_, state):
            return NestedCodeBinaryInspection(
                observation: .machO(summary: nil),
                existingSignature: NestedCodeExistingSignature.failure(state)
            )
        case .malformedMachO(let error):
            return NestedCodeBinaryInspection(
                observation: NestedCodeBinaryObservation.classifying(error)
            )
        }
    }

    private func readBounded(at path: ArchivePath, maximumBytes: Int) -> Data? {
        var url = workingRoot
        for component in path.components {
            url.appendPathComponent(component)
        }
        let cap = max(1, min(maximumBytes, limits.maximumInspectionReadBytes))
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: cap + 1), data.count <= cap else {
            return nil
        }
        return data
    }
}
