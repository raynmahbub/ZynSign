import Foundation

/// Reads the DER entitlement SET that `DEREntitlementsSerializer` writes.
///
/// The encoder has always been able to write slot 7; nothing could read it back.
/// That made a DER-only signature an *opaque* fact in the Entitlements Studio —
/// the screen could see that claims existed and had to say "unknown, not empty".
/// This decoder closes that gap: the same grammar the serializer emits is parsed
/// back into the same typed model, so a signature that carries only the DER slot
/// reports its claims instead of reporting its ignorance.
///
/// **The grammar, exactly.** A DER `SET` whose elements are `SEQUENCE { key
/// UTF8String, value }`, where a value is `UTF8String`, `BOOLEAN`, `INTEGER`,
/// `OCTET STRING`, `SEQUENCE` (array) or `SET` (dictionary, recursively the same
/// pair shape). That is the shape `DEREntitlementsSerializer` produces and the
/// shape Apple's DER entitlements carry.
///
/// **What it refuses rather than guesses.** Indefinite lengths, non-minimal
/// lengths, non-canonical booleans, non-minimal integers, duplicate keys,
/// trailing bytes after the outer SET, a tag outside the grammar, and any tree
/// past the configured depth, node, string, data, or collection bounds. A
/// refusal is an error, never a partial set: a signature's claims are either
/// read completely or not read at all.
///
/// **What decoding is not.** Claims decoded here are structurally valid data.
/// Nothing about a signature's authenticity, its authorization by Apple, or the
/// device's trust in it is established by reading this slot.
struct DEREntitlementsDecoder {

    let limits: ProvisioningProfileParsingLimits

    init(limits: ProvisioningProfileParsingLimits = .default) {
        self.limits = limits
    }

    /// Decodes one DER entitlement payload (the bytes inside
    /// `DEREntitlementsBlob`, without its 8-byte framing).
    ///
    /// Total payload size, declared lengths and collection counts are validated
    /// before any value allocation. Integer overflow on length fields is
    /// treated as malformed, and trailing bytes after the outer SET are
    /// refused. The DER decoder maintains its own traversal counter with the
    /// same node semantics as model, XML and profile decoding: value nodes
    /// count, while dictionary keys and the implicit root dictionary do not.
    func decode(_ payload: Data) throws -> CodeSigningEntitlements {
        guard !payload.isEmpty else { throw EntitlementsError.emptyPayload }
        guard payload.count <= DEREntitlementsBlob.maximumPayloadLength else { throw EntitlementsError.payloadTooLarge }
        // Validate outer framing before allocating the working buffer:
        // a payload that claims a length past the total buffer is truncated,
        // and a payload whose declared outer length would overflow the budget
        // is refused before the [UInt8] copy. The copy size was already proved
        // to be within 1 MiB.
        guard payload.count >= 2 else { throw EntitlementsError.malformedDEREncoding }
        var reader = DEREReader(bytes: [UInt8](payload), limits: limits)
        let set = try reader.readElement(expected: DERETag.set)
        var values: [String: ProvisioningProfileValue] = [:]
        var nodeCount = 0
        var pairReader = DEREReader(bytes: set.content, limits: limits)
        // Collection count for the outer SET is enforced before each pair is
        // materialized, bounding the number of allocations from untrusted input.
        while pairReader.hasMore {
            guard values.count < limits.maximumCollectionCount else {
                throw EntitlementsError.resourceLimitExceeded
            }
            let pair = try pairReader.readElement(expected: DERETag.sequence)
            var fieldReader = DEREReader(bytes: pair.content, limits: limits)
            let key = try fieldReader.readString(limits: limits)
            // Keys are validated by the shared canonical string policy; a
            // DER string that would fail the XML check is rejected here rather
            // than diverging from the XML representation.
            guard EntitlementCanonicalValidator.isValidEntitlementString(key) else {
                throw EntitlementsError.invalidXMLString
            }
            let value = try DEREntitlementsDecoder.readValue(
                from: &fieldReader,
                depth: 0,
                nodeCount: &nodeCount,
                limits: limits
            )
            guard !fieldReader.hasMore else { throw EntitlementsError.malformedDEREncoding }
            guard values[key] == nil else { throw EntitlementsError.malformedDEREncoding }
            values[key] = value
        }
        guard !reader.hasMore else { throw EntitlementsError.malformedDEREncoding }
        // The constructed values are validated through the same canonical
        // validator via `CodeSigningEntitlements` so the node budget counted
        // during decoding matches the budget counted during model validation;
        // the model construction also re-enforces the shared string and
        // collection policy, closing any gap between reader limits and model
        // limits.
        return try CodeSigningEntitlements(values: values, limits: limits)
    }

