import Foundation

/// A small append-only writer for bounded big-endian structures. It refuses
/// lengths that exceed its configured policy before mutating the buffer and
/// performs no unchecked integer narrowing.
struct CheckedBinaryWriter {
    private(set) var data = Data()
    private let maximumLength: Int

    init(maximumLength: Int) {
        self.maximumLength = maximumLength
    }

    var count: Int { data.count }

    mutating func appendUInt8(_ value: UInt8) throws {
        try ensureAdditionalCapacity(1)
        data.append(value)
    }

    mutating func appendUInt32BigEndian(_ value: UInt32) throws {
        try ensureAdditionalCapacity(4)
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendData(_ value: Data) throws {
        try ensureAdditionalCapacity(value.count)
        data.append(contentsOf: value)
    }

    mutating func appendUTF8(_ value: String) throws {
        try appendData(Data(value.utf8))
        try appendUInt8(0)
    }

    func checkedUInt32(_ value: Int, field: CodeDirectoryOffset) throws -> UInt32 {
        guard value >= 0, let result = UInt32(exactly: value) else {
            throw CodeDirectoryError.invalidOffset(field)
        }
        return result
    }

    private func ensureAdditionalCapacity(_ additional: Int) throws {
        guard additional >= 0 else {
            throw CodeDirectoryError.invalidLength
        }
        let (newCount, overflow) = data.count.addingReportingOverflow(additional)
        guard !overflow else {
            throw CodeDirectoryError.integerOverflow
        }
        guard newCount <= maximumLength else {
            throw CodeDirectoryError.resourceLimitExceeded
        }
    }
}
