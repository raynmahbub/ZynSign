import Foundation

/// ZynSign's writer for ZIP-based application packages.
///
/// The writer serializes a validated entry set into a deterministic,
/// stored (uncompressed) container: entries in ascending name-byte order,
/// fixed timestamps, fixed Unix modes, no extra fields, no comments, no
/// encryption, and no data descriptors. Equal entry sets produce
/// byte-identical containers on every run and every device.
///
/// Determinism is chosen over size. Stored entries keep the writer free of
/// any compression dependency and keep every output byte a pure function of
/// the entry set, which is what makes packaging round-trip verification
/// meaningful: the container can be reopened and compared entry for entry
/// against the plan that produced it.
///
/// The writer is ZIP32-only: entry counts, sizes, and offsets must fit the
/// container form's 16- and 32-bit fields. Sets beyond those ceilings are
/// refused with a typed error rather than approximated with ZIP64, which
/// the reader side does not need from containers ZynSign itself produces.
struct ZipArchiveWriter: ArchiveWriter {

    // MARK: - Format constants

    private static let localFileHeaderSignature: UInt32 = 0x0403_4B50
    private static let centralDirectorySignature: UInt32 = 0x0201_4B50
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50

    private static let storedMethod: UInt16 = 0
    private static let versionNeeded: UInt16 = 20
    private static let versionMadeBy: UInt16 = 0x032D
    private static let generalPurposeFlags: UInt16 = 0x0800
    private static let fixedTime: UInt16 = 0x0000
    private static let fixedDate: UInt16 = 0x0021

    private static let fileMode: UInt16 = 0o100_644
    private static let executableFileMode: UInt16 = 0o100_755
    private static let directoryMode: UInt16 = 0o040_755
    private static let symbolicLinkMode: UInt16 = 0o120_777

    private static let localFileHeaderSize = 30
    private static let centralDirectoryRecordSize = 46
    private static let endOfCentralDirectorySize = 22

    // MARK: - ArchiveWriter

    func writeArchive(
        entries: [ArchiveWriteEntry],
        policy: ArchiveWritePolicy,
        sink: (Data) throws -> Void
    ) throws {
        let plan = try ArchiveWritePlan.plan(entries: entries, policy: policy)
        guard plan.entries.count <= Int(UInt16.max) else {
            throw ZynSignError.packagingFailure(
                diagnosticDetail: "The entry set holds more entries than the container form can record."
            )
        }
        // Every size and offset is established before the first byte is
        // emitted, so a set beyond the container form's own ceilings writes
        // nothing at all.
        let layout = try Self.layout(for: plan)

        var central: [UInt8] = []
        central.reserveCapacity(layout.centralSize)
        for (entry, record) in zip(plan.entries, layout.records) {
            try sink(Data(record.localHeader))
            if !entry.content.isEmpty {
                try sink(entry.content)
            }
            central.append(contentsOf: record.centralRecord)
        }
        try sink(Data(central))
        try sink(Data(layout.endRecord))
    }

    // MARK: - Layout

    private struct EntryLayout {
        let localHeader: [UInt8]
        let centralRecord: [UInt8]
    }

    private struct ContainerLayout {
        let records: [EntryLayout]
        let centralSize: Int
        let endRecord: [UInt8]
    }

