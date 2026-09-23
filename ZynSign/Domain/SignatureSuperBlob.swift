import Foundation

/// A standalone embedded-signature container, with no executable or signing
/// identity. Ascending numeric slot order is project policy, not an Apple
/// semantic requirement. Duplicate slots are rejected rather than replaced.
struct SignatureSuperBlob: Equatable {
    static let magic: UInt32 = 0xFADE0CC0
    static let maximumEntries = 128
    static let maximumSerializedLength = 256 * 1_024 * 1_024

    let entries: [CodeSignatureBlobEntry]

    init(entries: [CodeSignatureBlobEntry]) throws {
        guard entries.count <= Self.maximumEntries else {
            throw SuperBlobError.resourceLimitExceeded
        }
        self.entries = entries.sorted { $0.encodedType < $1.encodedType }
        try validate()
    }

    func validate() throws {
        var previous: UInt32?
        for entry in entries {
            if previous == entry.encodedType {
                throw SuperBlobError.duplicateBlobType(entry.encodedType)
            }
            previous = entry.encodedType
        }
        _ = try layout()
    }

    func layout() throws -> SuperBlobLayout {
        try SuperBlobLayout(blobLengths: entries.map { $0.blob.serializedLength })
    }

    func serialize() throws -> SuperBlobSerialization {
        try validate()
        let layout = try layout()
        var writer = CheckedBinaryWriter(maximumLength: layout.length)
        // Layout has already proved all encoded values fit UInt32 and policy.
        try writer.appendUInt32BigEndian(Self.magic)
        try writer.appendUInt32BigEndian(UInt32(layout.length))
        try writer.appendUInt32BigEndian(UInt32(entries.count))
        for (entry, placement) in zip(entries, layout.blobs) {
            try writer.appendUInt32BigEndian(entry.encodedType)
            try writer.appendUInt32BigEndian(UInt32(placement.offset))
        }
        for (entry, placement) in zip(entries, layout.blobs) {
            guard writer.count == placement.offset else { throw SuperBlobError.invalidOffset }
            try writer.appendData(entry.blob.bytes)
        }
        guard writer.count == layout.length else { throw SuperBlobError.inconsistentSerialization }
        return SuperBlobSerialization(bytes: writer.data, layout: layout)
    }
}

/// All locations are relative to the SuperBlob's first byte. No alignment
/// rounding or padding is needed: even an odd-length blob is packed directly
/// before the next one. This size-only planner can exercise hostile lengths
/// without allocating the corresponding payloads.
struct SuperBlobLayout: Equatable {
    struct Placement: Equatable {
        let offset: Int
        let length: Int
    }

    let length: Int
    let blobs: [Placement]
    var indexEnd: Int { 12 + blobs.count * 8 } // count bounded at initialization

    init(blobLengths: [Int]) throws {
        guard blobLengths.count <= SignatureSuperBlob.maximumEntries else {
            throw SuperBlobError.resourceLimitExceeded
        }
        var cursor = 12 + blobLengths.count * 8 // at most 1,036 bytes
        var placements: [Placement] = []
        placements.reserveCapacity(blobLengths.count)
        for length in blobLengths {
            guard length >= 8 else { throw SuperBlobError.invalidLength }
            let (end, overflow) = cursor.addingReportingOverflow(length)
            guard !overflow, UInt32(exactly: end) != nil else {
                throw SuperBlobError.integerOverflow
            }
            guard end <= SignatureSuperBlob.maximumSerializedLength else {
                throw SuperBlobError.resourceLimitExceeded
            }
            placements.append(Placement(offset: cursor, length: length))
            cursor = end
        }
        self.length = cursor
        self.blobs = placements
    }
}

struct SuperBlobSerialization: Equatable {
    let bytes: Data
    let layout: SuperBlobLayout

    /// Explicit binary validation uses the independent ZS-022 parser. This
    /// checks metadata against bytes, not authenticity of payloads or hashes.
    func validate() throws {
        guard bytes.count == layout.length else { throw SuperBlobError.inconsistentSerialization }
        let parsed = try ReadOnlyMachOParser().parseSuperBlob(bytes)
        guard parsed.count == layout.blobs.count else { throw SuperBlobError.invalidBlobCount }
        var previous: UInt32?
        for (entry, placement) in zip(parsed.entries, layout.blobs) {
            guard entry.relativeOffset == placement.offset,
                  entry.fileRange.count == placement.length else {
                throw SuperBlobError.inconsistentSerialization
            }
            if let previous, entry.slotNumber <= previous {
                throw SuperBlobError.inconsistentSerialization
            }
            previous = entry.slotNumber
        }
    }
}
