import Foundation

/// RFC 5652 detached SignedData for exactly one RSA-2048/SHA-256 signer.
/// The CMS is a cryptographic container, not Apple trust or application policy.
/// No clock, network, key export, or platform CMS/private API is used.
struct DetachedCodeSignatureCMS {
    static let maximumBytes = 512 * 1024
    static let signatureLength = 256

    let certificate: Certificate
    private let fields: CertificateDERParser.SigningFields

    init(certificate: Certificate) throws {
        let fields = try CertificateDERParser.signingFields(CertificateInput(bytes: certificate.derData))
        guard fields.metadata == certificate.metadata else { throw MachOSigningError.certificateUnavailable }
        guard fields.metadata.publicKeyInfo.algorithm == .rsa,
              fields.metadata.publicKeyInfo.keySizeInBits == 2048 else {
            throw MachOSigningError.unsupportedSigningAlgorithm
        }
        self.certificate = certificate
        self.fields = fields
    }

    /// Digest lengths and RSA signature length are fixed. No private operation
    /// is needed to establish the exact reservation, including DER length octets.
    func plannedLength() throws -> Int {
        let bytes = try encode(contentDigest: Data(repeating: 0, count: 32),
                               signature: Data(repeating: 0, count: Self.signatureLength))
        _ = try CMSStructureReader.read(bytes)
        return bytes.count
    }

    func signedAttributes(contentDigest: Data) throws -> Data {
        guard contentDigest.count == 32 else { throw MachOSigningError.signatureBlobConstruction }
        let contentType = try DER.sequence(DER.oid(Self.contentTypeOID)
            + DER.set(DER.oid(Self.dataOID)))
        let messageDigest = try DER.sequence(DER.oid(Self.messageDigestOID)
            + DER.set(DER.value(0x04, contentDigest)))
        // DER SET OF is sorted by complete encoded values, not OID strings.
        let attributes = [contentType, messageDigest].sorted { $0.lexicographicallyPrecedes($1) }
        return try DER.set(attributes.reduce(Data(), +))
    }

    func encode(contentDigest: Data, signature: Data) throws -> Data {
        guard signature.count == Self.signatureLength else {
            throw MachOSigningError.signatureBlobConstruction
        }
        var attributes = try signedAttributes(contentDigest: contentDigest)
        attributes[0] = 0xA0 // IMPLICIT on the wire; SET OF when signed.
        let digestAlgorithm = try DER.sequence(DER.oid(Self.sha256OID)) // absent parameters
        let signatureAlgorithm = try DER.sequence(DER.oid(Self.rsaSHA256OID) + Data([0x05, 0x00]))
        let signer = try DER.sequence(Self.versionOne
            + DER.sequence(fields.issuerDER + fields.serialDER)
            + digestAlgorithm + attributes + signatureAlgorithm + DER.value(0x04, signature))
        let signedData = try DER.sequence(Self.versionOne + DER.set(digestAlgorithm)
            + DER.sequence(DER.oid(Self.dataOID)) // eContent absent (detached)
            + DER.value(0xA0, certificate.derData) + DER.set(signer))
        return try DER.sequence(DER.oid(Self.signedDataOID) + DER.value(0xA0, signedData))
    }

    func blob(contentDigest: Data, signature: Data) throws -> CodeSignatureBlob {
        let payload = try encode(contentDigest: contentDigest, signature: signature)
        var writer = CheckedBinaryWriter(maximumLength: payload.count + 8)
        try writer.appendUInt32BigEndian(0xFADE0B01)
        try writer.appendUInt32BigEndian(UInt32(payload.count + 8))
        try writer.appendData(payload)
        return try CodeSignatureBlob.opaque(serializedBytes: writer.data)
    }

    /// A separately implemented bounded decoder supplies the actual signature
    /// and message for verification. Canonical equality additionally rejects
    /// unknown attributes and alternate parameter encodings in this profile.
    func verify(_ cms: Data, codeDirectory: Data, digest: any MessageDigest,
                verifier: any CryptographicSignatureVerifier) throws {
        guard cms.count <= Self.maximumBytes else { throw MachOSigningError.postSignVerification }
        let contentDigest = try digest.digest(codeDirectory, algorithm: .sha256)
        guard contentDigest.algorithm == .sha256 else { throw MachOSigningError.postSignVerification }
        let parsed = try CMSStructureReader.read(cms)
        guard parsed.version == 1, parsed.encapsulatedContent == nil,
              parsed.encapsulatedContentType == CMSObjectIdentifiers.data,
              parsed.certificateRevocationListCount == 0,
              parsed.certificateEncodings == [certificate.derData],
              parsed.digestAlgorithmIdentifiers == [CMSDigestAlgorithm.sha256ObjectIdentifier],
              parsed.signerInfos.count == 1, let signer = parsed.signerInfos.first,
              signer.version == 1, signer.issuerDER == fields.issuerDER,
              case .issuerAndSerialNumber(let serial) = signer.identifier,
              try DER.value(0x02, Data(serial)) == fields.serialDER,
              signer.digestAlgorithm == CMSDigestAlgorithm.sha256ObjectIdentifier,
              signer.signatureAlgorithm == CMSVerificationAlgorithm.sha256WithRSAEncryptionObjectIdentifier,
              let attributes = signer.signedAttributes,
              attributes.contentType == CMSObjectIdentifiers.data,
              attributes.messageDigest == contentDigest.bytes,
              attributes.attributeObjectIdentifiers.count == 2,
              Set(attributes.attributeObjectIdentifiers) == Set([
                CMSObjectIdentifiers.attributeContentType, CMSObjectIdentifiers.attributeMessageDigest]),
              try cms == encode(contentDigest: contentDigest.bytes, signature: signer.signature),
              verifier.verify(signature: signer.signature,
                              message: .message(attributes.verificationMessage),
                              algorithm: .rsaPKCS1SHA256Message,
                              certificate: certificate) == .valid else {
            throw MachOSigningError.postSignVerification
        }
    }

    private static let versionOne = Data([0x02, 0x01, 0x01])
    // Published ASN.1 OID value octets; no external implementation is embedded.
    private static let dataOID = Data([0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x07,0x01])
    private static let signedDataOID = Data([0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x07,0x02])
    private static let contentTypeOID = Data([0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x09,0x03])
    private static let messageDigestOID = Data([0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x09,0x04])
    private static let sha256OID = Data([0x60,0x86,0x48,0x01,0x65,0x03,0x04,0x02,0x01])
    private static let rsaSHA256OID = Data([0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x01,0x0B])

    /// Construction only, not a second ASN.1 reader. All callers use fixed tags
    /// and checked, bounded values. Indefinite lengths are never emitted.
    private enum DER {
        static func value(_ tag: UInt8, _ content: Data) throws -> Data {
            guard content.count <= DetachedCodeSignatureCMS.maximumBytes - 6 else {
                throw MachOSigningError.resourceLimitExceeded
            }
            var length = content.count
            var octets: [UInt8] = []
            repeat {
                octets.insert(UInt8(truncatingIfNeeded: length), at: 0)
                length >>= 8
            } while length > 0
            var result = Data([tag])
            if content.count < 128 { result.append(UInt8(content.count)) }
            else { result.append(0x80 | UInt8(octets.count)); result.append(contentsOf: octets) }
            result.append(content)
            return result
        }
        static func sequence(_ content: Data) throws -> Data { try value(0x30, content) }
        static func set(_ content: Data) throws -> Data { try value(0x31, content) }
        static func oid(_ content: Data) throws -> Data { try value(0x06, content) }
    }
}
