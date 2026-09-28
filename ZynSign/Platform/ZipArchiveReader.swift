import Foundation
import Compression

/// ZynSign's reader for ZIP-based application packages.
///
/// The reader opens a container at a location the platform layer already
/// resolved, reads its entry table from the central directory, and can produce
/// the content of one named entry within a stated bound. It never extracts the
/// container, never creates a temporary directory, and never writes anything.
///
/// Two limits matter and both are enforced here rather than trusted to a
/// caller. Every read is bounds-checked against the container's actual size,
/// so a hostile offset cannot reach outside the file. Every content read is
/// capped by the configured policy as well as by the caller's request, so a
/// small archive cannot describe work larger than itself.
///
/// Scope is deliberately partial, matching the scanner: reading only, stored
/// and deflate encodings only, and no decryption. Anything outside that is
/// reported as unsupported rather than approximated.
final class ZipArchiveReader: ArchiveReader {

    /// The encoding a container uses for content it stores byte-for-byte.
    private static let storedMethod: UInt16 = 0

    /// The encoding a container uses for raw DEFLATE content.
    private static let deflateMethod: UInt16 = 8

    private static let localFileHeaderSize = 30
    private static let localFileHeaderSignature: UInt32 = 0x0403_4B50

    private let location: URL
    private let limits: ArchiveLimits

    private var handle: FileHandle?
    private var fileSize = 0
    private var records: [ZipCentralDirectoryRecord] = []
    private var recordsByPath: [ArchivePath: ZipCentralDirectoryRecord] = [:]
    private var isOpen = false
    private var isClosed = false

    /// Creates a reader for the container at `location`, applying `limits`.
    ///
    /// Nothing is read until the first call that needs the container, and the
    /// reader holds no open handle before then.
    init(location: URL, limits: ArchiveLimits = .default) {
        self.location = location
        self.limits = limits
    }

    deinit {
        close()
    }

    // MARK: - ArchiveReader

    func readEntryTable() throws -> [ArchiveEntry] {
        try openIfNeeded()
        return records.map { $0.entry }
    }

    func containsEntry(at path: ArchivePath) throws -> Bool {
        try openIfNeeded()
        return recordsByPath[path] != nil
    }

    func entryKind(at path: ArchivePath) throws -> ArchiveEntryKind? {
        try openIfNeeded()
        return recordsByPath[path]?.entry.kind
    }

    func readEntryData(at path: ArchivePath, maximumBytes: Int) throws -> Data {
        try openIfNeeded()
        guard let record = recordsByPath[path] else {
            throw ZynSignError.invalidArtifact(
                diagnosticDetail: "The archive records no entry at '\(path.rawValue)'."
            )
        }
        guard !record.isEncrypted else {
            throw ZynSignError.unsupportedArchiveFeature(
                diagnosticDetail: "The entry '\(path.rawValue)' is encrypted, which ZynSign does not support."
            )
        }
        guard record.compressionMethod == Self.storedMethod
            || record.compressionMethod == Self.deflateMethod else {
            throw ZynSignError.unsupportedArchiveFeature(
                diagnosticDetail: "The entry '\(path.rawValue)' uses container encoding \(record.compressionMethod), which ZynSign does not support."
            )
        }

        let bound = min(max(0, maximumBytes), limits.maximumInspectionReadBytes)
        guard record.entry.compressedSize <= bound, record.entry.uncompressedSize <= bound else {
            throw ZynSignError.archiveResourceLimitExceeded(
                diagnosticDetail: "The entry '\(path.rawValue)' declares \(record.entry.uncompressedSize) expanded bytes from \(record.entry.compressedSize) stored bytes, beyond the accepted maximum of \(bound)."
            )
        }

        let contentOffset = try contentOffset(for: record, path: path)
        guard contentOffset + record.entry.compressedSize <= fileSize else {
            throw ZynSignError.archiveEntryUnreadable(
                diagnosticDetail: "The entry '\(path.rawValue)' extends past the end of the archive."
            )
        }

        let storedBytes = try readBytes(at: contentOffset, count: record.entry.compressedSize)
        let expanded: Data
        if record.compressionMethod == Self.storedMethod {
            expanded = Data(storedBytes)
        } else {
            expanded = try Self.inflate(storedBytes, expectedSize: record.entry.uncompressedSize)
        }

        guard expanded.count == record.entry.uncompressedSize else {
            throw ZynSignError.archiveEntryUnreadable(
                diagnosticDetail: "The entry '\(path.rawValue)' produced \(expanded.count) bytes but declares \(record.entry.uncompressedSize)."
            )
        }
        guard Self.checksum(of: expanded) == record.checksum else {
            throw ZynSignError.archiveEntryUnreadable(
                diagnosticDetail: "The entry '\(path.rawValue)' does not match the checksum the archive records for it."
            )
        }
        return expanded
    }

