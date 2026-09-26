import Foundation

/// Object identifiers the CMS structure reader recognises.
///
/// Recognition is a labelling convenience, not a policy. An identifier that is
/// not listed here is preserved exactly so a caller can see what a message
/// declared.
enum CMSObjectIdentifiers {

    static let data = "1.2.840.113549.1.7.1"
    static let signedData = "1.2.840.113549.1.7.2"
    static let attributeContentType = "1.2.840.113549.1.9.3"
    static let attributeMessageDigest = "1.2.840.113549.1.9.4"
    static let attributeSigningTime = "1.2.840.113549.1.9.5"
}

/// Which subset of CMS the structure reader accepts.
///
/// The provisioning-profile subset is the default and is unchanged by the
/// existence of the other mode. The code-signature mode exists because a Mach-O
/// code signature's CMS message legitimately carries two shapes the profile
/// subset refuses: Apple's code-directory hash attribute carries one value per
/// CodeDirectory, and a signer may carry unsigned attributes such as a
/// timestamp token. Both are outside what the signature covers or what ZynSign
/// interprets, so the code-signature mode skips them — counting unsigned
/// attributes — while every modeled attribute keeps its strict rules.
enum CMSStructureReadingMode: Equatable {

    /// The provisioning-profile subset: every signed attribute carries exactly
    /// one value, and unsigned attributes are refused.
    case provisioningProfile

    /// Detached Mach-O code-signature messages: unmodeled signed attributes
    /// may carry several values, and unsigned attributes are skipped and
    /// counted. The message digest, content type, and signing time must still
    /// be single-valued to be read.
    case codeSignature
}

/// One CMS message as read by ZynSign's bounded structure reader.
///
/// This is a structural description, not a verdict. Nothing here says the
/// signature verifies, that a certificate is trusted, or that the encapsulated
/// content is a provisioning profile the platform accepts.
struct CMSStructure: Equatable {

    /// The outer content type. Always `signedData` for a message this reader
    /// returns; anything else is refused.
    let contentType: String

    /// The SignedData version.
    let version: Int

    /// The digest algorithms the message declares, in message order.
    let digestAlgorithmIdentifiers: [String]

    /// The encapsulated content type, when present.
    let encapsulatedContentType: String?

    /// The encapsulated content bytes, or `nil` for a detached message.
    let encapsulatedContent: Data?

    /// The exact DER encoding of every entry in the certificate bag, in bag
    /// order. Bag order carries no chain meaning, and an entry's presence here
    /// says only that it was delimited as a certificate-sized value: whether it
    /// parses as a certificate is decided by the certificate parser.
    let certificateEncodings: [Data]

    /// How many certificate-revocation entries the message carried. ZynSign
    /// counts them and does not interpret them.
    let certificateRevocationListCount: Int

    /// The signers, in message order.
    let signerInfos: [CMSStructureSignerInfo]
}

/// How one signer names its certificate, as read from the message.
enum CMSStructureSignerIdentifier: Equatable {

    /// Version 1: the issuer name and the certificate's serial number. Only the
    /// serial's INTEGER content octets are retained; the issuer name is not
    /// re-parsed here because the domain already models distinguished names.
    case issuerAndSerialNumber(serialContentBytes: [UInt8])

    /// Version 3: a subject key identifier.
    case subjectKeyIdentifier([UInt8])
}

/// The signed attributes of one signer, and the message they produce.
///
/// When signed attributes are present, the signature covers their DER encoding
/// as a `SET OF` — not the `[0] IMPLICIT` form that appears in the message —
/// and the encapsulated content is bound to the signature only through the
/// message-digest attribute. Both the re-encoded verification message and the
/// observed attribute values are kept so the two checks stay distinguishable.
struct CMSStructureSignedAttributes: Equatable {

    /// The attributes re-encoded as `SET OF`: the exact bytes a signature over
    /// signed attributes must cover.
    let verificationMessage: Data

    /// Every attribute identifier observed, in message order.
    let attributeObjectIdentifiers: [String]

    /// The message-digest attribute's value, when present.
    let messageDigest: Data?

    /// The content-type attribute's value, when present.
    let contentType: String?

    /// The signing-time attribute's value, when present, single-valued, and a
    /// well-formed UTCTime or GeneralizedTime. A time the signer declared by its
    /// own clock; it is not a trusted timestamp.
    var signingTime: Date? = nil
}

/// One signer as read from the message.
struct CMSStructureSignerInfo: Equatable {

    /// The SignerInfo version: 1 for issuer-and-serial, 3 for a key identifier.
    let version: Int

