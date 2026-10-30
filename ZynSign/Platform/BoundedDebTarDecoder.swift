import Compression
import Foundation

/// Bounded in-memory expansion for compressed Debian TAR members. Input is
/// already bounded by DebArchiveParser; output is counted before every append.
/// Format and device interoperability require Apple-platform validation.
enum BoundedDebTarDecoder {
    static func decode(_ input: Data, kind: DebArchiveParser.CompressionKind, limit: Int) throws -> Data {
        guard limit >= 0, !input.isEmpty else { throw DebArchiveParser.DebError.decompressionFailed("member") }
        let algorithm: compression_algorithm
        switch kind {
        case .deflate: algorithm = COMPRESSION_ZLIB
        case .lzma: algorithm = COMPRESSION_LZMA
        }
        let placeholder = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { placeholder.deallocate() }
        var stream = compression_stream(
            dst_ptr: placeholder, dst_size: 0,
            src_ptr: UnsafePointer(placeholder), src_size: 0, state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else {
            throw DebArchiveParser.DebError.decompressionFailed("member")
        }
        defer { compression_stream_destroy(&stream) }

        var output = Data()
        var offset = 0
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let remaining = input.count - offset
            let available = limit - output.count
            let room = min(buffer.count, available == 0 ? 1 : available)
            var consumed = 0
            var produced = 0
            let status = input.withUnsafeBytes { source in
                buffer.withUnsafeMutableBufferPointer { destination -> compression_status in
                    guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress,
                          let destinationBase = destination.baseAddress else { return COMPRESSION_STATUS_ERROR }
                    stream.src_ptr = sourceBase.advanced(by: offset)
                    stream.src_size = remaining
                    stream.dst_ptr = destinationBase
                    stream.dst_size = room
                    let result = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    consumed = remaining - stream.src_size
                    produced = room - stream.dst_size
                    return result
                }
            }
            guard consumed >= 0, consumed <= remaining, produced >= 0, produced <= room else {
                throw DebArchiveParser.DebError.decompressionFailed("member")
            }
            guard produced <= limit - output.count else {
                throw DebArchiveParser.DebError.archiveTooLarge(limit: limit)
            }
            output.append(contentsOf: buffer.prefix(produced))
            offset += consumed
            if status == COMPRESSION_STATUS_END {
                guard offset == input.count else { throw DebArchiveParser.DebError.decompressionFailed("member") }
                return output
            }
            guard status == COMPRESSION_STATUS_OK, consumed > 0 || produced > 0 else {
                throw DebArchiveParser.DebError.decompressionFailed("member")
            }
        }
    }
}