    func readEntryPrefix(at path: ArchivePath, maximumBytes: Int) throws -> Data {
        try openIfNeeded()
        guard let record = recordsByPath[path] else {
            throw ZynSignError.invalidArtifact(
                diagnosticDetail: "The archive records no entry at '\(path.rawValue)'."
            )
        }
        guard !record.isEncrypted else {
            throw ZynSignError.unsupportedArchiveFeature(
                diagnosticDetail: "The entry '\(path.rawValue)' is encrypted, which ZynSign does not support."
            )
        }
        guard record.compressionMethod == Self.storedMethod
            || record.compressionMethod == Self.deflateMethod else {
            throw ZynSignError.unsupportedArchiveFeature(
                diagnosticDetail: "The entry '\(path.rawValue)' uses container encoding \(record.compressionMethod), which ZynSign does not support."
            )
        }

        let bound = min(max(0, maximumBytes), limits.maximumInspectionReadBytes)
        // A complete entry stays on the checksum-verified path. A larger entry
        // returns a prefix and does not claim the whole-entry checksum.
        if record.entry.compressedSize <= bound, record.entry.uncompressedSize <= bound {
            return try readEntryData(at: path, maximumBytes: bound)
        }
        guard bound > 0 else { return Data() }

        let contentOffset = try contentOffset(for: record, path: path)
        if record.compressionMethod == Self.storedMethod {
            let count = min(bound, record.entry.uncompressedSize, record.entry.compressedSize)
            guard count >= 0, contentOffset <= fileSize, count <= fileSize - contentOffset else {
                throw ZynSignError.archiveEntryUnreadable(
                    diagnosticDetail: "The entry '\(path.rawValue)' extends past the end of the archive."
                )
            }
            return Data(try readBytes(at: contentOffset, count: count))
        }

        let compressedCap = min(record.entry.compressedSize, bound + 64 * 1_024)
        guard contentOffset <= fileSize, compressedCap <= fileSize - contentOffset else {
            throw ZynSignError.archiveEntryUnreadable(
                diagnosticDetail: "The entry '\(path.rawValue)' extends past the end of the archive."
            )
        }
        let stored = try readBytes(at: contentOffset, count: compressedCap)
        return try Self.inflatePrefix(stored, maximumOutputBytes: bound)
    }

    func close() {
        releaseResources()
        isClosed = true
    }

    /// Drops every resource the reader holds, without marking it closed. Used
    /// both by `close()` and to unwind a failed open.
    private func releaseResources() {
        if let handle = handle {
            try? handle.close()
        }
        handle = nil
        records = []
        recordsByPath = [:]
        fileSize = 0
        isOpen = false
    }

    // MARK: - Opening

    private func openIfNeeded() throws {
        if isOpen { return }
        guard !isClosed else {
            throw ZynSignError.artifactNotAvailable(
                diagnosticDetail: "The archive reader was used after it was closed."
            )
        }

        do {
            let fileHandle = try FileHandle(forReadingFrom: location)
            handle = fileHandle
            let size = try fileHandle.seekToEnd()
            guard let fileSize = Int(exactly: size) else {
                throw ZynSignError.unreadableArtifact(
                    diagnosticDetail: "The package is larger than this platform can address."
                )
            }
            self.fileSize = fileSize

            let scanned = try ZipCentralDirectoryScanner.scan(
                fileSize: fileSize,
                limits: limits
            ) { offset, count in
                try self.readBytes(at: offset, count: count)
            }

            var index: [ArchivePath: ZipCentralDirectoryRecord] = [:]
            for record in scanned {
                if let path = record.entry.path, index[path] == nil {
                    index[path] = record
                }
            }
            records = scanned
            recordsByPath = index
            isOpen = true
        } catch {
            releaseResources()
            if let zynSignError = error as? ZynSignError {
                throw zynSignError
            }
            throw ZynSignError.unreadableArtifact(
                diagnosticDetail: "The package could not be opened for reading.",
                underlyingError: error
            )
        }
    }

    // MARK: - Bounded reading

