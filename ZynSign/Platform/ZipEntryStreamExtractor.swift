import Compression
import Foundation

/// Streams one entry out of a ZIP archive into a file, safely.
///
/// This is how the Import Hub extracts a package the user chose from inside
/// a `.zip`. It never extracts "the archive" — only the single entry it is
/// asked for, into a destination the caller chose from a fresh identifier —
/// so no name inside the archive can decide where anything is written.
///
/// Every protection is applied before or while bytes are written, not
/// afterwards:
///
/// - The entry must appear exactly once in the central directory, be a
///   regular file, be unencrypted, and use a method ZynSign decodes
///   (stored or DEFLATE). Links, directories, and duplicates are refused.
/// - The declared size is bounded, and so is the ratio between declared
///   and stored size, so a small archive cannot claim to unpack into an
///   enormous one.
/// - Output is counted as it is produced and extraction stops the moment it
///   exceeds the declared size; the result must match the declared size and
///   the archive's CRC-32 exactly.
/// - The archive is read in bounded chunks and the output is written in
///   bounded chunks: neither is ever held in memory whole.
/// - Cancellation is checked between chunks.
///
/// The caller removes the destination if extraction throws.
struct ZipEntryStreamExtractor {

    /// The largest entry the extractor writes — the same ceiling the
    /// import policy applies to a selected file.
    static let defaultMaximumOutputBytes = 4 * 1_024 * 1_024 * 1_024

    private static let storedMethod: UInt16 = 0
    private static let deflateMethod: UInt16 = 8
    private static let localFileHeaderSize = 30
    private static let localFileHeaderSignature: UInt32 = 0x0403_4B50

    let archive: URL
    let limits: ArchiveLimits
    let maximumOutputBytes: Int
    let chunkSize: Int

    init(
        archive: URL,
        limits: ArchiveLimits = .default,
        maximumOutputBytes: Int = ZipEntryStreamExtractor.defaultMaximumOutputBytes,
        chunkSize: Int = 1_048_576
    ) {
        self.archive = archive
        self.limits = limits
        self.maximumOutputBytes = max(0, maximumOutputBytes)
        self.chunkSize = max(1, chunkSize)
    }

    private struct EntrySource {
        let reader: BoundedReader
        let record: ZipCentralDirectoryRecord
        let contentOffset: Int
    }

    /// Extracts the entry at `path` into `destination`, reporting the bytes
    /// written as `.copying` progress.
    func extract(
        _ path: ArchivePath,
        to destination: URL,
        reporting progress: (any ImportProgressReporting)?
    ) throws {
        let handle = try openArchive()
        defer { try? handle.close() }

        let source = try entrySource(for: path, handle: handle)
        let writer = try outputHandle(at: destination)
        defer { try? writer.close() }

        var sink = OutputSink(
            writer: writer,
            expectedByteCount: source.record.entry.uncompressedSize,
            path: path,
            progress: progress
        )
        progress?.report(ImportProgress(
            stage: .copying,
            completedUnitCount: 0,
            totalUnitCount: source.record.entry.uncompressedSize
        ))
        try streamEntry(source, path: path) { chunk in
            try sink.consume(chunk)
        }
        try sink.finish(expectedChecksum: source.record.checksum)
    }

    private func openArchive() throws -> FileHandle {
        do {
            return try FileHandle(forReadingFrom: archive)
        } catch {
            throw ZynSignError.unreadableArtifact(
                diagnosticDetail: "The archive's working copy could not be opened.",
                underlyingError: error
            )
        }
    }

    private func entrySource(for path: ArchivePath, handle: FileHandle) throws -> EntrySource {
        let fileSize = try archiveSize(of: handle)
        let reader = BoundedReader(handle: handle, fileSize: fileSize)
        let records = try ZipCentralDirectoryScanner.scan(fileSize: fileSize, limits: limits) { offset, count in
            try reader.read(at: offset, count: count)
        }
        let record = try Self.uniqueRecord(for: path, in: records)
        try Self.checkEntry(record, path: path, maximumOutputBytes: maximumOutputBytes, limits: limits)
        let contentOffset = try Self.contentOffset(for: record, path: path, reader: reader)
        guard contentOffset <= fileSize, record.entry.compressedSize <= fileSize - contentOffset else {
            throw ZynSignError.archiveEntryUnreadable(
                diagnosticDetail: "The content of '\(path.rawValue)' extends beyond the archive."
            )
        }
        return EntrySource(reader: reader, record: record, contentOffset: contentOffset)
    }

    private func archiveSize(of handle: FileHandle) throws -> Int {
        do {
            guard let size = Int(exactly: try handle.seekToEnd()) else {
                throw ZynSignError.unreadableArtifact(diagnosticDetail: "The archive's size cannot be addressed.")
            }
            return size
        } catch let error as ZynSignError {
            throw error
        } catch {
            throw ZynSignError.unreadableArtifact(
                diagnosticDetail: "The archive's size could not be read.",
                underlyingError: error
            )
        }
    }

