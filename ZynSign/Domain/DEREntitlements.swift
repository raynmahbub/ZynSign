import Foundation

/// Framed DER entitlements. Slot 7 and magic 0xFADE7172 are defined in
/// Apple's cs_blobs.h. This project requires CodeDirectory v20400 for slot 7;
/// that header names v20400 for exec-segment fields, not as a DER minimum.
/// Platform acceptance and the entitlement schema require independent validation.
struct DEREntitlementsBlob: Equatable, Hashable {
    static let magic: UInt32 = 0xFADE7172
    static let headerLength = 8
    /// Project resource policy; includes the eight-byte blob header.
    static let maximumPayloadLength = EntitlementsBlob.maximumPayloadByteCount
    static let maximumFramedLength = maximumPayloadLength + headerLength
    let payload: Data
    let bytes: Data

    init(derPayload payload: Data) throws {
        guard !payload.isEmpty else { throw EntitlementsError.emptyPayload }
        guard payload.count <= Self.maximumPayloadLength else {
            throw EntitlementsError.payloadTooLarge
        }
        let (total, overflow) = Self.headerLength.addingReportingOverflow(payload.count)
        guard !overflow, total <= Self.maximumFramedLength else { throw EntitlementsError.payloadTooLarge }
        guard let encoded = UInt32(exactly: total) else { throw EntitlementsError.payloadTooLarge }
        var w = CheckedBinaryWriter(maximumLength: total)
        try w.appendUInt32BigEndian(Self.magic)
        try w.appendUInt32BigEndian(encoded)
        try w.appendData(payload)
        self.payload = payload
        self.bytes = w.data
    }

    init(existingBlob bytes: Data) throws {
        // Bounds are enforced before any allocation: total framed length is
        // validated against the project's 1 MiB + 8 byte header budget, with
        // checked arithmetic so a crafted declared length cannot overflow into
        // a valid range. Payload memory is allocated only after framing is
        // proved, never before.
        guard bytes.count >= Self.headerLength else { throw EntitlementsError.invalidBlobFraming }
        // Integer overflow on the addition is treated as too large — a framed
        // blob that cannot be represented in 32 bits is not a valid blob.
        guard bytes.count <= Self.maximumFramedLength else { throw EntitlementsError.payloadTooLarge }
        let magic: UInt32 = bytes.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
        }
        let declared: Int = bytes.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            // Manual big-endian decode with overflow-checked accumulation:
            // each shift is over a checked Int width so a 32-bit declared
            // length never overflows the 64-bit Int on this platform, but
            // the total is still validated before any allocation.
            let v = (Int(b[4]) << 24) | (Int(b[5]) << 16) | (Int(b[6]) << 8) | Int(b[7])
            return v
        }
        guard magic == Self.magic else { throw EntitlementsError.invalidDERMagic }
        // Error precedence is deliberate: after magic, reject a declared
        // total length beyond the supported frame maximum as payloadTooLarge,
        // even when the supplied bytes are shorter. For an in-range declared
        // length, a mismatch with available bytes is invalidBlobFraming.
        // Declarations shorter than the header are always invalid framing.
        guard declared >= Self.headerLength else { throw EntitlementsError.invalidBlobFraming }
        guard declared <= Self.maximumFramedLength else { throw EntitlementsError.payloadTooLarge }
        guard declared == bytes.count else { throw EntitlementsError.invalidBlobFraming }
        let (payloadLength, overflow) = declared.subtractingReportingOverflow(Self.headerLength)
        guard !overflow else { throw EntitlementsError.invalidBlobFraming }
        guard payloadLength <= Self.maximumPayloadLength else { throw EntitlementsError.payloadTooLarge }
        // Only now is the payload slice copied; the allocation size has been
        // proved to be within the 1 MiB policy.
        self.payload = Data(bytes.dropFirst(Self.headerLength))
        self.bytes = bytes
    }
}

/// Deterministic DER serialization of entitlements.
///
/// This encoder produces a canonical DER `SET` of `SEQUENCE { key UTF8String, value }`
/// where values are mapped as: string→UTF8String, bool→BOOLEAN, integer→INTEGER,
/// data→OCTET STRING, array→SEQUENCE, dictionary→SET (recursive). Ordering is
/// lexicographic over complete DER-encoded pairs at every dictionary level.
struct DEREntitlementsSerializer {
    let limits: ProvisioningProfileParsingLimits

    init(limits: ProvisioningProfileParsingLimits = .default) {
        self.limits = limits
    }

    func serialize(_ entitlements: CodeSigningEntitlements) throws -> Data {
        var writer = DEREWriter()
        try writeDictionary(entitlements.values, to: writer)
        return writer.data
    }

    func blob(_ entitlements: CodeSigningEntitlements) throws -> DEREntitlementsBlob {
        let der = try serialize(entitlements)
        return try DEREntitlementsBlob(derPayload: der)
    }