    /// How the signer names its certificate.
    let identifier: CMSStructureSignerIdentifier

    /// Exact issuer Name encoding for detached code-signature verification.
    let issuerDER: Data?

    /// The declared digest algorithm identifier.
    let digestAlgorithm: String

    /// The declared signature algorithm identifier.
    let signatureAlgorithm: String

    /// The signature value.
    let signature: Data

    /// The signed attributes, when the signer carried them.
    let signedAttributes: CMSStructureSignedAttributes?

    /// How many unsigned attributes the signer carried. Always zero in the
    /// provisioning-profile mode, which refuses them; counted, never
    /// interpreted, in the code-signature mode.
    var unsignedAttributeCount: Int = 0
}

/// A bounded reader for the CMS SignedData subset a provisioning profile uses.
///
/// Apple's CMS decoder family (`CMSDecoderCreate`, `CMSDecoderUpdateMessage`,
/// `CMSDecoderFinalizeMessage`, `CMSDecoderCopyContent`,
/// `CMSDecoderCopySignerCert`, `CMSDecoderCopyAllCerts`,
/// `CMSDecoderCopySignerStatus`) is documented for macOS 10.5 and later only,
/// and `CMSSignerStatus` for macOS and Mac Catalyst only. None of it is in the
/// iOS API surface, so it cannot be the mechanism on this product's runtime and
/// is not called anywhere in this repository. This reader is the substitute: a
/// structural walk of RFC 5652 SignedData over the bytes ZynSign was given.
///
/// Input is hostile. The reader rejects empty, oversized, armored, indefinite-
/// length, non-minimal, high-tag-number, truncated, and trailing-data encodings
/// with typed errors; bounds the nesting depth, certificate count, signer
/// count, attribute count, and identifier lengths; and never interprets a
/// value it does not need. It performs no cryptography and no signature
/// verification, does not force-unwrap any parsed value, and does not log
/// payload or certificate bytes.
///
/// The walk is deliberately conservative: a shape outside the subset below is
/// refused rather than approximated, because a CMS message ZynSign only partly
/// understands must not produce a verification conclusion.
///
/// `read(_:mode:)` with `.codeSignature` widens exactly two rules for detached
/// Mach-O code-signature messages — several values on an unmodeled signed
/// attribute, and counted unsigned attributes — and nothing else. `read(_:)`
/// is the provisioning-profile subset, unchanged.
enum CMSStructureReader {

    /// The deepest constructed value the reader will enter. ZynSign policy, not
    /// a published limit.
    static let maximumConstructedDepth = 16

    /// The most certificate-bag entries the reader will delimit.
    static let maximumEmbeddedCertificateCount = 16

    /// The most signers the reader will examine before refusing the message.
    static let maximumSignerCount = 8

    /// The most signed attributes the reader will examine on one signer.
    static let maximumSignedAttributeCount = 32

    /// The most digest algorithms the reader will accept in one message.
    static let maximumDigestAlgorithmCount = 8

    /// The longest serial-number or key-identifier value the reader accepts.
    static let maximumIdentifierByteCount = 64

    /// Reads one CMS message.
    ///
    /// - Throws: A typed `ZynSignError` carrying a `CMSFailure` reason for
    ///   input that is empty, oversized, armored, malformed, truncated,
    ///   unsupported, or beyond a resource bound. A successful return is a
    ///   structural description only.
    static func read(_ data: Data) throws -> CMSStructure {
        try read(data, mode: .provisioningProfile)
    }

    /// Reads one CMS message under an explicit reading mode.
    ///
    /// `read(_:)` is this method in the provisioning-profile mode. The
    /// code-signature mode is for detached Mach-O code-signature messages; see
    /// `CMSStructureReadingMode`.
    static func read(_ data: Data, mode: CMSStructureReadingMode) throws -> CMSStructure {
        do {
            return try readStructure(data, mode: mode)
        } catch let error as CMSStructureError {
            throw error.asZynSignError
        } catch {
            // Nothing but the reader's own errors is expected here; a foreign
            // one is reduced to its CMS reason so that no detail it carries can
            // reach a caller.
            throw ZynSignError.sanitizedCMSFailure(error)
        }
    }