    /// Decodes a complete framed blob (`0xFADE7172` + length + payload).
    func decode(blob bytes: Data) throws -> CodeSigningEntitlements {
        let blob = try DEREntitlementsBlob(existingBlob: bytes)
        return try decode(blob.payload)
    }

    // MARK: - Values

    private static func readValue(
        from reader: inout DEREReader,
        depth: Int,
        nodeCount: inout Int,
        limits: ProvisioningProfileParsingLimits
    ) throws -> ProvisioningProfileValue {
        guard depth <= limits.maximumNestingDepth else {
            throw EntitlementsError.resourceLimitExceeded
        }
        nodeCount += 1
        guard nodeCount <= limits.maximumValueNodeCount else {
            throw EntitlementsError.resourceLimitExceeded
        }
        let element = try reader.readElement()
        switch element.tag {
        case DERETag.utf8String:
            let bytes = try element.contentBytes(limit: limits.maximumStringByteCount)
            guard let text = String(bytes: bytes, encoding: .utf8) else {
                throw EntitlementsError.malformedDEREncoding
            }
            // Enforce the shared string policy: a DER UTF8String that is not
            // valid XML character data is rejected so XML and DER stay
            // semantically identical. A lone surrogate or FFFE is not a
            // representable entitlement string in the canonical model.
            guard EntitlementCanonicalValidator.isValidEntitlementString(text) else {
                throw EntitlementsError.invalidXMLString
            }
            return .string(text)

        case DERETag.boolean:
            guard element.content.count == 1, let byte = element.content.first else {
                throw EntitlementsError.malformedDEREncoding
            }
            switch byte {
            case 0x00: return .boolean(false)
            case 0xFF: return .boolean(true)
            default: throw EntitlementsError.malformedDEREncoding
            }

        case DERETag.integer:
            return .integer(try DEREntitlementsDecoder.readInteger(element.content))

        case DERETag.octetString:
            let bytes = try element.contentBytes(limit: limits.maximumDataByteCount)
            return .data(Data(bytes))

        case DERETag.sequence:
            var elementReader = DEREReader(bytes: element.content, limits: limits)
            var items: [ProvisioningProfileValue] = []
            while elementReader.hasMore {
                guard items.count < limits.maximumCollectionCount else {
                    throw EntitlementsError.resourceLimitExceeded
                }
                items.append(try readValue(
                    from: &elementReader,
                    depth: depth + 1,
                    nodeCount: &nodeCount,
                    limits: limits
                ))
            }
            return .array(items)

        case DERETag.set:
            var pairReader = DEREReader(bytes: element.content, limits: limits)
            var dictionary: [String: ProvisioningProfileValue] = [:]
            while pairReader.hasMore {
                guard dictionary.count < limits.maximumCollectionCount else {
                    throw EntitlementsError.resourceLimitExceeded
                }
                let pair = try pairReader.readElement(expected: DERETag.sequence)
                var fieldReader = DEREReader(bytes: pair.content, limits: limits)
                let key = try fieldReader.readString(limits: limits)
                let value = try DEREntitlementsDecoder.readValue(
                    from: &fieldReader,
                    depth: depth + 1,
                    nodeCount: &nodeCount,
                    limits: limits
                )
                guard !fieldReader.hasMore, dictionary[key] == nil else {
                    throw EntitlementsError.malformedDEREncoding
                }
                dictionary[key] = value
            }
            return .dictionary(dictionary)

        default:
            // A tag the grammar does not carry — REAL, a time, a context tag —
            // is reported, not coerced into a string.
            throw EntitlementsError.unsupportedValueType
        }
    }

    /// A minimal two's-complement INTEGER of at most eight bytes.
    private static func readInteger(_ bytes: [UInt8]) throws -> Int64 {
        guard !bytes.isEmpty, bytes.count <= 8 else { throw EntitlementsError.malformedDEREncoding }
        if bytes.count > 1 {
            let first = bytes[0]
            let second = bytes[1]
            // Reject a redundant sign byte: DER requires the shortest form.
            if first == 0x00, second & 0x80 == 0 { throw EntitlementsError.malformedDEREncoding }
            if first == 0xFF, second & 0x80 != 0 { throw EntitlementsError.malformedDEREncoding }
        }
        var value: Int64 = (bytes[0] & 0x80) == 0 ? 0 : -1
        for byte in bytes {
            value = (value << 8) | Int64(byte)
        }
        return value
    }
}