    private func write(value: ProvisioningProfileValue, to writer: DEREWriter) throws {
        switch value {
        case .string(let s):
            // Canonical string policy: both XML and DER reject the same
            // strings. A value that would fail the XML canonical check is
            // rejected here with the same `invalidXMLString` so the two
            // serializations stay semantically identical — identical claims
            // have identical validity, and a claim rejected for XML is not
            // silently carried by DER.
            guard EntitlementCanonicalValidator.isValidEntitlementString(s) else {
                throw EntitlementsError.invalidXMLString
            }
            guard s.utf8.count <= limits.maximumStringByteCount else {
                throw EntitlementsError.resourceLimitExceeded
            }
            try writer.writeUTF8String(s)
        case .boolean(let b):
            try writer.writeBoolean(b)
        case .integer(let i):
            try writer.writeInteger(i)
        case .real:
            // DER's grammar has no REAL; a lossy string coercion would make
            // XML and DER diverge. The canonical model already allows `.real`
            // for XML, but the DER path refuses it before key use so the
            // signing boundary can report `notRepresentable` rather than
            // embedding a different claim.
            throw EntitlementsError.notRepresentable
        case .data(let d):
            guard d.count <= limits.maximumDataByteCount else {
                throw EntitlementsError.resourceLimitExceeded
            }
            try writer.writeOctetString(d)
        case .date:
            throw EntitlementsError.unsupportedValueType
        case .array(let arr):
            guard arr.count <= limits.maximumCollectionCount else {
                throw EntitlementsError.resourceLimitExceeded
            }
            try writer.writeSequence { seq in
                for el in arr { try write(value: el, to: seq) }
            }
        case .dictionary(let dict):
            guard dict.count <= limits.maximumCollectionCount else {
                throw EntitlementsError.resourceLimitExceeded
            }
            try writeDictionary(dict, to: writer)
        }
    }

    private func writeDictionary(_ values: [String: ProvisioningProfileValue], to writer: DEREWriter) throws {
        guard values.count <= limits.maximumCollectionCount else {
            throw EntitlementsError.resourceLimitExceeded
        }
        var pairs: [Data] = []
        for key in values.keys {
            try EntitlementCanonicalValidator.validateKey(key, limits: limits)
            guard let value = values[key] else { continue }
            let pair = DEREWriter()
            try pair.writeSequence { seq in
                try seq.writeUTF8String(key)
                try write(value: value, to: seq)
            }
            pairs.append(pair.data)
        }
        // DER SET OF ordering is lexicographic over complete encoded elements,
        // not lexical key ordering (element lengths affect that ordering).
        pairs.sort { $0.lexicographicallyPrecedes($1) }
        writer.writeSetElements(pairs)
    }

}

/// Minimal DER writer — definite length only, no indefinite.
private final class DEREWriter {
    private var buffer: Data = Data()

    var data: Data { buffer }

    func writeSetElements(_ elements: [Data]) {
        let length = elements.reduce(0) { $0 + $1.count }
        buffer.append(0x31)
        appendLength(length)
        for element in elements { buffer.append(element) }
    }
    func writeSet(_ content: (DEREWriter) throws -> Void) throws {
        try writeConstructed(tag: 0x31, content)
    }
    func writeSequence(_ content: (DEREWriter) throws -> Void) throws {
        try writeConstructed(tag: 0x30, content)
    }
    private func writeConstructed(tag: UInt8, _ content: (DEREWriter) throws -> Void) rethrows {
        let inner = DEREWriter()
        try content(inner)
        buffer.append(tag)
        appendLength(inner.buffer.count)
        buffer.append(inner.buffer)
    }
    func writeUTF8String(_ s: String) {
        let bytes = Array(s.utf8)
        buffer.append(0x0C)
        appendLength(bytes.count)
        buffer.append(contentsOf: bytes)
    }
    func writeBoolean(_ b: Bool) {
        buffer.append(0x01)
        buffer.append(0x01)
        buffer.append(b ? 0xFF : 0x00)
    }
    func writeInteger(_ i: Int64) {
        var bytes: [UInt8] = []
        var v = i
        let negative = v < 0
        repeat {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        } while v != 0 && v != -1
        // Ensure minimal two's complement sign
        if !negative, bytes[0] & 0x80 != 0 { bytes.insert(0x00, at: 0) }
        if negative, bytes[0] & 0x80 == 0 { bytes.insert(0xFF, at: 0) }
        buffer.append(0x02)
        appendLength(bytes.count)
        buffer.append(contentsOf: bytes)
    }
    func writeOctetString(_ d: Data) {
        buffer.append(0x04)
        appendLength(d.count)
        buffer.append(d)
    }
    private func appendLength(_ len: Int) {
        if len < 128 {
            buffer.append(UInt8(len))
        } else {
            var tmp = len
            var bytes: [UInt8] = []
            while tmp > 0 { bytes.insert(UInt8(tmp & 0xFF), at: 0); tmp >>= 8 }
            buffer.append(UInt8(0x80 | bytes.count))
            buffer.append(contentsOf: bytes)
        }
    }
}
