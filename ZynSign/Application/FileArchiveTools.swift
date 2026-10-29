import Foundation

/// Archive extraction, folder-to-IPA/ZIP packaging, and certificate-pair
/// folder discovery for the in-app File Manager (`FilesView`).
struct FileArchiveTools: Sendable {

    enum PackageOutputKind: String, CaseIterable, Sendable {
        case ipa = "IPA Package (.ipa)"
        case zip = "ZIP Archive (.zip)"

        var fileExtension: String {
            switch self {
            case .ipa: return "ipa"
            case .zip: return "zip"
            }
        }
    }

    struct DetectedCertificatePair: Equatable, Sendable, Identifiable {
        var id: String { p12URL.path + "::" + profileURL.path }
        let p12URL: URL
        let profileURL: URL
        let passwordHint: String?
    }

    /// Extracts `.ipa`, `.tipa`, `.zip`, or `.deb` into a new sibling subfolder.
    static func extractArchive(at archiveURL: URL, in destinationParent: URL) async throws -> URL {
        let stem = archiveURL.deletingPathExtension().lastPathComponent
        let targetDir = uniqueDestinationURL(
            baseName: stem.isEmpty ? "Extracted" : stem,
            pathExtension: nil,
            in: destinationParent
        )
        let fm = FileManager.default
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let ext = archiveURL.pathExtension.lowercased()
        if ext == "deb" {
            let bytes = try Data(contentsOf: archiveURL)
            let unpacked = try DebArchiveParser.unpack(bytes)
            for item in unpacked.payloads {
                let fileURL = targetDir.appendingPathComponent(item.relativePath)
                try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try item.bytes.write(to: fileURL, options: .atomic)
                if item.isExecutable {
                    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
                }
            }
            return targetDir
        }

        let reader = ZipArchiveReader(location: archiveURL)
        defer { reader.close() }
        let policy = ArchiveExtractionPolicy(
            maximumExtractedBytes: ArchiveLimits.default.maximumTotalUncompressedBytes,
            maximumLinkTargetBytes: ArchiveLimits.default.maximumEntryNameLength,
            symlinkPolicy: .recreateWithinRoot
        )
        _ = try await DirectoryArchiveExtractor(
            destination: targetDir,
            policy: policy,
            readBound: ArchiveLimits.default.maximumEntryBytes
        ).extract(reader: reader)
        return targetDir
    }

    /// Packages a directory into either a valid `Payload/<Name>.app` `.ipa` or a `.zip`.
    static func packageDirectory(
        at folderURL: URL,
        as outputKind: PackageOutputKind,
        in destinationParent: URL
    ) async throws -> URL {
        let fm = FileManager.default
        let baseName = folderURL.deletingPathExtension().lastPathComponent
        let outputURL = uniqueDestinationURL(
            baseName: baseName.isEmpty ? "Archive" : baseName,
            pathExtension: outputKind.fileExtension,
            in: destinationParent
        )

        if outputKind == .ipa {
            if let appDir = locateAppBundle(in: folderURL) {
                let packager = PackageSignedApplication(writer: ZipArchiveWriter())
                _ = try await packager.package(
                    PackageSignedApplicationRequest(
                        bundleDirectory: appDir,
                        bundleName: appDir.lastPathComponent,
                        outputURL: outputURL
                    )
                )
                return outputURL
            }
        }

        let entries = try collectArchiveEntries(under: folderURL, prefixWithFolderName: outputKind == .zip)
        _ = fm.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }
        try ZipArchiveWriter().writeArchive(entries: entries, policy: .default) { chunk in
            try handle.write(contentsOf: chunk)
        }
        return outputURL
    }

    /// Detects a matching `.p12`/`.pfx` + `.mobileprovision`/`.provisionprofile`
    /// pair (and optional `.txt` password file) inside `directory`.
    static func detectCertificatePair(in directory: URL) -> DetectedCertificatePair? {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let p12 = items.first {
            let ext = $0.pathExtension.lowercased()
            return ext == "p12" || ext == "pfx"
        }
        let profile = items.first {
            let ext = $0.pathExtension.lowercased()
            return ext == "mobileprovision" || ext == "provisionprofile"
        }
        guard let p12, let profile else { return nil }
        let txtFile = items.first { $0.pathExtension.lowercased() == "txt" }
        let passwordHint = txtFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return DetectedCertificatePair(
            p12URL: p12,
            profileURL: profile,
            passwordHint: passwordHint?.isEmpty == true ? nil : passwordHint
        )
    }

    // MARK: - Helpers

    private static func locateAppBundle(in folderURL: URL) -> URL? {
        if folderURL.pathExtension.lowercased() == "app" {
            return folderURL
        }
        let fm = FileManager.default
        let payloadDir = folderURL.appendingPathComponent("Payload", isDirectory: true)
        if let children = try? fm.contentsOfDirectory(at: payloadDir, includingPropertiesForKeys: nil),
           let app = children.first(where: { $0.pathExtension.lowercased() == "app" }) {
            return app
        }
        if let children = try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil),
           let app = children.first(where: { $0.pathExtension.lowercased() == "app" }) {
            return app
        }
        return nil
    }

    private static func collectArchiveEntries(
        under folderURL: URL,
        prefixWithFolderName: Bool
    ) throws -> [ArchiveWriteEntry] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .posixPermissionsKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let rootPath = folderURL.standardizedFileURL.path
        let topPrefix = prefixWithFolderName ? folderURL.lastPathComponent : ""
        var entries: [ArchiveWriteEntry] = []

        for case let itemURL as URL in enumerator {
            let stdPath = itemURL.standardizedFileURL.path
            guard stdPath.hasPrefix(rootPath + "/") else { continue }
            let sub = String(stdPath.dropFirst(rootPath.count + 1))
            let combined = topPrefix.isEmpty ? sub : "\(topPrefix)/\(sub)"
            guard let archPath = ArchivePath(rawValue: combined) else { continue }
            let values = try itemURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .posixPermissionsKey])
            if values.isDirectory == true {
                entries.append(ArchiveWriteEntry(path: archPath, kind: .directory))
            } else if values.isRegularFile == true {
                let perms = values.posixPermissions ?? 0o644
                let content = try Data(contentsOf: itemURL)
                entries.append(ArchiveWriteEntry(
                    path: archPath,
                    kind: .regularFile(isExecutable: (perms & 0o111) != 0),
                    content: content
                ))
            }
        }
        return entries.sorted { $0.path.rawValue < $1.path.rawValue }
    }

    static func uniqueDestinationURL(
        baseName: String,
        pathExtension: String?,
        in parent: URL
    ) -> URL {
        let fm = FileManager.default
        for idx in 1...500 {
            let numbered = idx == 1 ? baseName : "\(baseName)-\(idx)"
            let fileName: String
            if let ext = pathExtension, !ext.isEmpty {
                fileName = "\(numbered).\(ext)"
            } else {
                fileName = numbered
            }
            let candidate = parent.appendingPathComponent(fileName)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        let fallback = "\(baseName)-\(UUID().uuidString.prefix(6))"
        if let ext = pathExtension, !ext.isEmpty {
            return parent.appendingPathComponent("\(fallback).\(ext)")
        }
        return parent.appendingPathComponent(fallback)
    }
}
