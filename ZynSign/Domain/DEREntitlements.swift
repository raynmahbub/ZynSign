import Foundation

/// Framed DER entitlements. Slot 7 and magic 0xFADE7172 are defined in
/// Apple's cs_blobs.h. This project requires CodeDirectory v20400 for slot 7;
/// that header names v20400 for exec-segment fields, not as a DER minimum.
/// Platform acceptance and the entitlement schema require independent validation.
struct DEREntitlementsBlob: Equatable, Hashable {
    static let magic: UInt32 = 0xFADE7172
    static let headerLength = 8
    let payload: Data
    let bytes: Data

    init(derPayload payload: Data) throws {
        guard !payload.isEmpty else { throw EntitlementsError.emptyPayload }
        guard payload.count <= EntitlementsBlob.maximumPayloadByteCount else {
            throw EntitlementsError.payloadTooLarge
        }
        let total = Self.headerLength + payload.count
        guard let encoded = UInt32(exactly: total) else { throw EntitlementsError.payloadTooLarge }
        var w = CheckedBinaryWriter(maximumLength: total)
        try w.appendUInt32BigEndian(Self.magic)
        try w.appendUInt32BigEndian(encoded)
        try w.appendData(payload)
        self.payload = payload
        self.bytes = w.data
    }

    init(existingBlob bytes: Data) throws {
        guard bytes.count >= Self.headerLength else { throw EntitlementsError.invalidBlobFraming }
        let magic: UInt32 = bytes.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
        }
        let declared: Int = bytes.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            return Int(b[4]) << 24 | Int(b[5]) << 16 | Int(b[6]) << 8 | Int(b[7])
        }
        guard magic == Self.magic else { throw EntitlementsError.invalidBlobFraming }
        guard declared == bytes.count else { throw EntitlementsError.invalidBlobFraming }
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
            try writer.writeUTF8String(s)
        case .boolean(let b):
            try writer.writeBoolean(b)
        case .integer(let i):
            try writer.writeInteger(i)
        case .real(let r):
            // Legacy serializer behavior; the signing boundary rejects this lossy mapping.
            try writer.writeUTF8String(String(describing: r))
        case .data(let d):
            try writer.writeOctetString(d)
        case .date:
            throw EntitlementsError.unsupportedValueType
        case .array(let arr):
            try writer.writeSequence { seq in
                for el in arr { try write(value: el, to: seq) }
            }
        case .dictionary(let dict):
            try writeDictionary(dict, to: writer)
        }
    }

    private func writeDictionary(_ values: [String: ProvisioningProfileValue], to writer: DEREWriter) throws {
        var pairs: [Data] = []
        for key in values.keys {
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