    private static func readStructure(_ data: Data, mode: CMSStructureReadingMode) throws -> CMSStructure {
        if data.isEmpty {
            throw CMSStructureError.empty
        }
        if data.count > ProvisioningProfileInput.maximumByteCount {
            throw CMSStructureError.tooLarge
        }
        let bytes = [UInt8](data)
        if bytes.starts(with: armoredPrefix) {
            throw CMSStructureError.unsupported(
                "Armored CMS input is not accepted; a DER-encoded message is required."
            )
        }

        var reader = Reader(bytes: bytes, index: 0, end: bytes.count, depth: 0)
        let contentInfo = try reader.readTLV()
        guard contentInfo.tag == Tag.sequence, reader.isExhausted else {
            throw CMSStructureError.invalid("The container is not exactly one CMS ContentInfo value.")
        }
        var contentInfoBody = try reader.enter(contentInfo)

        let contentTypeTLV = try contentInfoBody.readTLV()
        guard contentTypeTLV.tag == Tag.objectIdentifier else {
            throw CMSStructureError.invalid("The container's content type is not an object identifier.")
        }
        let contentType = try objectIdentifier(bytes, range: contentTypeTLV.content)
        guard contentType == CMSObjectIdentifiers.signedData else {
            throw CMSStructureError.unsupportedContentType(contentType)
        }

        let contentTLV = try contentInfoBody.readTLV()
        guard contentTLV.tag == Tag.context0, contentInfoBody.isExhausted else {
            throw CMSStructureError.invalid("The container's content is not an explicit context value.")
        }
        var explicitContent = try contentInfoBody.enter(contentTLV)
        let signedDataTLV = try explicitContent.readTLV()
        guard signedDataTLV.tag == Tag.sequence, explicitContent.isExhausted else {
            throw CMSStructureError.invalid("SignedData is not a single sequence value.")
        }
        var signedData = try explicitContent.enter(signedDataTLV)

        let versionTLV = try signedData.readTLV()
        guard versionTLV.tag == Tag.integer else {
            throw CMSStructureError.invalid("The SignedData version is not an integer.")
        }
        let version = try smallInteger(bytes, range: versionTLV.content, accepted: 1...5)

        let digestAlgorithmsTLV = try signedData.readTLV()
        guard digestAlgorithmsTLV.tag == Tag.setOf else {
            throw CMSStructureError.invalid("The digest algorithm collection is not a set.")
        }
        var digestAlgorithms = try signedData.enter(digestAlgorithmsTLV)
        var digestAlgorithmIdentifiers: [String] = []
        while !digestAlgorithms.isExhausted {
            let algorithmTLV = try digestAlgorithms.readTLV()
            guard algorithmTLV.tag == Tag.sequence else {
                throw CMSStructureError.invalid("A digest algorithm entry is not a sequence.")
            }
            guard digestAlgorithmIdentifiers.count < maximumDigestAlgorithmCount else {
                throw CMSStructureError.resourceLimit("The message declares too many digest algorithms.")
            }
            digestAlgorithmIdentifiers.append(
                try algorithmIdentifier(algorithmTLV, enteredFrom: digestAlgorithms, bytes: bytes)
            )
        }

        let encapsulatedTLV = try signedData.readTLV()
        guard encapsulatedTLV.tag == Tag.sequence else {
            throw CMSStructureError.invalid("The encapsulated content information is not a sequence.")
        }
        var encapsulated = try signedData.enter(encapsulatedTLV)
        let encapsulatedTypeTLV = try encapsulated.readTLV()
        guard encapsulatedTypeTLV.tag == Tag.objectIdentifier else {
            throw CMSStructureError.invalid("The encapsulated content type is not an object identifier.")
        }
        let encapsulatedContentType = try objectIdentifier(bytes, range: encapsulatedTypeTLV.content)
        var encapsulatedContent: Data?
        if !encapsulated.isExhausted {
            let explicitContentTLV = try encapsulated.readTLV()
            guard explicitContentTLV.tag == Tag.context0, encapsulated.isExhausted else {
                throw CMSStructureError.invalid("The encapsulated content is not an explicit context value.")
            }
            var contentBody = try encapsulated.enter(explicitContentTLV)
            let octetsTLV = try contentBody.readTLV()
            guard octetsTLV.tag == Tag.octetString, contentBody.isExhausted else {
                throw CMSStructureError.invalid("The encapsulated content is not an octet string.")
            }
            guard octetsTLV.length <= ProvisioningProfilePayload.maximumByteCount else {
                throw CMSStructureError.resourceLimit("The encapsulated content exceeds the payload bound.")
            }
            encapsulatedContent = Data(bytes[octetsTLV.content])
        }

        var certificateEncodings: [Data] = []
        var certificateRevocationListCount = 0
        var signerInfos: [CMSStructureSignerInfo]?
        while !signedData.isExhausted {
            let tag = try signedData.peekTag()
            switch tag {
            case Tag.context0:
                guard signerInfos == nil else {
                    throw CMSStructureError.invalid("SignedData fields are out of order.")
                }
                let bagTLV = try signedData.readTLV()
                var bag = try signedData.enter(bagTLV)
                while !bag.isExhausted {
                    let certificateTLV = try bag.readTLV()
                    guard certificateTLV.tag == Tag.sequence else {
                        throw CMSStructureError.invalid("A certificate bag entry is not a sequence.")
                    }
                    guard certificateEncodings.count < maximumEmbeddedCertificateCount else {
                        throw CMSStructureError.resourceLimit("The certificate bag exceeds the configured bound.")
                    }
                    guard certificateTLV.length <= CertificateInput.maximumByteCount else {
                        throw CMSStructureError.resourceLimit("A certificate bag entry exceeds the certificate bound.")
                    }
                    certificateEncodings.append(Data(bytes[certificateTLV.full]))
                }
            case Tag.context1:
                guard signerInfos == nil else {
                    throw CMSStructureError.invalid("SignedData fields are out of order.")
                }
                let revocationTLV = try signedData.readTLV()
                var revocation = try signedData.enter(revocationTLV)
                while !revocation.isExhausted {
                    _ = try revocation.readTLV()
                    certificateRevocationListCount += 1
                    guard certificateRevocationListCount <= maximumEmbeddedCertificateCount else {
                        throw CMSStructureError.resourceLimit("The revocation collection exceeds the configured bound.")
                    }
                }
            case Tag.setOf:
                guard signerInfos == nil else {
                    throw CMSStructureError.invalid("The message declares signer information twice.")
                }
                let signersTLV = try signedData.readTLV()
                signerInfos = try readSignerInfos(signersTLV, enteredFrom: signedData, bytes: bytes, mode: mode)
            default:
                throw CMSStructureError.invalid("SignedData contains an unexpected field.")
            }
        }
        guard let signerInfos else {
            throw CMSStructureError.invalid("SignedData declares no signer information collection.")
        }

        return CMSStructure(
            contentType: contentType,
            version: version,
            digestAlgorithmIdentifiers: digestAlgorithmIdentifiers,
            encapsulatedContentType: encapsulatedContentType,
            encapsulatedContent: encapsulatedContent,
            certificateEncodings: certificateEncodings,
            certificateRevocationListCount: certificateRevocationListCount,
            signerInfos: signerInfos
        )
    }