    private static func layout(for plan: ArchiveWritePlan) throws -> ContainerLayout {
        let entries = plan.entries
        var records: [EntryLayout] = []
        records.reserveCapacity(entries.count)
        var offset: UInt64 = 0
        var centralSize: UInt64 = 0

        for entry in entries {
            let nameBytes = Array(ArchiveWritePlan.recordedName(for: entry).utf8)
            guard nameBytes.count <= Int(UInt16.max) else {
                throw ZynSignError.packagingFailure(
                    diagnosticDetail: "An entry name exceeds what the container form can record."
                )
            }
            let contentCount = UInt64(entry.content.count)
            guard contentCount <= UInt64(UInt32.max) else {
                throw ZynSignError.packagingFailure(
                    diagnosticDetail: "An entry carries more content than the container form can record."
                )
            }
            let checksum = crc32(of: entry.content)
            let mode = mode(for: entry.kind)

            let headerEnd = try adding(offset, UInt64(localFileHeaderSize + nameBytes.count))
            let contentEnd = try adding(headerEnd, contentCount)
            let recordLength = UInt64(centralDirectoryRecordSize + nameBytes.count)
            centralSize = try adding(centralSize, recordLength)
            guard contentEnd <= UInt64(UInt32.max) else {
                throw ZynSignError.packagingFailure(
                    diagnosticDetail: "The container would grow beyond what the container form can address."
                )
            }

            var localHeader: [UInt8] = []
            localHeader.reserveCapacity(localFileHeaderSize + nameBytes.count)
            appendUInt32(&localHeader, localFileHeaderSignature)
            appendUInt16(&localHeader, versionNeeded)
            appendUInt16(&localHeader, generalPurposeFlags)
            appendUInt16(&localHeader, storedMethod)
            appendUInt16(&localHeader, fixedTime)
            appendUInt16(&localHeader, fixedDate)
            appendUInt32(&localHeader, checksum)
            appendUInt32(&localHeader, UInt32(contentCount))
            appendUInt32(&localHeader, UInt32(contentCount))
            appendUInt16(&localHeader, UInt16(nameBytes.count))
            appendUInt16(&localHeader, 0)
            localHeader.append(contentsOf: nameBytes)

            var centralRecord: [UInt8] = []
            centralRecord.reserveCapacity(centralDirectoryRecordSize + nameBytes.count)
            appendUInt32(&centralRecord, centralDirectorySignature)
            appendUInt16(&centralRecord, versionMadeBy)
            appendUInt16(&centralRecord, versionNeeded)
            appendUInt16(&centralRecord, generalPurposeFlags)
            appendUInt16(&centralRecord, storedMethod)
            appendUInt16(&centralRecord, fixedTime)
            appendUInt16(&centralRecord, fixedDate)
            appendUInt32(&centralRecord, checksum)
            appendUInt32(&centralRecord, UInt32(contentCount))
            appendUInt32(&centralRecord, UInt32(contentCount))
            appendUInt16(&centralRecord, UInt16(nameBytes.count))
            appendUInt16(&centralRecord, 0)
            appendUInt16(&centralRecord, 0)
            appendUInt16(&centralRecord, 0)
            appendUInt16(&centralRecord, 0)
            appendUInt32(&centralRecord, UInt32(mode) << 16)
            appendUInt32(&centralRecord, UInt32(offset))
            centralRecord.append(contentsOf: nameBytes)

            records.append(EntryLayout(localHeader: localHeader, centralRecord: centralRecord))
            offset = contentEnd
        }

        let centralEnd = try adding(offset, centralSize)
        let totalEnd = try adding(centralEnd, UInt64(endOfCentralDirectorySize))
        guard totalEnd <= UInt64(UInt32.max) else {
            throw ZynSignError.packagingFailure(
                diagnosticDetail: "The container would grow beyond what the container form can address."
            )
        }
        guard centralSize <= UInt64(Int.max) else {
            throw ZynSignError.packagingFailure(
                diagnosticDetail: "The container directory would grow beyond what this platform can address."
            )
        }

        var endRecord: [UInt8] = []
        endRecord.reserveCapacity(endOfCentralDirectorySize)
        appendUInt32(&endRecord, endOfCentralDirectorySignature)
        appendUInt16(&endRecord, 0)
        appendUInt16(&endRecord, 0)
        appendUInt16(&endRecord, UInt16(records.count))
        appendUInt16(&endRecord, UInt16(records.count))
        appendUInt32(&endRecord, UInt32(centralSize))
        appendUInt32(&endRecord, UInt32(offset))
        appendUInt16(&endRecord, 0)

        return ContainerLayout(
            records: records,
            centralSize: Int(centralSize),
            endRecord: endRecord
        )
    }

    private static func mode(for kind: ArchiveWriteEntryKind) -> UInt16 {
        switch kind {
        case .directory:
            return directoryMode
        case .regularFile(let isExecutable):
            if isExecutable {
                return executableFileMode
            }
            return fileMode
        case .symbolicLink:
            return symbolicLinkMode
        }
    }

    private static func adding(_ left: UInt64, _ right: UInt64) throws -> UInt64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        if overflow {
            throw ZynSignError.packagingFailure(
                diagnosticDetail: "Container size arithmetic overflowed while planning the output."
            )
        }
        return value
    }

    // MARK: - Byte helpers

    private static func appendUInt16(_ bytes: inout [UInt8], _ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private static func appendUInt32(_ bytes: inout [UInt8], _ value: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static let checksumTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            if (value & 1) != 0 {
                value = (value >> 1) ^ 0xEDB8_8320
            } else {
                value = value >> 1
            }
        }
        return value
    }

    private static func crc32(of data: Data) -> UInt32 {
        var value = UInt32.max
        for byte in data {
            value = (value >> 8) ^ checksumTable[Int((value ^ UInt32(byte)) & 0xFF)]
        }
        return value ^ UInt32.max
    }
}

