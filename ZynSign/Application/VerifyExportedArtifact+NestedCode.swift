import Foundation

extension VerifyExportedArtifact {

    /// Inspects every nested code bundle the bundle carries for a signature of
    /// its own.
    ///
    /// Bundle directories are found structurally — by the suffixes the
    /// platform's conventions give them — not by guessing from file names, and
    /// each one's executable is located by the convention that names it after
    /// its directory. A nested binary that cannot be read within the bound is
    /// reported as unsupported rather than as signed.
    func verifyNestedCode(
        reader: any ArchiveReader,
        table: [ArchiveEntry],
        bundlePath: ArchivePath,
        collector: inout ArtifactVerificationCollector
    ) throws {
        let directories = nestedCodeDirectories(in: table, bundlePath: bundlePath)
        guard !directories.isEmpty else {
            collector.record(.nestedCode, .note, "The bundle carries no nested code bundles.")
            return
        }
        let inspected = directories.prefix(limits.maximumNestedCodeCount)
        recordNestedCodeLimit(directories.count, inspectedCount: inspected.count, collector: &collector)
        let results = inspectNestedCodeDirectories(inspected, reader: reader)
        recordNestedCodeResults(results, collector: &collector)
    }

    private struct NestedCodeDirectory {
        let path: ArchivePath
        let name: String
    }

    private enum NestedCodeInspection {
        case signed
        case unsigned(String)
        case unreadable(String)
    }

    private struct NestedCodeResults {
        var unsigned: [String] = []
        var unreadable: [String] = []
        var signed = 0
    }

    private func nestedCodeDirectories(in table: [ArchiveEntry], bundlePath: ArchivePath) -> [NestedCodeDirectory] {
        let prefix = bundlePath.rawValue + "/"
        var directories: [NestedCodeDirectory] = []
        for entry in table {
            guard let path = entry.path, entry.kind == .directory, path.rawValue.hasPrefix(prefix) else { continue }
            let name = path.components.last ?? ""
            guard NestedCodeLocation.codeBundleSuffixes.contains(where: { NestedCodeLocation.hasSuffix(name, $0) }) else {
                continue
            }
            directories.append(NestedCodeDirectory(path: path, name: name))
        }
        return directories.sorted { $0.path.rawValue < $1.path.rawValue }
    }

    private func recordNestedCodeLimit(
        _ directoryCount: Int,
        inspectedCount: Int,
        collector: inout ArtifactVerificationCollector
    ) {
        guard directoryCount > inspectedCount else { return }
        collector.record(
            .nestedCode,
            .warning,
            "The bundle carries more nested code bundles than verification inspects; \(inspectedCount) of \(directoryCount) were inspected."
        )
    }

    private func inspectNestedCodeDirectories(
        _ directories: ArraySlice<NestedCodeDirectory>,
        reader: any ArchiveReader
    ) -> NestedCodeResults {
        var results = NestedCodeResults()
        for directory in directories {
            switch inspectNestedCodeDirectory(directory, reader: reader) {
            case .signed:
                results.signed += 1
            case .unsigned(let name):
                results.unsigned.append(name)
            case .unreadable(let name):
                results.unreadable.append(name)
            }
        }
        return results
    }

    private func inspectNestedCodeDirectory(
        _ directory: NestedCodeDirectory,
        reader: any ArchiveReader
    ) -> NestedCodeInspection {
        let executableName = NestedCodeLocation.baseName(ofBundleNamed: directory.name)
        guard !executableName.isEmpty,
              let executablePath = directory.path.appending(component: executableName),
              let bytes = try? reader.readEntryData(at: executablePath, maximumBytes: limits.maximumExecutableBytes) else {
            return .unreadable(directory.name)
        }
        switch inspector.inspect(bytes: bytes) {
        case .thin(let slice):
            if case .valid = slice.existingSignature { return .signed }
            return .unsigned(directory.name)
        case .universal(let list):
            let allSigned = list.allSatisfy { slice in
                if case .valid = slice.existingSignature { return true }
                return false
            }
            return allSigned ? .signed : .unsigned(directory.name)
        case .malformedMachO, .malformedSignature:
            return .unreadable(directory.name)
        }
    }

    private func recordNestedCodeResults(_ results: NestedCodeResults, collector: inout ArtifactVerificationCollector) {
        if !results.unsigned.isEmpty {
            collector.record(
                .nestedCode,
                .error,
                "Nested code carries no readable signature: \(results.unsigned.prefix(Self.maximumDetailedFindings).joined(separator: ", "))."
            )
        }
        if !results.unreadable.isEmpty {
            collector.record(
                .nestedCode,
                .unsupported,
                "Nested code could not be inspected: \(results.unreadable.prefix(Self.maximumDetailedFindings).joined(separator: ", "))."
            )
        }
        if results.signed > 0 {
            collector.record(
                .nestedCode,
                .note,
                "\(results.signed) nested code bundle\(results.signed == 1 ? "" : "s") carr\(results.signed == 1 ? "ies" : "y") a signature."
            )
        }
    }
}
