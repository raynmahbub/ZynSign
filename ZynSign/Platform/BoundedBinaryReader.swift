/// Checked byte access for fixed-width binary structures. Views refer to the
/// caller's existing buffer only for the duration of parsing: no pointer or
/// buffer escapes into a domain model. Unlike ZIP's internal `ZipField`, a
/// failed read is never silently interpreted as zero.
struct BoundedBinaryReader {
    private let bytes: UnsafeRawBufferPointer
    let fileRange: Range<Int>

    init(bytes: UnsafeRawBufferPointer) {
        self.bytes = bytes
        fileRange = 0..<bytes.count
    }

    private init(bytes: UnsafeRawBufferPointer, fileRange: Range<Int>) {
        self.bytes = bytes
        self.fileRange = fileRange
    }

    var count: Int { fileRange.count }

    /// Returns an absolute range only if both the offset and the entire
    /// length fit inside this view. Subtraction before addition prevents
    /// attacker-controlled fields from overflowing a machine integer.
    func checkedRange(
        at offset: Int,
        length: Int,
        boundary: MachOParsingError.Boundary,
        ifTooLong: MachOParsingError.Reason = .truncatedInput
    ) throws -> Range<Int> {
        guard offset >= 0, offset <= count else {
            throw MachOParsingError(.invalidOffset, at: boundary)
        }
        guard length >= 0 else {
            throw MachOParsingError(.invalidLength, at: boundary)
        }
        guard length <= count - offset else {
            throw MachOParsingError(ifTooLong, at: boundary)
        }
        // The view itself lies within bytes.count, so both sums are bounded
        // by bytes.count after the checks above. Still check the additions so
        // this invariant cannot become an unchecked dependency.
        let (start, startOverflow) = fileRange.lowerBound.addingReportingOverflow(offset)
        let (end, endOverflow) = start.addingReportingOverflow(length)
        guard !startOverflow, !endOverflow, end <= bytes.count else {
            throw MachOParsingError(.invalidOffset, at: boundary)
        }
        return start..<end
    }

    func view(
        at offset: Int,
        length: Int,
        boundary: MachOParsingError.Boundary,
        ifTooLong: MachOParsingError.Reason = .truncatedInput
    ) throws -> BoundedBinaryReader {
        BoundedBinaryReader(
            bytes: bytes,
            fileRange: try checkedRange(at: offset, length: length, boundary: boundary, ifTooLong: ifTooLong)
        )
    }

    func uint8(at offset: Int, boundary: MachOParsingError.Boundary) throws -> UInt8 {
        let span = try checkedRange(at: offset, length: 1, boundary: boundary)
        return bytes[span.lowerBound]
    }

    /// Copies a previously checked range into a value-owned Data buffer.
    /// The reader never exposes its input pointer beyond the read operation.
    func data(
        at offset: Int,
        length: Int,
        boundary: MachOParsingError.Boundary,
        ifTooLong: MachOParsingError.Reason = .truncatedInput
    ) throws -> Data {
        let span = try checkedRange(at: offset, length: length, boundary: boundary, ifTooLong: ifTooLong)
        var result = Data()
        result.reserveCapacity(length)
        for index in span {
            result.append(bytes[index])
        }
        return result
    }

    func uint16(at offset: Int, order: MachOByteOrder, boundary: MachOParsingError.Boundary) throws -> UInt16 {
        UInt16(try unsigned(at: offset, width: 2, order: order, boundary: boundary))
    }

    func uint32(at offset: Int, order: MachOByteOrder, boundary: MachOParsingError.Boundary) throws -> UInt32 {
        UInt32(try unsigned(at: offset, width: 4, order: order, boundary: boundary))
    }

    /// Converts an on-disk UInt32 to a native index without trapping on a
    /// platform whose Int cannot represent it.
    func uint32AsInt(
        at offset: Int,
        order: MachOByteOrder,
        boundary: MachOParsingError.Boundary,
        ifUnrepresentable: MachOParsingError.Reason = .resourceLimitExceeded
    ) throws -> Int {
        let value = try uint32(at: offset, order: order, boundary: boundary)
        guard let result = Int(exactly: value) else {
            throw MachOParsingError(ifUnrepresentable, at: boundary)
        }
        return result
    }

    func uint64(at offset: Int, order: MachOByteOrder, boundary: MachOParsingError.Boundary) throws -> UInt64 {
        try unsigned(at: offset, width: 8, order: order, boundary: boundary)
    }

    func int32(at offset: Int, order: MachOByteOrder, boundary: MachOParsingError.Boundary) throws -> Int32 {
        Int32(bitPattern: try uint32(at: offset, order: order, boundary: boundary))
    }

    /// Only the fixed widths used in these formats are requested. Every byte
    /// in the loop lies inside one validated range, including on sliced Data.
    private func unsigned(
        at offset: Int,
        width: Int,
        order: MachOByteOrder,
        boundary: MachOParsingError.Boundary
    ) throws -> UInt64 {
        let span = try checkedRange(at: offset, length: width, boundary: boundary)
        var result: UInt64 = 0
        switch order {
        case .bigEndian:
            for index in span {
                result = (result << 8) | UInt64(bytes[index])
            }
        case .littleEndian:
            for index in span.reversed() {
                result = (result << 8) | UInt64(bytes[index])
            }
        }
        return result
    }
}