    private func outputHandle(at destination: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw ZynSignError.importTemporaryStorageFailure(
                diagnosticDetail: "The extracted package's working copy could not be created."
            )
        }
        do {
            return try FileHandle(forWritingTo: destination)
        } catch {
            throw ZynSignError.importTemporaryStorageFailure(underlyingError: error)
        }
    }

    private func streamEntry(
        _ source: EntrySource,
        path: ArchivePath,
        consume: @escaping (Data) throws -> Void
    ) throws {
        if source.record.compressionMethod == Self.storedMethod {
            try stream(from: source.reader, at: source.contentOffset, count: source.record.entry.compressedSize, into: consume)
            return
        }
        try streamDeflatedEntry(source, path: path, consume: consume)
    }

    private func streamDeflatedEntry(
        _ source: EntrySource,
        path: ArchivePath,
        consume: @escaping (Data) throws -> Void
    ) throws {
        var sinkError: (any Error)?
        let filter = try OutputFilter(.decompress, using: .zlib, bufferCapacity: 65_536) { output in
            guard let output, sinkError == nil else { return }
            do {
                try consume(output)
            } catch {
                sinkError = error
                throw error
            }
        }
        do {
            try stream(from: source.reader, at: source.contentOffset, count: source.record.entry.compressedSize) {
                chunk in try filter.write(chunk)
            }
            try filter.finalize()
        } catch let error as ZynSignError {
            // Cancellation and read failures keep their own meaning.
            throw sinkError ?? error
        } catch {
            throw sinkError ?? ZynSignError.archiveEntryUnreadable(
                diagnosticDetail: "The compressed content of '\(path.rawValue)' could not be decoded.",
                underlyingError: error
            )
        }
        // A refusal raised while writing is authoritative even if the decoder
        // chose not to pass it on.
        if let sinkError { throw sinkError }
    }

    // MARK: - Checks

    private static func uniqueRecord(
        for path: ArchivePath,
        in records: [ZipCentralDirectoryRecord]
    ) throws -> ZipCentralDirectoryRecord {
        let matches = records.filter { $0.entry.path == path }
        guard let record = matches.first else {
            throw ZynSignError.archiveEntryUnreadable(
                diagnosticDetail: "The archive has no entry '\(path.rawValue)'."
            )
        }
        guard matches.count == 1 else {
            throw ZynSignError.unsafeArchiveEntry(
                diagnosticDetail: "The archive lists '\(path.rawValue)' more than once."
            )
        }
        return record
    }

    private static func checkEntry(
        _ record: ZipCentralDirectoryRecord,
        path: ArchivePath,
        maximumOutputBytes: Int,
        limits: ArchiveLimits
    ) throws {
        guard record.entry.kind == .regularFile else {
            throw ZynSignError.unsafeArchiveEntry(
                diagnosticDetail: "'\(path.rawValue)' is \(record.entry.kind.displayName), not a regular file."
            )
        }
        guard !record.isEncrypted else {
            throw ZynSignError.unsupportedArchiveFeature(
                diagnosticDetail: "'\(path.rawValue)' is encrypted."
            )
        }
        guard record.compressionMethod == storedMethod || record.compressionMethod == deflateMethod else {
            throw ZynSignError.unsupportedArchiveFeature(
                diagnosticDetail: "'\(path.rawValue)' uses compression method \(record.compressionMethod)."
            )
        }

        let declared = record.entry.uncompressedSize
        let stored = record.entry.compressedSize
        guard declared <= maximumOutputBytes else {
            throw ZynSignError.archiveResourceLimitExceeded(
                diagnosticDetail: "'\(path.rawValue)' declares \(declared) bytes, above the \(maximumOutputBytes)-byte ceiling."
            )
        }
        if record.compressionMethod == storedMethod {
            guard declared == stored else {
                throw ZynSignError.archiveEntryUnreadable(
                    diagnosticDetail: "'\(path.rawValue)' is stored uncompressed but declares two different sizes."
                )
            }
        } else if declared > 0 {
            guard stored > 0 else {
                throw ZynSignError.archiveResourceLimitExceeded(
                    diagnosticDetail: "'\(path.rawValue)' declares content but stores none."
                )
            }
            let (bound, overflow) = stored.multipliedReportingOverflow(by: max(1, limits.maximumCompressionRatio))
            guard overflow || declared <= bound else {
                throw ZynSignError.archiveResourceLimitExceeded(
                    diagnosticDetail: "'\(path.rawValue)' declares a compression ratio above the permitted bound."
                )
            }
        }
    }

    private static func contentOffset(
        for record: ZipCentralDirectoryRecord,
        path: ArchivePath,
        reader: BoundedReader
    ) throws -> Int {
        let header = try reader.read(at: record.localHeaderOffset, count: localFileHeaderSize)
        guard ZipField.uint32(header, 0) == localFileHeaderSignature else {
            throw ZynSignError.archiveEntryUnreadable(
                diagnosticDetail: "The entry header for '\(path.rawValue)' does not begin with a recognized signature."
            )
        }
        guard ZipField.uint16(header, 8) == record.compressionMethod else {
            throw ZynSignError.archiveEntryUnreadable(
                diagnosticDetail: "The entry header for '\(path.rawValue)' disagrees with the archive's directory about its encoding."
            )
        }
        let nameLength = Int(ZipField.uint16(header, 26))
        let extraLength = Int(ZipField.uint16(header, 28))
        return record.localHeaderOffset + localFileHeaderSize + nameLength + extraLength
    }

    // MARK: - Streaming

    private func stream(
        from reader: BoundedReader,
        at offset: Int,
        count: Int,
        into consume: (Data) throws -> Void
    ) throws {
        var position = offset
        let end = offset + count
        while position < end {
            if Task.isCancelled {
                throw ZynSignError.importCancelled()
            }
            let length = min(chunkSize, end - position)
            let chunk = try reader.readData(at: position, count: length)
            try consume(chunk)
            position += length
        }
    }
}