    private static let armoredPrefix: [UInt8] = Array("-----BEGIN".utf8)

    // MARK: - Signers

    private static func readSignerInfos(
        _ tlv: TLV,
        enteredFrom reader: Reader,
        bytes: [UInt8],
        mode: CMSStructureReadingMode
    ) throws -> [CMSStructureSignerInfo] {
        var collection = try reader.enter(tlv)
        var infos: [CMSStructureSignerInfo] = []
        while !collection.isExhausted {
            let infoTLV = try collection.readTLV()
            guard infoTLV.tag == Tag.sequence else {
                throw CMSStructureError.invalid("A signer entry is not a sequence.")
            }
            guard infos.count < maximumSignerCount else {
                throw CMSStructureError.resourceLimit("The message declares too many signers.")
            }
            infos.append(try signerInfo(infoTLV, enteredFrom: collection, bytes: bytes, mode: mode))
        }
        return infos
    }

    private static func signerInfo(
        _ tlv: TLV,
        enteredFrom reader: Reader,
        bytes: [UInt8],
        mode: CMSStructureReadingMode
    ) throws -> CMSStructureSignerInfo {
        var body = try reader.enter(tlv)

        let versionTLV = try body.readTLV()
        guard versionTLV.tag == Tag.integer else {
            throw CMSStructureError.invalid("The signer version is not an integer.")
        }
        let version = try smallInteger(bytes, range: versionTLV.content, accepted: 1...3)
        guard version == 1 || version == 3 else {
            throw CMSStructureError.unsupported("Signer version \(version) is not supported.")
        }

        let identifierTLV = try body.readTLV()
        let identifier: CMSStructureSignerIdentifier
        let issuerDER: Data?
        switch identifierTLV.tag {
        case Tag.sequence:
            guard version == 1 else {
                throw CMSStructureError.invalid("The signer version and identifier form disagree.")
            }
            var issuerAndSerial = try body.enter(identifierTLV)
            let issuerStart = issuerAndSerial.index
            let issuerTLV = try issuerAndSerial.readTLV()
            guard issuerTLV.tag == Tag.sequence else {
                throw CMSStructureError.invalid("The signer issuer name is not a sequence.")
            }
            let serialTLV = try issuerAndSerial.readTLV()
            guard serialTLV.tag == Tag.integer, issuerAndSerial.isExhausted else {
                throw CMSStructureError.invalid("The signer serial number is not an integer.")
            }
            guard serialTLV.length > 0, serialTLV.length <= maximumIdentifierByteCount else {
                throw CMSStructureError.invalid("The signer serial number is empty or oversized.")
            }
            issuerDER = Data(bytes[issuerStart..<issuerTLV.content.upperBound])
            identifier = .issuerAndSerialNumber(serialContentBytes: Array(bytes[serialTLV.content]))
        case Tag.context0:
            guard version == 3 else {
                throw CMSStructureError.invalid("The signer version and identifier form disagree.")
            }
            var explicitIdentifier = try body.enter(identifierTLV)
            let keyIdentifierTLV = try explicitIdentifier.readTLV()
            guard keyIdentifierTLV.tag == Tag.octetString, explicitIdentifier.isExhausted else {
                throw CMSStructureError.invalid("The signer key identifier is not an octet string.")
            }
            guard keyIdentifierTLV.length > 0, keyIdentifierTLV.length <= maximumIdentifierByteCount else {
                throw CMSStructureError.invalid("The signer key identifier is empty or oversized.")
            }
            issuerDER = nil
            identifier = .subjectKeyIdentifier(Array(bytes[keyIdentifierTLV.content]))
        default:
            throw CMSStructureError.invalid("The signer identifier has an unexpected form.")
        }

        let digestAlgorithmTLV = try body.readTLV()
        guard digestAlgorithmTLV.tag == Tag.sequence else {
            throw CMSStructureError.invalid("The signer digest algorithm is not a sequence.")
        }
        let digestAlgorithm = try algorithmIdentifier(digestAlgorithmTLV, enteredFrom: body, bytes: bytes)

        var signedAttributes: CMSStructureSignedAttributes?
        if !body.isExhausted, try body.peekTag() == Tag.context0 {
            let attributesTLV = try body.readTLV()
            signedAttributes = try readSignedAttributes(attributesTLV, enteredFrom: body, bytes: bytes, mode: mode)
        }

        let signatureAlgorithmTLV = try body.readTLV()
        guard signatureAlgorithmTLV.tag == Tag.sequence else {
            throw CMSStructureError.invalid("The signer signature algorithm is not a sequence.")
        }
        let signatureAlgorithm = try algorithmIdentifier(signatureAlgorithmTLV, enteredFrom: body, bytes: bytes)

        let signatureTLV = try body.readTLV()
        guard signatureTLV.tag == Tag.octetString, signatureTLV.length > 0 else {
            throw CMSStructureError.invalid("The signer signature value is not a non-empty octet string.")
        }
        guard signatureTLV.length <= 1024 else {
            throw CMSStructureError.resourceLimit("The signer signature value exceeds the configured bound.")
        }
        let signature = Data(bytes[signatureTLV.content])

        var unsignedAttributeCount = 0
        if !body.isExhausted {
            // Unsigned attributes are not covered by the signature, are not
            // part of a provisioning profile, and are refused rather than
            // silently dropped in that mode. A code signature may carry them —
            // a timestamp token is the common case — so the code-signature mode
            // counts them without entering or interpreting their values.
            guard mode == .codeSignature, try body.peekTag() == Tag.context1 else {
                throw CMSStructureError.unsupported("The signer carries attributes outside the signed set.")
            }
            let unsignedTLV = try body.readTLV()
            var unsigned = try body.enter(unsignedTLV)
            while !unsigned.isExhausted {
                let attributeTLV = try unsigned.readTLV()
                guard attributeTLV.tag == Tag.sequence else {
                    throw CMSStructureError.invalid("An unsigned attribute is not a sequence.")
                }
                unsignedAttributeCount += 1
                guard unsignedAttributeCount <= maximumSignedAttributeCount else {
                    throw CMSStructureError.resourceLimit("The signer carries too many unsigned attributes.")
                }
            }
            guard body.isExhausted else {
                throw CMSStructureError.invalid("The signer carries values after its unsigned attributes.")
            }
        }

        return CMSStructureSignerInfo(
            version: version,
            identifier: identifier,
            issuerDER: issuerDER,
            digestAlgorithm: digestAlgorithm,
            signatureAlgorithm: signatureAlgorithm,
            signature: signature,
            signedAttributes: signedAttributes,
            unsignedAttributeCount: unsignedAttributeCount
        )
    }

