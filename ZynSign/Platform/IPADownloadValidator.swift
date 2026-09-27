import Foundation
import CryptoKit

/// Validates a downloaded file before it can be imported.
///
/// The check reads the archive through the existing archive boundary and the
/// existing structure and metadata readers. It does not extract the package,
/// does not import it, and does not treat a configured source as trust. A
/// failure leaves the caller's file where it is; the center moves that file
/// into isolation.
final class IPADownloadValidator: DownloadValidating {

    private let limits: ArchiveLimits
    private let maximumArtifactBytes: Int64

    init(limits: ArchiveLimits = .default, maximumArtifactBytes: Int64 = DownloadURLPolicy.maximumArtifactBytes) {
        self.limits = limits
        self.maximumArtifactBytes = maximumArtifactBytes
    }

    func validate(fileAt url: URL, expectedSHA256: String?) async -> DownloadArtifactValidation {
        let checkedAt = Date()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]))
        guard size?.isRegularFile != false, let byteCount = size?.fileSize, byteCount > 0 else {
            return failure("The download is empty or unreadable.", detail: nil, checksum: checksumResult(expected: expectedSHA256, matched: nil), at: checkedAt)
        }
        guard Int64(byteCount) <= maximumArtifactBytes else {
            return failure("The download is larger than ZynSign will accept.", detail: nil, checksum: false, at: checkedAt)
        }
        let checksum = await checksumMatch(url: url, expected: expectedSHA256)
        if checksum == false {
            return DownloadArtifactValidation(
                archiveReadable: false,
                ipaStructureAccepted: false,
                extractionReady: false,
                metadataAvailable: false,
                checksumMatched: false,
                summary: "The download's checksum does not match the source. It was kept isolated and was not imported.",
                detail: "A declared SHA-256 did not match the file. The source listing was not treated as trust.",
                checkedAt: checkedAt
            )
        }
        let reader = ZipArchiveReader(location: url, limits: limits)
        defer { reader.close() }
        let table: [ArchiveEntry]
        do {
            table = try reader.readEntryTable()
        } catch {
            return failure(
                "The download could not be read as an archive. It was kept isolated and was not imported.",
                detail: "Archive reading failed. The file was not imported.",
                checksum: checksum,
                at: checkedAt,
                archiveReadable: false
            )
        }
        let inspection = IPAStructureValidator(limits: limits).validate(entryTable: table)
        let structureOK = inspection.isValid
        let extractionReady = structureOK
        var metadataOK = false
        var detail = inspection.validation.findings.first?.detail
        if let bundle = inspection.bundle, let infoPath = IPALayout.bundleInformationPath(within: bundle.bundlePath) {
            do {
                let info = try reader.readEntryData(at: infoPath, maximumBytes: limits.maximumInspectionReadBytes)
                let examination = ApplicationMetadataReader.read(from: info)
                metadataOK = examination.isValid
                if !metadataOK {
                    detail = examination.findings.first?.detail ?? detail
                }
            } catch {
                metadataOK = false
                detail = "The bundle information file could not be read."
            }
        }
        let ready = structureOK && extractionReady && metadataOK && checksum != false
        if ready {
            return DownloadArtifactValidation(
                archiveReadable: true,
                ipaStructureAccepted: true,
                extractionReady: true,
                metadataAvailable: true,
                checksumMatched: checksum,
                summary: "The file can be read as an app package and declares metadata. It has not been imported.",
                detail: nil,
                checkedAt: checkedAt
            )
        }
        let summary: String
        if !structureOK {
            summary = "The archive does not have the expected app package layout. It was kept isolated and was not imported."
        } else if !metadataOK {
            summary = "The package does not include readable application metadata. It was kept isolated and was not imported."
        } else {
            summary = "The download did not pass validation. It was kept isolated and was not imported."
        }
        return DownloadArtifactValidation(
            archiveReadable: true,
            ipaStructureAccepted: structureOK,
            extractionReady: extractionReady,
            metadataAvailable: metadataOK,
            checksumMatched: checksum,
            summary: summary,
            detail: detail,
            checkedAt: checkedAt
        )
    }

    private func failure(
        _ summary: String,
        detail: String?,
        checksum: Bool?,
        at date: Date,
        archiveReadable: Bool = false
    ) -> DownloadArtifactValidation {
        DownloadArtifactValidation(
            archiveReadable: archiveReadable,
            ipaStructureAccepted: false,
            extractionReady: false,
            metadataAvailable: false,
            checksumMatched: checksum,
            summary: summary,
            detail: detail,
            checkedAt: date
        )
    }

    private func checksumResult(expected: String?, matched: Bool?) -> Bool? {
        guard expected != nil else { return nil }
        return matched
    }

    private func checksumMatch(url: URL, expected: String?) async -> Bool? {
        guard let expected else { return nil }
        let normalized = expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count == 64, normalized.allSatisfy(\.isHexDigit) else { return false }
        guard let actual = streamSHA256(url: url) else { return false }
        return actual == normalized
    }

    /// Streams SHA-256 so a large package is not loaded into one buffer.
    private func streamSHA256(url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunk = 1024 * 1024
        while true {
            let data: Data
            do {
                guard let next = try handle.read(upToCount: chunk), !next.isEmpty else { break }
                data = next
            } catch {
                return nil
            }
            hasher.update(data: data)
        }
        let hex = Array("0123456789abcdef")
        var text = ""
        text.reserveCapacity(64)
        for byte in hasher.finalize() {
            text.append(hex[Int(byte >> 4)])
            text.append(hex[Int(byte & 0x0F)])
        }
        return text
    }
}
