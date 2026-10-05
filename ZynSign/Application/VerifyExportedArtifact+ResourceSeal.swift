import Foundation

extension VerifyExportedArtifact {

    /// Re-reads the resource seal and every file resource it covers.
    ///
    /// The seal is checked twice over. Its own bytes are digested and held
    /// against the CodeDirectory's slot-3 digest, which is what ties the seal
    /// to the signature; then each sealed file is re-read and re-digested,
    /// which is what ties the bundle's resources to the seal. Both are
    /// recomputed here from the artifact's bytes.
    func verifyResourceSeal(
        reader: any ArchiveReader,
        table: [ArchiveEntry],
        bundlePath: ArchivePath,
        declaredSealDigest: Data?,
        collector: inout ArtifactVerificationCollector
    ) throws {
        guard let seal = readResourceSeal(reader: reader, table: table, bundlePath: bundlePath, collector: &collector) else {
            return
        }
        collector.record(
            .resourceSeal,
            .note,
            "The resource seal records \(seal.document.files2.count) entr\(seal.document.files2.count == 1 ? "y" : "ies")."
        )
        verifySealBinding(seal.bytes, declaredDigest: declaredSealDigest, collector: &collector)
        let coverage = inspectSealedResources(
            seal.document.files2,
            reader: reader,
            bundlePath: bundlePath,
            collector: &collector
        )
        recordSealCoverage(coverage, totalEntries: seal.document.files2.count, collector: &collector)
    }

    private struct ResourceSeal {
        let bytes: Data
        let document: CodeResourcesDocument
    }

    private struct SealCoverage {
        var checkedFiles = 0
        var readBytes = 0
        var mismatches = 0
        var unreadable = 0
        var skipped = 0
        var nestedChecked = 0
        var reachedTotalBound = false
    }

    private enum SealEntryInspection {
        case complete
        case stop
    }

    private func readResourceSeal(
        reader: any ArchiveReader,
        table: [ArchiveEntry],
        bundlePath: ArchivePath,
        collector: inout ArtifactVerificationCollector
    ) -> ResourceSeal? {
        guard let sealPath = ArchivePath(rawValue: bundlePath.rawValue + "/_CodeSignature/CodeResources") else {
            collector.record(.resourceSeal, .error, "The bundle's seal location cannot be named.")
            return nil
        }
        guard table.contains(where: { $0.path == sealPath }), reader.containsEntrySafe(at: sealPath) else {
            collector.record(.resourceSeal, .error, "The bundle carries no resource seal.")
            return nil
        }
        guard let sealBytes = try? reader.readEntryData(at: sealPath, maximumBytes: archiveLimits.maximumInspectionReadBytes) else {
            collector.record(.resourceSeal, .error, "The bundle's resource seal could not be read.")
            return nil
        }
        do {
            return ResourceSeal(bytes: sealBytes, document: try CodeResourcesParser.parse(sealBytes))
        } catch {
            collector.record(.resourceSeal, .error, "The bundle's resource seal could not be parsed.")
            return nil
        }
    }

    private func verifySealBinding(
        _ sealBytes: Data,
        declaredDigest: Data?,
        collector: inout ArtifactVerificationCollector
    ) {
        guard let declaredDigest else {
            collector.record(
                .resourceSeal,
                .warning,
                "The signature records no seal digest, so the seal is not bound to the signature."
            )
            return
        }
        guard let computed = try? digest.digest(sealBytes, algorithm: .sha256) else {
            collector.record(.resourceSeal, .unsupported, "The resource seal could not be digested.")
            return
        }
        if computed.bytes == declaredDigest {
            collector.record(.resourceSeal, .note, "The signature's seal digest matches the seal's own bytes.")
        } else {
            collector.record(
                .resourceSeal,
                .error,
                "The signature's recorded seal digest does not match the resource seal's own bytes."
            )
        }
    }

    private func inspectSealedResources(
        _ entries: [CodeResourcesFileEntry],
        reader: any ArchiveReader,
        bundlePath: ArchivePath,
        collector: inout ArtifactVerificationCollector
    ) -> SealCoverage {
        var coverage = SealCoverage()
        for entry in entries {
            if coverage.checkedFiles + coverage.unreadable >= limits.maximumSealedResourceCount {
                coverage.reachedTotalBound = true
                break
            }
            let result: SealEntryInspection
            switch entry {
            case .file(let fileSeal):
                result = inspectFileSeal(fileSeal, reader: reader, bundlePath: bundlePath, coverage: &coverage, collector: &collector)
            case .nestedCode(let nestedSeal):
                result = inspectNestedSeal(nestedSeal, reader: reader, bundlePath: bundlePath, coverage: &coverage, collector: &collector)
            }
            if case .stop = result { break }
        }
        return coverage
    }