    private static func readSignedAttributes(
        _ tlv: TLV,
        enteredFrom reader: Reader,
        bytes: [UInt8],
        mode: CMSStructureReadingMode
    ) throws -> CMSStructureSignedAttributes {
        var attributes = try reader.enter(tlv)
        var identifiers: [String] = []
        var messageDigest: Data?
        var contentType: String?
        var signingTime: Date?
        while !attributes.isExhausted {
            let attributeTLV = try attributes.readTLV()
            guard attributeTLV.tag == Tag.sequence else {
                throw CMSStructureError.invalid("A signed attribute is not a sequence.")
            }
            guard identifiers.count < maximumSignedAttributeCount else {
                throw CMSStructureError.resourceLimit("The signer carries too many signed attributes.")
            }
            var attribute = try attributes.enter(attributeTLV)
            let typeTLV = try attribute.readTLV()
            guard typeTLV.tag == Tag.objectIdentifier else {
                throw CMSStructureError.invalid("A signed attribute type is not an object identifier.")
            }
            let identifier = try objectIdentifier(bytes, range: typeTLV.content)
            identifiers.append(identifier)

            let valuesTLV = try attribute.readTLV()
            guard valuesTLV.tag == Tag.setOf, attribute.isExhausted else {
                throw CMSStructureError.invalid("A signed attribute value collection is not a set.")
            }
            var values = try attribute.enter(valuesTLV)
            let valueTLV = try values.readTLV()
            guard values.isExhausted else {
                throw CMSStructureError.invalid("A signed attribute carries more than one value.")
            }

            switch identifier {
            case CMSObjectIdentifiers.attributeMessageDigest:
                guard valueTLV.tag == Tag.octetString, messageDigest == nil else {
                    throw CMSStructureError.invalid("The message-digest attribute is malformed or repeated.")
                }
                guard valueTLV.length <= 64 else {
                    throw CMSStructureError.invalid("The message-digest attribute is oversized.")
                }
                messageDigest = Data(bytes[valueTLV.content])
            case CMSObjectIdentifiers.attributeContentType:
                guard valueTLV.tag == Tag.objectIdentifier, contentType == nil else {
                    throw CMSStructureError.invalid("The content-type attribute is malformed or repeated.")
                }
                contentType = try objectIdentifier(bytes, range: valueTLV.content)
            case CMSObjectIdentifiers.attributeSigningTime:
                // Read only when single-valued and well formed. A malformed
                // time is left unread, exactly as this attribute was before it
                // was modeled, rather than refusing the message.
                if isSingleValued, signingTime == nil {
                    signingTime = declaredTime(bytes, tag: valueTLV.tag, range: valueTLV.content)
                }
            default:
                // Recorded by identifier above and otherwise left alone. An
                // attribute ZynSign does not model is not interpreted.
                break
            }
        }
        guard !identifiers.isEmpty else {
            throw CMSStructureError.invalid("The signed attribute collection is empty.")
        }

        let attributeContent = Array(bytes[tlv.content])
        var verificationMessage: [UInt8] = [Tag.setOf]
        verificationMessage.append(contentsOf: lengthEncoding(attributeContent.count))
        verificationMessage.append(contentsOf: attributeContent)
        return CMSStructureSignedAttributes(
            verificationMessage: Data(verificationMessage),
            attributeObjectIdentifiers: identifiers,
            messageDigest: messageDigest,
            contentType: contentType,
            signingTime: signingTime
        )
    }