// MARK: - Reader

/// The scalar tags the grammar uses. Numbers rather than an enum so an
/// unexpected tag keeps its own value in the refusal path.
private enum DERETag {
    static let boolean: UInt8 = 0x01
    static let integer: UInt8 = 0x02
    static let octetString: UInt8 = 0x04
    static let utf8String: UInt8 = 0x0C
    static let sequence: UInt8 = 0x30
    static let set: UInt8 = 0x31
}

/// One delimited element: its tag and its content bytes.
private struct DEREElement {
    let tag: UInt8
    let content: [UInt8]

    func contentBytes(limit: Int) throws -> [UInt8] {
        guard content.count <= limit else { throw EntitlementsError.resourceLimitExceeded }
        return content
    }
}

/// A strict DER cursor over `[UInt8]`.
///
/// Definite lengths only, minimal length encodings only, and every read is
/// bounds-checked against the slice it was given. It never allocates a range it
/// has not already proved exists inside the slice.
private struct DEREReader {

    private let bytes: [UInt8]
    private let limits: ProvisioningProfileParsingLimits
    private var cursor: Int = 0

    init(bytes: [UInt8], limits: ProvisioningProfileParsingLimits) {
        self.bytes = bytes
        self.limits = limits
    }

    var hasMore: Bool { cursor < bytes.count }

    /// Reads one element, optionally requiring a tag.
    mutating func readElement() throws -> DEREElement {
        let tag = try readByte()
        let length = try readLength()
        guard length <= bytes.count - cursor else { throw EntitlementsError.malformedDEREncoding }
        let content = Array(bytes[cursor..<(cursor + length)])
        cursor += length
        return DEREElement(tag: tag, content: content)
    }

    mutating func readElement(expected tag: UInt8) throws -> DEREElement {
        let element = try readElement()
        guard element.tag == tag else { throw EntitlementsError.malformedDEREncoding }
        return element
    }

    /// Reads a UTF8String and returns its text, enforcing the shared string
    /// policy so DER keys also respect the canonical XML character rule.
    mutating func readString(limits: ProvisioningProfileParsingLimits) throws -> String {
        let element = try readElement(expected: DERETag.utf8String)
        let content = try element.contentBytes(limit: limits.maximumStringByteCount)
        guard let text = String(bytes: content, encoding: .utf8) else {
            throw EntitlementsError.malformedDEREncoding
        }
        guard EntitlementCanonicalValidator.isValidEntitlementString(text) else {
            throw EntitlementsError.invalidXMLString
        }
        return text
    }

    private mutating func readByte() throws -> UInt8 {
        guard cursor < bytes.count else { throw EntitlementsError.malformedDEREncoding }
        defer { cursor += 1 }
        return bytes[cursor]
    }

    /// Definite, minimally encoded lengths only, with overflow-checked
    /// arithmetic. Indefinite, reserved, non-minimal and overflowed lengths
    /// are refused before any content allocation. Truncated input (declared
    /// past the buffer) is also refused here, not after a partial allocation.
    private mutating func readLength() throws -> Int {
        let first = try readByte()
        if first < 0x80 { return Int(first) }
        // 0x80 is the indefinite form DER forbids, and 0xFF is reserved.
        guard first != 0x80, first != 0xFF else { throw EntitlementsError.malformedDEREncoding }
        let byteCount = Int(first & 0x7F)
        guard byteCount <= 4 else { throw EntitlementsError.malformedDEREncoding }
        var length = 0
        for index in 0..<byteCount {
            let byte = try readByte()
            // A leading zero in the long form is a non-minimal encoding.
            if index == 0, byte == 0x00 { throw EntitlementsError.malformedDEREncoding }
            let (shifted, overflowShift) = length.multipliedReportingOverflow(by: 256)
            guard !overflowShift else { throw EntitlementsError.malformedDEREncoding }
            let (added, overflowAdd) = shifted.addingReportingOverflow(Int(byte))
            guard !overflowAdd else { throw EntitlementsError.malformedDEREncoding }
            length = added
        }
        // Anything that would have fitted the short form must use it.
        guard length >= 0x80 else { throw EntitlementsError.malformedDEREncoding }
        guard length <= EntitlementsBlob.maximumPayloadByteCount else {
            throw EntitlementsError.resourceLimitExceeded
        }
        // Length is also checked against the remaining buffer so a truncated
        // element (declared past the slice) is refused without allocating the
        // missing bytes.
        guard length <= bytes.count - cursor else { throw EntitlementsError.malformedDEREncoding }
        return length
    }
}
