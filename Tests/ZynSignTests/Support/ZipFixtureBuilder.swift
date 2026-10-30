import Foundation
import Compression

/// Builds synthetic ZIP containers in memory.
///
/// Every fixture is generated programmatically from literal names and small
/// synthetic payloads. No real application package, signing material, profile,
/// or certificate appears anywhere in the test suite, and no binary fixture is
/// committed: the containers these tests read are written by this builder at
/// run time and written to a temporary directory that the test removes.
enum ZipFixtureBuilder {

    /// One entry to place in a synthetic container.
    struct Entry {
        /// The name bytes recorded in the container. Not validated: fixtures
        /// deliberately include names ZynSign must refuse, including byte
        /// sequences that are not decodable text at all.
        let nameBytes: [UInt8]
        let content: [UInt8]
        let deflate: Bool
        let unixMode: UInt16

        init(
            name: String,
            content: [UInt8] = [],
            deflate: Bool = false,
            unixMode: UInt16 = 0o100_644
        ) {
            self.init(
                nameBytes: Array(name.utf8),
                content: content,
                deflate: deflate,
                unixMode: unixMode
            )
        }

        init(
            nameBytes: [UInt8],
            content: [UInt8] = [],
            deflate: Bool = false,
            unixMode: UInt16 = 0o100_644
        ) {
            self.nameBytes = nameBytes
            self.content = content
            self.deflate = deflate
            self.unixMode = unixMode
        }

        /// A directory entry, named and typed the way containers record them.
        static func directory(_ name: String) -> Entry {
            Entry(name: name.hasSuffix("/") ? name : "\(name)/", content: [], unixMode: 0o040_755)
        }

        /// An entry whose recorded name is not decodable text.
        static func undecodableName(content: [UInt8] = []) -> Entry {
            Entry(nameBytes: [0xFF, 0xFE, 0x41, 0x80], content: content, unixMode: 0o100_644)
        }

        /// A symbolic link entry whose target is `content`.
        static func symbolicLink(_ name: String, target: String) -> Entry {
            Entry(
                name: name,
                content: Array(target.utf8),
                unixMode: 0o120_777
            )
        }
    }

    /// Builds a well-formed container holding `entries`, in order.
    static func archive(_ entries: [Entry]) -> [UInt8] {
        var body: [UInt8] = []
        var central: [UInt8] = []

        for entry in entries {
            let nameBytes = entry.nameBytes
            let (stored, method) = encode(entry)
            let checksum = crc32(of: entry.content)
            let localOffset = body.count

            var localHeader: [UInt8] = []
            appendUInt32(&localHeader, 0x0403_4B50)
            appendUInt16(&localHeader, 20)
            appendUInt16(&localHeader, 0)
            appendUInt16(&localHeader, method)
            appendUInt16(&localHeader, 0)
            appendUInt16(&localHeader, 0x0021)
            appendUInt32(&localHeader, checksum)
            appendUInt32(&localHeader, UInt32(stored.count))
            appendUInt32(&localHeader, UInt32(entry.content.count))
            appendUInt16(&localHeader, UInt16(nameBytes.count))
            appendUInt16(&localHeader, 0)
            localHeader.append(contentsOf: nameBytes)

            body.append(contentsOf: localHeader)
            body.append(contentsOf: stored)

            var record: [UInt8] = []
            appendUInt32(&record, 0x0201_4B50)
            appendUInt16(&record, 0x032D)
            appendUInt16(&record, 20)
            appendUInt16(&record, 0)
            appendUInt16(&record, method)
            appendUInt16(&record, 0)
            appendUInt16(&record, 0x0021)
            appendUInt32(&record, checksum)
            appendUInt32(&record, UInt32(stored.count))
            appendUInt32(&record, UInt32(entry.content.count))
            appendUInt16(&record, UInt16(nameBytes.count))
            appendUInt16(&record, 0)
            appendUInt16(&record, 0)
            appendUInt16(&record, 0)
            appendUInt16(&record, 0)
            appendUInt32(&record, UInt32(entry.unixMode) << 16)
            appendUInt32(&record, UInt32(localOffset))
            record.append(contentsOf: nameBytes)

            central.append(contentsOf: record)
        }

        var container = body
        let centralOffset = container.count
        container.append(contentsOf: central)

        appendUInt32(&container, 0x0605_4B50)
        appendUInt16(&container, 0)
        appendUInt16(&container, 0)
        appendUInt16(&container, UInt16(entries.count))
        appendUInt16(&container, UInt16(entries.count))
        appendUInt32(&container, UInt32(central.count))
        appendUInt32(&container, UInt32(centralOffset))
        appendUInt16(&container, 0)

        return container
    }