// MARK: - Reading

/// Reads bounded ranges of the archive, refusing any range outside it.
private final class BoundedReader {

    private let handle: FileHandle
    private let fileSize: Int

    init(handle: FileHandle, fileSize: Int) {
        self.handle = handle
        self.fileSize = fileSize
    }

    func read(at offset: Int, count: Int) throws -> [UInt8] {
        Array(try readData(at: offset, count: count))
    }

    func readData(at offset: Int, count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset <= fileSize, count <= fileSize - offset else {
            throw ZynSignError.unreadableArtifact(
                diagnosticDetail: "A read outside the archive's own bounds was requested."
            )
        }
        guard count > 0 else { return Data() }
        do {
            try handle.seek(toOffset: UInt64(offset))
        } catch {
            throw ZynSignError.unreadableArtifact(
                diagnosticDetail: "The archive could not be positioned for reading.",
                underlyingError: error
            )
        }
        var collected = Data()
        collected.reserveCapacity(count)
        while collected.count < count {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: count - collected.count)
            } catch {
                throw ZynSignError.unreadableArtifact(
                    diagnosticDetail: "The archive could not be read.",
                    underlyingError: error
                )
            }
            guard let chunk, !chunk.isEmpty else {
                throw ZynSignError.unreadableArtifact(
                    diagnosticDetail: "The archive ended before an expected structure was complete."
                )
            }
            collected.append(chunk)
        }
        return collected
    }
}

// MARK: - Writing

/// Counts, checksums, and writes extracted bytes, refusing any byte beyond
/// the declared size.
private struct OutputSink {

    let writer: FileHandle
    let expectedByteCount: Int
    let path: ArchivePath
    let progress: (any ImportProgressReporting)?

    private(set) var writtenByteCount = 0
    private var checksum = ZipChecksum()

    init(writer: FileHandle, expectedByteCount: Int, path: ArchivePath, progress: (any ImportProgressReporting)?) {
        self.writer = writer
        self.expectedByteCount = expectedByteCount
        self.path = path
        self.progress = progress
    }

    mutating func consume(_ data: Data) throws {
        guard !data.isEmpty else { return }
        guard data.count <= expectedByteCount - writtenByteCount else {
            throw ZynSignError.archiveResourceLimitExceeded(
                diagnosticDetail: "'\(path.rawValue)' unpacks to more than the size the archive declares."
            )
        }
        data.withUnsafeBytes { checksum.update($0) }
        do {
            try writer.write(contentsOf: data)
        } catch {
            throw ZynSignError.importCopyFailure(underlyingError: error)
        }
        writtenByteCount += data.count
        progress?.report(
            ImportProgress(stage: .copying, completedUnitCount: writtenByteCount, totalUnitCount: expectedByteCount)
        )
    }

    func finish(expectedChecksum: UInt32) throws {
        guard writtenByteCount == expectedByteCount else {
            throw ZynSignError.archiveEntryUnreadable(
                diagnosticDetail: "'\(path.rawValue)' unpacked to \(writtenByteCount) bytes; the archive declares \(expectedByteCount)."
            )
        }
        guard checksum.value == expectedChecksum else {
            throw ZynSignError.archiveEntryUnreadable(
                diagnosticDetail: "'\(path.rawValue)' does not match the checksum the archive records for it."
            )
        }
    }
}

/// An incremental CRC-32 (IEEE 802.3), the checksum ZIP records for every
/// entry.
struct ZipChecksum {

    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    private var state: UInt32 = 0xFFFF_FFFF

    /// The checksum of everything consumed so far.
    var value: UInt32 {
        state ^ 0xFFFF_FFFF
    }

    /// Adds `bytes` to the checksum.
    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        var crc = state
        Self.table.withUnsafeBufferPointer { table in
            for byte in bytes {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        state = crc
    }

    /// Adds `data` to the checksum.
    mutating func update(_ data: Data) {
        data.withUnsafeBytes { update($0) }
    }
}
