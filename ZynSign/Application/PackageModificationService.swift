import Foundation

/// Executes ZynSign's **Only Modify** workflow: applies
/// `SideloadSigningOptions` (`Info.plist` overrides, PPQ bundle ID rewrites,
/// icon swap, removals, tweak/bundle staging, and Mach-O compatibility patches)
/// to an imported `.ipa` inside an isolated working directory and repackages it
/// into a valid `Payload/<Name>.app` `.ipa` without requiring a signing identity
/// or provisioning profile.
struct PackageModificationService: Sendable {

    struct Outcome: Equatable, Sendable {
        let outputURL: URL
        let editReport: SideloadEditReport
        let packageReport: PackageSignedApplicationReport
    }

    private let limits: ArchiveLimits
    private let makeReader: @Sendable (URL) -> any ArchiveReader
    private let makeWriter: @Sendable () -> any ArchiveWriter

    init(
        limits: ArchiveLimits = .default,
        makeReader: @escaping @Sendable (URL) -> any ArchiveReader = { ZipArchiveReader(location: $0) },
        makeWriter: @escaping @Sendable () -> any ArchiveWriter = { ZipArchiveWriter() }
    ) {
        self.limits = limits
        self.makeReader = makeReader
        self.makeWriter = makeWriter
    }

    func modifyAndRepackage(
        sourceURL: URL,
        options: SideloadSigningOptions,
        stripSignatures: Bool = true,
        outputDirectory: URL? = nil
    ) async throws -> Outcome {
        var validated = options
        validated.onlyModify = true
        try validated.validate(hasCertificate: false)

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ZynSign-ModifyOnly-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let reader = makeReader(sourceURL)
        defer { reader.close() }
        let entries = try reader.readEntryTable()
        guard case .exactlyOne(let bundleArchivePath) = ApplicationBundleDiscovery.discover(in: entries).outcome else {
            throw ZynSignError.missingApplicationBundle(diagnosticDetail: "Could not locate a single Payload/<Name>.app bundle.")
        }

        let workDir = tempRoot.appendingPathComponent("work", isDirectory: true)
        let extractionPolicy = ArchiveExtractionPolicy(
            maximumExtractedBytes: limits.maximumTotalUncompressedBytes,
            maximumLinkTargetBytes: limits.maximumEntryNameLength,
            symlinkPolicy: .recreateWithinRoot
        )
        _ = try await DirectoryArchiveExtractor(
            destination: workDir,
            policy: extractionPolicy,
            readBound: limits.maximumEntryBytes
        ).extract(reader: reader)

        var bundleDirectory = workDir
        for component in bundleArchivePath.components {
            bundleDirectory.appendPathComponent(component)
        }
        let bundleName = bundleDirectory.lastPathComponent

        if stripSignatures {
            stripExistingCodeSignatures(in: bundleDirectory)
        }

        let editReport = try SideloadPackageEditor(options: validated).apply(in: bundleDirectory)

        if stripSignatures {
            stripExistingCodeSignatures(in: bundleDirectory)
        }

        if validated.adHoc {
            let infoURL = bundleDirectory.appendingPathComponent("Info.plist")
            if let infoData = try? Data(contentsOf: infoURL),
               let plist = try? PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any],
               let execName = plist["CFBundleExecutable"] as? String,
               let bundleID = plist["CFBundleIdentifier"] as? String {
                _ = try AdHocMachOSigner().signBundleDirectory(
                    at: bundleDirectory,
                    bundleIdentifier: bundleID,
                    executableName: execName
                )
            }
        }

        let deliveryRoot = outputDirectory ?? fileManager.temporaryDirectory
            .appendingPathComponent("ZynSign-ModifiedExports", isDirectory: true)
        try fileManager.createDirectory(at: deliveryRoot, withIntermediateDirectories: true)
        let stem = (bundleName as NSString).deletingPathExtension
        let outputURL = deliveryRoot
            .appendingPathComponent("\(stem)-Modified-\(UUID().uuidString.prefix(8)).ipa")

        let packager = PackageSignedApplication(
            writer: makeWriter(),
            limits: limits,
            makeReader: makeReader
        )
        let packageReport = try await packager.package(
            PackageSignedApplicationRequest(
                bundleDirectory: bundleDirectory,
                bundleName: bundleName,
                outputURL: outputURL
            )
        )
        return Outcome(outputURL: outputURL, editReport: editReport, packageReport: packageReport)
    }

    /// Reads the embedded `CSSLOT_ENTITLEMENTS` XML from an `.ipa`'s main executable,
    /// used when `Merge Binary Entitlements` is enabled before signing.
    func extractMainExecutableEntitlements(from ipaURL: URL) -> Data? {
        let reader = makeReader(ipaURL)
        defer { reader.close() }
        guard let entries = try? reader.readEntryTable(),
              case .exactlyOne(let bundleArchivePath) = ApplicationBundleDiscovery.discover(in: entries).outcome else {
            return nil
        }
        let infoPathComp = bundleArchivePath.components + ["Info.plist"]
        guard let infoPath = ArchivePath(rawValue: infoPathComp.joined(separator: "/")),
              let infoBytes = try? reader.readEntryData(at: infoPath, maximumBytes: 2 * 1_024 * 1_024),
              let plist = try? PropertyListSerialization.propertyList(from: infoBytes, options: [], format: nil) as? [String: Any],
              let execName = plist["CFBundleExecutable"] as? String else {
            return nil
        }
        let execComp = bundleArchivePath.components + [execName]
        guard let execPath = ArchivePath(rawValue: execComp.joined(separator: "/")),
              let execBytes = try? reader.readEntryData(at: execPath, maximumBytes: 128 * 1_024 * 1_024) else {
            return nil
        }
        return MachOBinaryPatcher.extractEmbeddedEntitlementsXML(from: execBytes)
    }

    private func stripExistingCodeSignatures(in bundleDirectory: URL) {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: bundleDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: []
        ) else { return }
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey]) else {
                continue
            }
            if values.isDirectory == true {
                if item.lastPathComponent == "_CodeSignature" {
                    try? fileManager.removeItem(at: item)
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true,
                  let data = try? Data(contentsOf: item, options: .mappedIfSafe),
                  data.count <= MachOCodeSignatureStripper.maximumImageByteCount,
                  MachOCodeSignatureStripper.carriesSignature(data),
                  let stripped = try? MachOCodeSignatureStripper.stripSignature(from: data) else {
                continue
            }
            try? stripped.write(to: item, options: .atomic)
        }
    }
}