    private func readBytes(at offset: Int, count: Int) throws -> [UInt8] {
        guard let handle = handle else {
            throw ZynSignError.unreadableArtifact(
                diagnosticDetail: "The package is not open for reading."
            )
        }
        guard offset >= 0, count >= 0, offset + count <= fileSize else {
            throw ZynSignError.unreadableArtifact(
                diagnosticDetail: "A read outside the package's own bounds was requested."
            )
        }
        guard count > 0 else { return [] }

        do {
            try handle.seek(toOffset: UInt64(offset))
        } catch {
            throw ZynSignError.unreadableArtifact(
                diagnosticDetail: "The package could not be positioned for reading.",
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
                    diagnosticDetail: "The package could not be read.",
                    underlyingError: error
                )
            }
            guard let chunk = chunk, !chunk.isEmpty else {
                throw ZynSignError.unreadableArtifact(
                    diagnosticDetail: "The package ended before an expected structure was complete."
                )
            }
            collected.append(chunk)
        }
        return Array(collected)
    }

    /// Resolves where an entry's content begins, verifying that the container's
    /// own local header agrees with its central directory before any content is
    /// read from that offset.
    private func contentOffset(for record: ZipCentralDirectoryRecord, path: ArchivePath) throws -> Int {
        guard record.localHeaderOffset >= 0,
              record.localHeaderOffset + Self.localFileHeaderSize <= fileSize else {
            throw ZynSignError.archiveEntryUnreadable(
                diagnosticDetail: "The entry header for '\(path.rawValue)' lies outside the archive."
            )
        }
        let header = try readBytes(at: record.localHeaderOffset, count: Self.localFileHeaderSize)
        guard ZipField.uint32(header, 0) == Self.localFileHeaderSignature else {
            throw ZynSignError.archiveEntryUnreadable(
                diagnosticDetail: "The entry header for '\(path.rawValue)' does not begin with a recognized signature."
            )
        }
        guard ZipField.uint16(header, 8) == record.compressionMethod else {
            throw ZynSignError.archiveEntryUnreadable(
                diagnosticDetail: "The entry header for '\(path.rawValue)' disagrees with the archive's directory about its encoding."
            )
        }
        // A container that streams an entry records no sizes in its local
        // header, so agreement is only checkable when the flag is absent.
        if (ZipField.uint16(header, 6) & 0x0008) == 0 {
            let localCompressedSize = Int(ZipField.uint32(header, 18))
            guard localCompressedSize == record.entry.compressedSize else {
                throw ZynSignError.archiveEntryUnreadable(
                    diagnosticDetail: "The entry header for '\(path.rawValue)' disagrees with the archive's directory about its size."
                )
            }
        }

        let nameLength = Int(ZipField.uint16(header, 26))
        let extraLength = Int(ZipField.uint16(header, 28))
        let contentOffset = record.localHeaderOffset + Self.localFileHeaderSize + nameLength + extraLength
        guard contentOffset <= fileSize else {
            throw ZynSignError.archiveEntryUnreadable(
                diagnosticDetail: "The entry header for '\(path.rawValue)' places its content outside the archive."
            )
        }
        return contentOffset
    }

    // MARK: - Expansion

    /// Expands raw DEFLATE content into at most `expectedSize` bytes.
    ///
    /// The destination is sized from the container's declared expanded size,
    /// which the caller has already bounded, so the allocation is bounded
    /// before any expansion happens. An entry that expands beyond what the
    /// container declares is treated as malformed rather than accommodated.
    private static func inflate(_ compressed: [UInt8], expectedSize: Int) throws -> Data {
        guard expectedSize >= 0 else {
            throw ZynSignError.archiveEntryUnreadable(
                diagnosticDetail: "The archive declares a negative expanded size for an entry."
            )
        }
        guard !compressed.isEmpty else { return Data() }
        let capacity = expectedSize + 1
        var destination = [UInt8](repeating: 0, count: capacity)

        let produced = try compressed.withUnsafeBufferPointer { source -> Int in
            try destination.withUnsafeMutableBufferPointer { target -> Int in
                guard let targetAddress = target.baseAddress,
                      let sourceAddress = source.baseAddress else {
                    throw ZynSignError.archiveEntryUnreadable(
                        diagnosticDetail: "The entry's compressed data could not be addressed for expansion."
                    )
                }
                return compression_decode_buffer(
                    targetAddress,
                    capacity,
                    sourceAddress,
                    compressed.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        guard produced > 0 || compressed.isEmpty else {
            throw ZynSignError.archiveEntryUnreadable(
                diagnosticDetail: "The entry's compressed data could not be expanded."
            )
        }
        guard produced <= expectedSize else {
            throw ZynSignError.archiveEntryUnreadable(
                diagnosticDetail: "The entry expanded to more bytes than the archive declares."
            )
        }
        return Data(destination.prefix(produced))
    }

    /// Expands at most `maximumOutputBytes` of a raw DEFLATE stream.
    ///
    /// The input may be a prefix of a larger entry. The stream is not finalized,
    /// because a truncated DEFLATE member is not a complete member: bytes
    /// produced before the input runs out are the prefix, and a stream that
    /// produces nothing is refused. The whole-entry checksum is not computed
    /// here.
    private static func inflatePrefix(_ compressed: [UInt8], maximumOutputBytes: Int) throws -> Data {
        guard maximumOutputBytes > 0 else { return Data() }
        guard !compressed.isEmpty else { return Data() }

        // Xcode 26 imports the stream's pointer fields as non-nullable, so the
        // struct cannot be seeded with `nil`. Both pointers are overwritten on
        // every process call below before anything reads them, so a single
        // placeholder byte satisfies the initializer and is released together
        // with the stream (defers run in reverse order: destroy, then free).
        let placeholder = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { placeholder.deallocate() }
        var stream = compression_stream(
            dst_ptr: placeholder,
            dst_size: 0,
            src_ptr: UnsafePointer(placeholder),
            src_size: 0,
            state: nil
        )
        let initStatus = withUnsafeMutablePointer(to: &stream) { pointer in
            compression_stream_init(pointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        }
        guard initStatus == COMPRESSION_STATUS_OK else {
            throw ZynSignError.archiveEntryUnreadable(
                diagnosticDetail: "The entry's compressed data could not be prepared for a bounded read."
            )
        }
        defer {
            withUnsafeMutablePointer(to: &stream) { pointer in
                compression_stream_destroy(pointer)
            }
        }

        var output = Data()
        output.reserveCapacity(min(maximumOutputBytes, 64 * 1_024))
        var destination = [UInt8](repeating: 0, count: 16 * 1_024)
        var sourceOffset = 0
        var iterations = 0
        let iterationLimit = compressed.count + maximumOutputBytes + 8

        while output.count < maximumOutputBytes {
            iterations += 1
            if iterations > iterationLimit { break }
            let remaining = compressed.count - sourceOffset
            if remaining <= 0 { break }
            let feed = min(remaining, 16 * 1_024)
            var produced = 0
            var consumed = 0
            let status: compression_status = compressed.withUnsafeBufferPointer { sourceBuffer in
                destination.withUnsafeMutableBufferPointer { destBuffer in
                    withUnsafeMutablePointer(to: &stream) { pointer in
                        guard let sourceBase = sourceBuffer.baseAddress,
                              let destBase = destBuffer.baseAddress else {
                            return COMPRESSION_STATUS_ERROR
                        }
                        let room = min(destBuffer.count, maximumOutputBytes - output.count)
                        pointer.pointee.src_ptr = sourceBase.advanced(by: sourceOffset)
                        pointer.pointee.src_size = feed
                        pointer.pointee.dst_ptr = destBase
                        pointer.pointee.dst_size = room
                        let status = compression_stream_process(pointer, 0)
                        consumed = feed - pointer.pointee.src_size
                        produced = room - pointer.pointee.dst_size
                        return status
                    }
                }
            }
            guard consumed >= 0, produced >= 0, consumed <= feed, produced <= destination.count else {
                throw ZynSignError.archiveEntryUnreadable(
                    diagnosticDetail: "A bounded expansion of the entry produced an inconsistent length."
                )
            }
            if produced > 0 {
                output.append(contentsOf: destination.prefix(produced))
            }
            sourceOffset += consumed
            if status == COMPRESSION_STATUS_END { break }
            if status == COMPRESSION_STATUS_ERROR || (consumed == 0 && produced == 0) {
                if output.isEmpty {
                    throw ZynSignError.archiveEntryUnreadable(
                        diagnosticDetail: "The entry's compressed data could not be expanded for a bounded read."
                    )
                }
                break
            }
        }
        if output.count > maximumOutputBytes {
            return Data(output.prefix(maximumOutputBytes))
        }
        return output
    }

    // MARK: - Checksum

    private static let checksumTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
        }
        return value
    }

    /// The container checksum of expanded content, used to detect damage or
    /// inconsistency in a single entry's stored bytes.
    private static func checksum(of data: Data) -> UInt32 {
        var value = UInt32.max
        for byte in data {
            value = (value >> 8) ^ checksumTable[Int((value ^ UInt32(byte)) & 0xFF)]
        }
        return value ^ UInt32.max
    }
}
