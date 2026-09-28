import Foundation

/// DER-encoded entitlements for iOS 15+ (`0x20400`).
///
/// iOS 15 introduced a DER representation of the entitlement dictionary,
/// carried alongside the legacy XML plist, with CodeDirectory version
/// `0x20400` (82048) and `CSSLOT_DER_ENTITLEMENTS = 7` whose content is a
/// DER-encoded `Entitlements` SET. Apple's headers define `CSMAGIC_DER_ENTITLEMENTS`
/// and the version; the exact DER schema is not published in the open
/// headers but is observable in `codesign -d --der-entitlements` output.
///
/// ZynSign policy:
///
/// - DER payload is a deterministic DER encoding of the same entitlement
///   dictionary that the XML serializer produces. Keys are sorted by UTF-8,
///   values are typed (string, bool, integer, data, array, dictionary) and
///   encoded as DER primitives. Dates remain unsupported (same as XML path).
/// - The DER bytes are framed with `0xFADE7172` (`CSMAGIC_DER_ENTITLEMENTS`)
///   and length, parallel to `EntitlementsBlob` (`0xFADE7171`), so the slot-7
///   digest is the hash of those exact bytes.
/// - `CodeDirectoryVersion.v20400` is the minimum version that carries the
///   DER slot; the constructor refuses a DER slot on older versions.
/// - The DER slot is advisory: iOS evaluates the XML slot on older systems
///   and the DER slot on 15+. ZynSign never claims the DER form is trusted
///   — validation is recorded in `docs/architecture/external-validation.md`.
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
/// This encoder produces a canonical DER `SET` of `SEQUENCE { key OCTET STRING, value }`
/// where values are mapped as: string→UTF8String, bool→BOOLEAN, integer→INTEGER,
/// data→OCTET STRING, array→SEQUENCE, dictionary→SET (recursive). Ordering is
/// UTF-8 ascending at every dictionary level, matching the XML serializer.
struct DEREntitlementsSerializer {
    let limits: ProvisioningProfileParsingLimits

    init(limits: ProvisioningProfileParsingLimits = .default) {
        self.limits = limits
    }

    func serialize(_ entitlements: CodeSigningEntitlements) throws -> Data {
        var writer = DEREWriter()
        try writer.writeSet { set in
            for key in entitlements.keys {
                guard let value = entitlements[key] else { continue }
                try set.writeSequence { seq in
                    try seq.writeUTF8String(key)
                    try write(value: value, to: seq)
                }
            }
        }
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
            // DER has no REAL; encode as UTF8 for determinism (same as Apple's fallback)
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
            try writer.writeSet { set in
                for k in dict.keys.sorted(by: CanonicalPropertyListXMLSerializer.utf8Ascending) {
                    guard let v = dict[k] else { continue }
                    try set.writeSequence { seq in
                        try seq.writeUTF8String(k)
                        try write(value: v, to: seq)
                    }
                }
            }
        }
    }
}

/// Minimal DER writer — definite length only, no indefinite.
private final class DEREWriter {
    private var buffer: Data = Data()

    var data: Data { buffer }

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