    private func inspectFileSeal(
        _ fileSeal: FileResourceSeal,
        reader: any ArchiveReader,
        bundlePath: ArchivePath,
        coverage: inout SealCoverage,
        collector: inout ArtifactVerificationCollector
    ) -> SealEntryInspection {
        guard let path = Self.archivePath(bundle: bundlePath, relative: fileSeal.path) else {
            coverage.skipped += 1
            return .complete
        }
        guard let data = try? reader.readEntryData(at: path, maximumBytes: limits.maximumSealedResourceBytes) else {
            coverage.unreadable += 1
            return .complete
        }
        coverage.readBytes += data.count
        guard coverage.readBytes <= limits.maximumTotalSealedReadBytes else {
            coverage.reachedTotalBound = true
            return .stop
        }
        guard let computed = try? digest.digest(data, algorithm: .sha256) else {
            coverage.unreadable += 1
            return .complete
        }
        coverage.checkedFiles += 1
        if computed.bytes != fileSeal.hash2 {
            recordSealMismatch(
                "The sealed resource \(fileSeal.path.rawValue) does not match the digest the seal records for it.",
                coverage: &coverage,
                collector: &collector
            )
        }
        return .complete
    }

    private func inspectNestedSeal(
        _ nestedSeal: NestedCodeResourceSeal,
        reader: any ArchiveReader,
        bundlePath: ArchivePath,
        coverage: inout SealCoverage,
        collector: inout ArtifactVerificationCollector
    ) -> SealEntryInspection {
        guard let path = Self.archivePath(bundle: bundlePath, relative: nestedSeal.path) else {
            coverage.skipped += 1
            return .complete
        }
        coverage.nestedChecked += 1
        guard let hash = nestedCodeDirectoryHash(reader: reader, path: path) else {
            coverage.unreadable += 1
            return .complete
        }
        guard hash == nestedSeal.codeDirectoryHash else {
            recordSealMismatch(
                "The nested code \(nestedSeal.path.rawValue) does not match the code-directory hash the seal records for it.",
                coverage: &coverage,
                collector: &collector
            )
            return .complete
        }
        coverage.checkedFiles += 1
        return .complete
    }

    private func recordSealMismatch(
        _ detail: String,
        coverage: inout SealCoverage,
        collector: inout ArtifactVerificationCollector
    ) {
        coverage.mismatches += 1
        guard coverage.mismatches <= Self.maximumDetailedFindings else { return }
        collector.record(.sealedResourceDigest, .error, detail)
    }

    private func recordSealCoverage(
        _ coverage: SealCoverage,
        totalEntries: Int,
        collector: inout ArtifactVerificationCollector
    ) {
        if coverage.mismatches > Self.maximumDetailedFindings {
            collector.record(
                .sealedResourceDigest,
                .error,
                "\(coverage.mismatches) sealed resources do not match the digests the seal records for them; the first \(Self.maximumDetailedFindings) are listed."
            )
        }
        if coverage.unreadable > 0 {
            collector.record(
                .sealedResourceUnreadable,
                coverage.mismatches > 0 ? .warning : .unsupported,
                "\(coverage.unreadable) sealed resource\(coverage.unreadable == 1 ? " could" : "s could") not be read within verification's bounds."
            )
        }
        if coverage.skipped > 0 {
            collector.record(
                .sealedResourceUnreadable,
                .warning,
                "\(coverage.skipped) seal entr\(coverage.skipped == 1 ? "y names a path" : "ies name paths") verification did not read."
            )
        }
        recordCoverageConclusion(coverage, totalEntries: totalEntries, collector: &collector)
    }

    private func recordCoverageConclusion(
        _ coverage: SealCoverage,
        totalEntries: Int,
        collector: inout ArtifactVerificationCollector
    ) {
        if coverage.reachedTotalBound {
            collector.record(
                .sealCoverage,
                .warning,
                "The seal lists more content than verification reads, so only \(coverage.checkedFiles + coverage.unreadable) of \(totalEntries) entries were checked."
            )
        } else {
            collector.record(
                .sealCoverage,
                .note,
                "Every resource the seal covers was re-read and re-digested (\(coverage.checkedFiles) sealed file\(coverage.checkedFiles == 1 ? "" : "s"), \(coverage.nestedChecked) nested code reference\(coverage.nestedChecked == 1 ? "" : "s"))."
            )
        }
    }

    /// The SHA-256 digest of a nested binary's CodeDirectory blob, which is
    /// what a seal's `cdhash` entry names. Returns `nil` when the binary
    /// cannot be read or carries no CodeDirectory, so an unreadable
    /// reference is reported rather than assumed to match.
    private func nestedCodeDirectoryHash(reader: any ArchiveReader, path: ArchivePath) -> Data? {
        guard let bytes = try? reader.readEntryData(at: path, maximumBytes: limits.maximumSealedResourceBytes) else {
            return nil
        }
        let inspection = inspector.inspect(bytes: bytes)
        let slices: [MachOCodeSignatureSliceInspection]
        switch inspection {
        case .thin(let slice): slices = [slice]
        case .universal(let list): slices = list
        case .malformedMachO, .malformedSignature: return nil
        }
        guard let slice = slices.first,
              case .valid(let embedded) = slice.existingSignature,
              let directoryEntry = embedded.superBlob.entries.first(where: { $0.slot == .codeDirectory }),
              directoryEntry.fileRange.lowerBound >= bytes.startIndex,
              directoryEntry.fileRange.upperBound <= bytes.endIndex else {
            return nil
        }
        let directoryBytes = bytes.subdata(in: directoryEntry.fileRange)
        guard let computed = try? digest.digest(directoryBytes, algorithm: .sha256) else { return nil }
        return Data(computed.bytes.prefix(NestedCodeResourceSeal.codeDirectoryHashByteCount))
    }
}