    /// A small ZIP using ZIP64 directory structures, optionally with extensible data.
    static func zip64Archive(_ entries: [Entry], extensionBytes: [UInt8] = []) -> [UInt8] {
        var bytes = archive(entries)
        let end = bytes.count - 22
        func field32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
        }
        let directorySize = field32(end + 12)
        let directoryOffset = field32(end + 16)
        var extended: [UInt8] = []
        appendUInt32(&extended, 0x0606_4B50)
        appendUInt64(&extended, UInt64(44 + extensionBytes.count))
        appendUInt16(&extended, 45)
        appendUInt16(&extended, 45)
        appendUInt32(&extended, 0)
        appendUInt32(&extended, 0)
        appendUInt64(&extended, UInt64(entries.count))
        appendUInt64(&extended, UInt64(entries.count))
        appendUInt64(&extended, UInt64(directorySize))
        appendUInt64(&extended, UInt64(directoryOffset))
        extended.append(contentsOf: extensionBytes)
        appendUInt32(&extended, 0x0706_4B50)
        appendUInt32(&extended, 0)
        appendUInt64(&extended, UInt64(end))
        appendUInt32(&extended, 1)
        bytes.insert(contentsOf: extended, at: end)
        let newEnd = end + extended.count
        for index in 8..<20 { bytes[newEnd + index] = 0xFF }
        return bytes
    }

    /// A single-entry ZIP using a data descriptor instead of local sizes.
    static func archiveWithDataDescriptor(_ entry: Entry) -> [UInt8] {
        var bytes = archive([entry])
        let end = bytes.count - 22
        let centralOffset = Int(bytes[end + 16])
            | (Int(bytes[end + 17]) << 8)
            | (Int(bytes[end + 18]) << 16)
            | (Int(bytes[end + 19]) << 24)
        let descriptor: [UInt8] = [0x50, 0x4B, 0x07, 0x08] + Array(bytes[14..<26])
        bytes.insert(contentsOf: descriptor, at: centralOffset)
        let newCentralOffset = centralOffset + descriptor.count
        let newEnd = end + descriptor.count
        bytes[6] |= 0x08
        bytes[newCentralOffset + 8] |= 0x08
        for index in 14..<26 { bytes[index] = 0 }
        for index in 0..<4 {
            bytes[newEnd + 16 + index] = UInt8(truncatingIfNeeded: newCentralOffset >> (index * 8))
        }
        return bytes
    }

    /// The entries of a minimal, structurally valid application package.
    static func validPackage(bundleName: String = "Example.app") -> [Entry] {
        [
            .directory("Payload"),
            .directory("Payload/\(bundleName)"),
            Entry(name: "Payload/\(bundleName)/Info.plist", content: syntheticPlist),
            Entry(name: "Payload/\(bundleName)/Example", content: Array(repeating: 0x90, count: 64), deflate: true),
        ]
    }

    /// Bytes that are not a container at all.
    static func notAnArchive() -> [UInt8] {
        Array("ZynSign synthetic test fixture — this is not a ZIP container.".utf8)
    }

    /// A container whose central directory has been damaged, while its
    /// end-of-central-directory record still looks plausible.
    static func corruptCentralDirectory(_ entries: [Entry]) -> [UInt8] {
        var container = archive(entries)
        // The end-of-central-directory record occupies the container's last 22
        // bytes, and records the central directory's offset at byte 16.
        let endOffset = container.count - 22
        let centralOffset = Int(container[endOffset + 16])
            | (Int(container[endOffset + 17]) << 8)
            | (Int(container[endOffset + 18]) << 16)
            | (Int(container[endOffset + 19]) << 24)
        guard centralOffset >= 0, centralOffset + 4 <= container.count else {
            return container
        }
        for index in centralOffset..<(centralOffset + 4) {
            container[index] = 0x00
        }
        return container
    }

    /// A container truncated so that its end-of-central-directory record is
    /// incomplete.
    static func truncated(_ entries: [Entry], droppingBytes: Int = 24) -> [UInt8] {
        let container = archive(entries)
        guard droppingBytes < container.count else { return [] }
        return Array(container.dropLast(droppingBytes))
    }

    /// Synthetic, non-secret content standing in for a bundle information file.
    static let syntheticPlist: [UInt8] = Array(
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
          <key>CFBundleIdentifier</key><string>com.example.synthetic</string>
        </dict></plist>
        """.utf8
    )

    // MARK: - Encoding

    private static func encode(_ entry: Entry) -> ([UInt8], UInt16) {
        guard entry.deflate, !entry.content.isEmpty else {
            return (entry.content, 0)
        }
        let capacity = entry.content.count + 512
        var destination = [UInt8](repeating: 0, count: capacity)
        let produced = entry.content.withUnsafeBufferPointer { source -> Int in
            destination.withUnsafeMutableBufferPointer { target -> Int in
                guard let targetAddress = target.baseAddress,
                      let sourceAddress = source.baseAddress else {
                    return 0
                }
                return compression_encode_buffer(
                    targetAddress,
                    capacity,
                    sourceAddress,
                    entry.content.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard produced > 0 else {
            return (entry.content, 0)
        }
        return (Array(destination.prefix(produced)), 8)
    }

    // MARK: - Byte helpers

    private static func appendUInt16(_ bytes: inout [UInt8], _ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private static func appendUInt32(_ bytes: inout [UInt8], _ value: UInt32) {
        for shift in stride(from: 0, through: 24, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    private static func appendUInt64(_ bytes: inout [UInt8], _ value: UInt64) {
        for shift in stride(from: 0, through: 56, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    /// An independent CRC-32 implementation, deliberately not shared with the
    /// reader under test so that a mistake in one is not mirrored in the other.
    private static func crc32(of bytes: [UInt8]) -> UInt32 {
        var value = UInt32.max
        for byte in bytes {
            value ^= UInt32(byte)
            for _ in 0..<8 {
                value = (value & 1) != 0 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
            }
        }
        return value ^ UInt32.max
    }
}
