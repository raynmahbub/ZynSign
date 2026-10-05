import Foundation

extension CMSStructureReader {
    // MARK: - Signers

    static func readSignerInfos(
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

    private struct SignerIdentifierFields {
        let version: Int
        let identifier: CMSStructureSignerIdentifier
        let issuerDER: Data?
    }

    private static func signerInfo(
        _ tlv: TLV,
        enteredFrom reader: Reader,
        bytes: [UInt8],
        mode: CMSStructureReadingMode
    ) throws -> CMSStructureSignerInfo {
        var body = try reader.enter(tlv)
        let identity = try readSignerIdentifier(from: &body, bytes: bytes)
        let digestTLV = try body.readTLV()
        guard digestTLV.tag == Tag.sequence else {
            throw CMSStructureError.invalid("The signer digest algorithm is not a sequence.")
        }
        let digestAlgorithm = try algorithmIdentifier(digestTLV, enteredFrom: body, bytes: bytes)
        let signedAttributes = try readSignedAttributesIfPresent(from: &body, bytes: bytes, mode: mode)
        let signatureAlgorithm = try readSignatureAlgorithm(from: &body, bytes: bytes)
        let signature = try readSignatureValue(from: &body, bytes: bytes)
        let unsignedAttributeCount = try readUnsignedAttributeCount(from: &body, mode: mode)
        return CMSStructureSignerInfo(
            version: identity.version,
            identifier: identity.identifier,
            issuerDER: identity.issuerDER,
            digestAlgorithm: digestAlgorithm,
            signatureAlgorithm: signatureAlgorithm,
            signature: signature,
            signedAttributes: signedAttributes,
            unsignedAttributeCount: unsignedAttributeCount
        )
    }

    private static func readSignerIdentifier(
        from body: inout Reader,
        bytes: [UInt8]
    ) throws -> SignerIdentifierFields {
        let versionTLV = try body.readTLV()
        guard versionTLV.tag == Tag.integer else {
            throw CMSStructureError.invalid("The signer version is not an integer.")
        }
        let version = try smallInteger(bytes, range: versionTLV.content, accepted: 1...3)
        guard version == 1 || version == 3 else {
            throw CMSStructureError.unsupported("Signer version \(version) is not supported.")
        }
        let identifierTLV = try body.readTLV()
        switch identifierTLV.tag {
        case Tag.sequence:
            guard version == 1 else {
                throw CMSStructureError.invalid("The signer version and identifier form disagree.")
            }
            return try readIssuerAndSerial(identifierTLV, from: body, bytes: bytes, version: version)
        case Tag.context0:
            guard version == 3 else {
                throw CMSStructureError.invalid("The signer version and identifier form disagree.")
            }
            return try readSubjectKeyIdentifier(identifierTLV, from: body, bytes: bytes, version: version)
        default:
            throw CMSStructureError.invalid("The signer identifier has an unexpected form.")
        }
    }

    private static func readIssuerAndSerial(
        _ tlv: TLV,
        from body: Reader,
        bytes: [UInt8],
        version: Int
    ) throws -> SignerIdentifierFields {
        var issuerAndSerial = try body.enter(tlv)
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
        return SignerIdentifierFields(
            version: version,
            identifier: .issuerAndSerialNumber(serialContentBytes: Array(bytes[serialTLV.content])),
            issuerDER: Data(bytes[issuerStart..<issuerTLV.content.upperBound])
        )
    }

    private static func readSubjectKeyIdentifier(
        _ tlv: TLV,
        from body: Reader,
        bytes: [UInt8],
        version: Int
    ) throws -> SignerIdentifierFields {
        var explicitIdentifier = try body.enter(tlv)
        let keyIdentifierTLV = try explicitIdentifier.readTLV()
        guard keyIdentifierTLV.tag == Tag.octetString, explicitIdentifier.isExhausted else {
            throw CMSStructureError.invalid("The signer key identifier is not an octet string.")
        }
        guard keyIdentifierTLV.length > 0, keyIdentifierTLV.length <= maximumIdentifierByteCount else {
            throw CMSStructureError.invalid("The signer key identifier is empty or oversized.")
        }
        return SignerIdentifierFields(
            version: version,
            identifier: .subjectKeyIdentifier(Array(bytes[keyIdentifierTLV.content])),
            issuerDER: nil
        )
    }

    private static func readSignedAttributesIfPresent(
        from body: inout Reader,
        bytes: [UInt8],
        mode: CMSStructureReadingMode
    ) throws -> CMSStructureSignedAttributes? {
        guard !body.isExhausted, try body.peekTag() == Tag.context0 else { return nil }
        let attributesTLV = try body.readTLV()
        return try readSignedAttributes(attributesTLV, enteredFrom: body, bytes: bytes, mode: mode)
    }

    private static func readSignatureAlgorithm(
        from body: inout Reader,
        bytes: [UInt8]
    ) throws -> String {
        let algorithmTLV = try body.readTLV()
        guard algorithmTLV.tag == Tag.sequence else {
            throw CMSStructureError.invalid("The signer signature algorithm is not a sequence.")
        }
        return try algorithmIdentifier(algorithmTLV, enteredFrom: body, bytes: bytes)
    }

    private static func readSignatureValue(from body: inout Reader, bytes: [UInt8]) throws -> Data {
        let signatureTLV = try body.readTLV()
        guard signatureTLV.tag == Tag.octetString, signatureTLV.length > 0 else {
            throw CMSStructureError.invalid("The signer signature value is not a non-empty octet string.")
        }
        guard signatureTLV.length <= 1024 else {
            throw CMSStructureError.resourceLimit("The signer signature value exceeds the configured bound.")
        }
        return Data(bytes[signatureTLV.content])
    }

    private static func readUnsignedAttributeCount(
        from body: inout Reader,
        mode: CMSStructureReadingMode
    ) throws -> Int {
        guard !body.isExhausted else { return 0 }
        guard mode == .codeSignature, try body.peekTag() == Tag.context1 else {
            throw CMSStructureError.unsupported("The signer carries attributes outside the signed set.")
        }
        let unsignedTLV = try body.readTLV()
        var unsigned = try body.enter(unsignedTLV)
        var count = 0
        while !unsigned.isExhausted {
            let attributeTLV = try unsigned.readTLV()
            guard attributeTLV.tag == Tag.sequence else {
                throw CMSStructureError.invalid("An unsigned attribute is not a sequence.")
            }
            count += 1
            guard count <= maximumSignedAttributeCount else {
                throw CMSStructureError.resourceLimit("The signer carries too many unsigned attributes.")
            }
        }
        guard body.isExhausted else {
            throw CMSStructureError.invalid("The signer carries values after its unsigned attributes.")
        }
        return count
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
                if signingTime == nil {
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

}