    /// Reads a UTCTime (`YYMMDDHHMMSSZ`) or GeneralizedTime
    /// (`YYYYMMDDHHMMSSZ`) value in the strict UTC form DER requires.
    /// Anything else yields `nil`.
    private static func declaredTime(_ bytes: [UInt8], tag: UInt8, range: Range<Int>) -> Date? {
        let utcTimeTag: UInt8 = 0x17
        let generalizedTimeTag: UInt8 = 0x18
        let digitCount: Int
        switch tag {
        case utcTimeTag: digitCount = 12
        case generalizedTimeTag: digitCount = 14
        default: return nil
        }
        guard range.count == digitCount + 1, bytes[range.upperBound - 1] == UInt8(ascii: "Z") else {
            return nil
        }
        var digits: [Int] = []
        digits.reserveCapacity(digitCount)
        for index in range.lowerBound..<(range.upperBound - 1) {
            let byte = bytes[index]
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            digits.append(Int(byte - UInt8(ascii: "0")))
        }
        func number(_ start: Int, _ length: Int) -> Int {
            digits[start..<(start + length)].reduce(0) { $0 * 10 + $1 }
        }
        var components = DateComponents()
        let cursor: Int
        if tag == utcTimeTag {
            // RFC 5280: two-digit years 50–99 are 19YY, 00–49 are 20YY.
            let year = number(0, 2)
            components.year = year >= 50 ? 1900 + year : 2000 + year
            cursor = 2
        } else {
            components.year = number(0, 4)
            cursor = 4
        }
        components.month = number(cursor, 2)
        components.day = number(cursor + 2, 2)
        components.hour = number(cursor + 4, 2)
        components.minute = number(cursor + 6, 2)
        components.second = number(cursor + 8, 2)
        guard let month = components.month, (1...12).contains(month),
              let day = components.day, (1...31).contains(day),
              let hour = components.hour, (0...23).contains(hour),
              let minute = components.minute, (0...59).contains(minute),
              let second = components.second, (0...60).contains(second) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(secondsFromGMT: 0) else { return nil }
        calendar.timeZone = utc
        components.timeZone = utc
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: date).day == day else {
            return nil
        }
        return date
    }

    // MARK: - Shared value readers

    private static func algorithmIdentifier(
        _ tlv: TLV,
        enteredFrom reader: Reader,
        bytes: [UInt8]
    ) throws -> String {
        var body = try reader.enter(tlv)
        let algorithmTLV = try body.readTLV()
        guard algorithmTLV.tag == Tag.objectIdentifier else {
            throw CMSStructureError.invalid("An algorithm identifier is not an object identifier.")
        }
        let identifier = try objectIdentifier(bytes, range: algorithmTLV.content)
        if !body.isExhausted {
            // Parameters are read for their shape only: an algorithm ZynSign
            // maps to a verification operation carries none it needs.
            let parametersTLV = try body.readTLV()
            guard parametersTLV.tag == Tag.null || parametersTLV.tag == Tag.sequence
                || parametersTLV.tag == Tag.objectIdentifier else {
                throw CMSStructureError.invalid("An algorithm identifier has unexpected parameters.")
            }
            guard body.isExhausted else {
                throw CMSStructureError.invalid("An algorithm identifier has trailing values.")
            }
        }
        return identifier
    }

    private static func smallInteger(
        _ bytes: [UInt8],
        range: Range<Int>,
        accepted: ClosedRange<Int>
    ) throws -> Int {
        guard !range.isEmpty, range.count <= 2 else {
            throw CMSStructureError.invalid("An integer value is empty or oversized.")
        }
        var value = 0
        for offset in range {
            value = (value << 8) | Int(bytes[offset])
        }
        guard accepted.contains(value) else {
            throw CMSStructureError.unsupported("An integer value is outside the supported range.")
        }
        return value
    }

    private static func objectIdentifier(_ bytes: [UInt8], range: Range<Int>) throws -> String {
        guard !range.isEmpty else {
            throw CMSStructureError.invalid("An object identifier is empty.")
        }
        var index = range.lowerBound
        func readComponent() throws -> UInt64 {
            var value: UInt64 = 0
            guard index < range.upperBound else {
                throw CMSStructureError.invalid("An object identifier is truncated.")
            }
            while index < range.upperBound {
                let byte = bytes[index]
                index += 1
                if value > (UInt64.max >> 7) {
                    throw CMSStructureError.invalid("An object identifier component is oversized.")
                }
                value = (value << 7) | UInt64(byte & 0x7F)
                if byte & 0x80 == 0 {
                    return value
                }
            }
            throw CMSStructureError.invalid("An object identifier is truncated.")
        }
        let first = try readComponent()
        var arcs: [UInt64]
        if first < 40 {
            arcs = [0, first]
        } else if first < 80 {
            arcs = [1, first - 40]
        } else {
            arcs = [2, first - 80]
        }
        while index < range.upperBound {
            arcs.append(try readComponent())
        }
        return arcs.map(String.init).joined(separator: ".")
    }

    /// Minimal definite-length encoding of `length`, matching the DER the
    /// reader accepts. Re-encoding a signed-attribute collection with this
    /// reproduces the bytes a signature over those attributes covers.
    private static func lengthEncoding(_ length: Int) -> [UInt8] {
        if length < 0x80 {
            return [UInt8(length)]
        }
        var value = length
        var body: [UInt8] = []
        while value > 0 {
            body.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return [UInt8(0x80 | body.count)] + body
    }

    // MARK: - Reader

    private enum Tag {
        static let integer: UInt8 = 0x02
        static let octetString: UInt8 = 0x04
        static let null: UInt8 = 0x05
        static let objectIdentifier: UInt8 = 0x06
        static let sequence: UInt8 = 0x30
        static let setOf: UInt8 = 0x31

        /// `[0] EXPLICIT` / `[0] IMPLICIT`: constructed, context class, tag 0.
        static let context0: UInt8 = 0xA0

        /// `[1] IMPLICIT`: constructed, context class, tag 1.
        static let context1: UInt8 = 0xA1
    }

    private struct TLV {
        let tag: UInt8
        let full: Range<Int>
        let content: Range<Int>
        var length: Int { content.count }
    }

    /// A bounded cursor over the message bytes.
    ///
    /// The reader is a private primitive of this CMS boundary. The certificate
    /// reader has its own equivalent walk with certificate-specific errors; the
    /// two are deliberately separate because their structures, bounds, and
    /// failure taxonomies differ, and consolidating them is recorded as a
    /// deferred cleanup rather than done blind here.
    private struct Reader {
        let bytes: [UInt8]
        var index: Int
        let end: Int
        let depth: Int

        var isExhausted: Bool { index >= end }

        func peekTag() throws -> UInt8 {
            guard index < end else {
                throw CMSStructureError.truncated("The CMS message ends before a value it declares.")
            }
            return bytes[index]
        }

        mutating func readTLV() throws -> TLV {
            guard index < end else {
                throw CMSStructureError.truncated("The CMS message ends before a value it declares.")
            }
            let start = index
            let tag = bytes[index]
            index += 1
            if tag & 0x1F == 0x1F {
                throw CMSStructureError.invalid("The CMS message uses a high-tag-number form.")
            }
            let length = try readLength()
            guard length <= end - index else {
                throw CMSStructureError.truncated("The CMS message ends before a value it declares.")
            }
            let contentStart = index
            index += length
            return TLV(tag: tag, full: start..<index, content: contentStart..<index)
        }

        func enter(_ tlv: TLV) throws -> Reader {
            guard depth < maximumConstructedDepth else {
                throw CMSStructureError.invalid("The CMS message exceeds the nesting bound.")
            }
            return Reader(
                bytes: bytes,
                index: tlv.content.lowerBound,
                end: tlv.content.upperBound,
                depth: depth + 1
            )
        }

        private mutating func readLength() throws -> Int {
            guard index < end else {
                throw CMSStructureError.truncated("The CMS message ends inside a length field.")
            }
            let first = bytes[index]
            index += 1
            if first == 0x80 {
                throw CMSStructureError.unsupported("Indefinite-length encoding is not supported.")
            }
            if first < 0x80 {
                return Int(first)
            }
            let count = Int(first & 0x7F)
            guard count > 0, count <= 4 else {
                throw CMSStructureError.invalid("The CMS message uses an oversized length field.")
            }
            guard count <= end - index else {
                throw CMSStructureError.truncated("The CMS message ends inside a length field.")
            }
            if bytes[index] == 0 {
                throw CMSStructureError.invalid("The CMS message uses a non-minimal length encoding.")
            }
            var value = 0
            for offset in 0..<count {
                value = (value << 8) | Int(bytes[index + offset])
            }
            index += count
            guard count == minimumLongFormOctets(value) else {
                throw CMSStructureError.invalid("The CMS message uses a non-minimal length encoding.")
            }
            return value
        }

        private func minimumLongFormOctets(_ length: Int) -> Int {
            if length < 128 { return 0 }
            if length < 256 { return 1 }
            if length < 65_536 { return 2 }
            if length < 16_777_216 { return 3 }
            return 4
        }
    }
}

/// The structural failures this reader distinguishes, mapped to the shared
/// CMS error vocabulary.
private enum CMSStructureError: Error {

    case empty
    case tooLarge
    case unsupported(String)
    case unsupportedContentType(String)
    case truncated(String)
    case invalid(String)
    case resourceLimit(String)

    var asZynSignError: ZynSignError {
        switch self {
        case .empty:
            return .cms(.emptyInput, diagnosticDetail: "The CMS container is empty.")
        case .tooLarge:
            return .cms(.inputTooLarge, diagnosticDetail: "The CMS container exceeds the accepted size.")
        case .unsupported(let detail):
            return .cms(.unsupportedStructure, diagnosticDetail: detail)
        case .unsupportedContentType(let identifier):
            return .cms(
                .unsupportedContentType,
                diagnosticDetail: "The CMS content type \(identifier) is not signedData."
            )
        case .truncated(let detail):
            return .cms(.truncatedCMS, diagnosticDetail: detail)
        case .invalid(let detail):
            return .cms(.malformedCMS, diagnosticDetail: detail)
        case .resourceLimit(let detail):
            return .cms(.resourceLimitExceeded, diagnosticDetail: detail)
        }
    }
}
