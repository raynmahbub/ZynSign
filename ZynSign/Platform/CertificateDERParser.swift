import Foundation

/// A bounded reader for the X.509 fields ZynSign inspects.
///
/// `SecCertificateCopyValues` is documented for macOS 10.7 and is not part of
/// the iOS API surface, so it cannot be the metadata source on the iOS 17
/// deployment target. This reader extracts only the fields the domain model
/// requires. It does not evaluate a signature, does not build a chain, and
/// does not decide trust or code-signing policy.
///
/// Input is untrusted. The reader rejects empty, oversized, PEM, indefinite-
/// length, truncated, and non-minimal encodings with typed errors. It does
/// not force-unwrap parsed values, does not log certificate bytes, and does
/// not execute anything it reads. An unrecognised algorithm or name attribute
/// is recorded, not rejected.
enum CertificateDERParser {

    /// The deepest constructed value the reader will enter.
    ///
    /// Ordinary certificates stay well under this. The cap is ZynSign policy
    /// so a nested encoding cannot grow the walk without bound.
    static let maximumConstructedDepth = 16

    /// Parses `input` and returns metadata.
    ///
    /// The fingerprint is the SHA-256 of `input.bytes`. Those bytes are the
    /// certificate that was accepted: trailing data is rejected, and the
    /// digest is not taken from a platform re-encoding.
    static func parse(_ input: CertificateInput) throws -> CertificateMetadata {
        try signingFields(input).metadata
    }

    /// Original encodings are required for CMS issuer-and-serial identification.
    /// This extends the existing parse, not a second certificate decoder.
    struct SigningFields {
        let metadata: CertificateMetadata
        let issuerDER: Data
        let serialDER: Data
    }

    static func signingFields(_ input: CertificateInput) throws -> SigningFields {
        do { return try parseCertificate(input) }
        catch let error as DERError { throw error.asZynSignError }
    }

    private static func parseCertificate(_ input: CertificateInput) throws -> SigningFields {
        if input.bytes.isEmpty {
            throw DERError.empty
        }
        if input.bytes.count > CertificateInput.maximumByteCount {
            throw DERError.tooLarge
        }
        let bytes = [UInt8](input.bytes)
        if bytes.starts(with: pemPrefix) {
            throw DERError.unsupported("PEM encoding is not a supported certificate format.")
        }

        var reader = Reader(bytes: bytes, index: 0, end: bytes.count, depth: 0)
        let certificate = try reader.readTLV()
        guard certificate.tag == 0x30, reader.isExhausted else {
            throw DERError.invalid("Certificate structure is not valid.")
        }
        var body = try reader.enter(certificate)

        let tbs = try body.readTLV()
        guard tbs.tag == 0x30 else {
            throw DERError.invalid("Certificate structure is not valid.")
        }
        let signatureAlgorithmTLV = try body.readTLV()
        guard signatureAlgorithmTLV.tag == 0x30 else {
            throw DERError.invalid("Certificate structure is not valid.")
        }
        let signature = try body.readTLV()
        guard signature.tag == 0x03, body.isExhausted else {
            throw DERError.invalid("Certificate structure is not valid.")
        }
        try validateBitString(signature, in: bytes)

        var tbsReader = try body.enter(tbs)
        if !tbsReader.isExhausted, try tbsReader.peekTag() == 0xA0 {
            let version = try tbsReader.readTLV()
            var versionReader = try tbsReader.enter(version)
            let versionInteger = try versionReader.readTLV()
            guard versionInteger.tag == 0x02, versionReader.isExhausted else {
                throw DERError.invalid("Certificate structure is not valid.")
            }
            guard versionInteger.length > 0, versionInteger.length <= 4 else {
                throw DERError.invalid("Certificate structure is not valid.")
            }
        }

        let serialStart = tbsReader.index
        let serialTLV = try tbsReader.readTLV()
        guard serialTLV.tag == 0x02 else {
            throw DERError.invalid("Certificate structure is not valid.")
        }
        let serial = try serialNumber(from: bytes, range: serialTLV.content)

        let tbsSignature = try readAlgorithmIdentifier(try tbsReader.readTLV(), in: bytes, enteredFrom: tbsReader)
        let issuerStart = tbsReader.index
        let issuerTLV = try tbsReader.readTLV()
        let issuer = try readName(issuerTLV, enteredFrom: tbsReader)
        let validity = try readValidity(try tbsReader.readTLV(), enteredFrom: tbsReader)
        let subject = try readName(try tbsReader.readTLV(), enteredFrom: tbsReader)
        let publicKey = try readPublicKey(try tbsReader.readTLV(), in: bytes, enteredFrom: tbsReader)

        while !tbsReader.isExhausted {
            let tag = try tbsReader.peekTag()
            guard tag == 0xA1 || tag == 0xA2 || tag == 0xA3 else {
                throw DERError.invalid("Certificate structure is not valid.")
            }
            _ = try tbsReader.readTLV()
        }

        let outerSignature = try readAlgorithmIdentifier(signatureAlgorithmTLV, in: bytes, enteredFrom: body)
        guard outerSignature == tbsSignature else {
            throw DERError.invalid("Certificate signature algorithm identifiers do not match.")
        }

        let digest = CertificateDigest.sha256(bytes)
        guard let fingerprint = CertificateFingerprint(digestBytes: digest) else {
            throw DERError.unavailable("SHA-256 fingerprint could not be recorded.")
        }
        let metadata = CertificateMetadata(
            subject: subject,
            issuer: issuer,
            serialNumber: serial,
            notValidBefore: validity.notBefore,
            notValidAfter: validity.notAfter,
            publicKeyInfo: publicKey,
            signatureAlgorithm: SignatureAlgorithm.from(objectIdentifier: outerSignature),
            sha256Fingerprint: fingerprint
        )
        return SigningFields(metadata: metadata,
                             issuerDER: Data(bytes[issuerStart..<issuerTLV.content.upperBound]),
                             serialDER: Data(bytes[serialStart..<serialTLV.content.upperBound]))
    }

    private static let pemPrefix: [UInt8] = Array("-----BEGIN".utf8)

    // MARK: - Names

    private static func readName(_ tlv: TLV, enteredFrom reader: Reader) throws -> CertificateDistinguishedName {
        guard tlv.tag == 0x30 else {
            throw DERError.invalid("Certificate structure is not valid.")
        }
        var name = try reader.enter(tlv)
        var attributes: [CertificateNameAttribute] = []
        while !name.isExhausted {
            let set = try name.readTLV()
            guard set.tag == 0x31 else {
                throw DERError.invalid("Certificate structure is not valid.")
            }
            var setReader = try name.enter(set)
            while !setReader.isExhausted {
                let attribute = try setReader.readTLV()
                guard attribute.tag == 0x30 else {
                    throw DERError.invalid("Certificate structure is not valid.")
                }
                var attributeReader = try setReader.enter(attribute)
                let oidTLV = try attributeReader.readTLV()
                guard oidTLV.tag == 0x06 else {
                    throw DERError.invalid("Certificate structure is not valid.")
                }
                let oid = try decodeObjectIdentifier(reader.bytes, range: oidTLV.content)
                guard !attributeReader.isExhausted else {
                    throw DERError.unavailable("Required certificate metadata is absent.")
                }
                let valueTLV = try attributeReader.readTLV()
                guard attributeReader.isExhausted else {
                    throw DERError.invalid("Certificate structure is not valid.")
                }
                attributes.append(nameAttribute(oid: oid, value: valueTLV, bytes: reader.bytes))
            }
        }
        return CertificateDistinguishedName.from(attributes: attributes)
    }

    private static func nameAttribute(oid: String, value: TLV, bytes: [UInt8]) -> CertificateNameAttribute {
        let recognition = CertificateNameAttribute.recognition(for: oid)
        let content = Array(bytes[value.content])
        let decoded: CertificateNameAttribute.Value
        switch value.tag {
        case 0x0C:
            if let text = String(bytes: content, encoding: .utf8) {
                decoded = .text(text)
            } else {
                decoded = .undecodedHexadecimal(CertificateSerialNumber.hexadecimal(of: content))
            }
        case 0x13, 0x16:
            if content.allSatisfy({ $0 < 0x80 }), let text = String(bytes: content, encoding: .ascii) {
                decoded = .text(text)
            } else {
                decoded = .undecodedHexadecimal(CertificateSerialNumber.hexadecimal(of: content))
            }
        default:
            decoded = .undecodedHexadecimal(CertificateSerialNumber.hexadecimal(of: content))
        }
        return CertificateNameAttribute(
            objectIdentifier: oid,
            recognition: recognition,
            value: decoded
        )
    }

    // MARK: - Validity

    private static func readValidity(_ tlv: TLV, enteredFrom reader: Reader) throws -> (notBefore: Date, notAfter: Date) {
        guard tlv.tag == 0x30 else {
            throw DERError.invalid("Certificate structure is not valid.")
        }
        var validity = try reader.enter(tlv)
        let notBefore = try readTime(try validity.readTLV(), bytes: reader.bytes)
        let notAfter = try readTime(try validity.readTLV(), bytes: reader.bytes)
        guard validity.isExhausted else {
            throw DERError.invalid("Certificate structure is not valid.")
        }
        return (notBefore, notAfter)
    }

    private static func readTime(_ tlv: TLV, bytes: [UInt8]) throws -> Date {
        guard tlv.tag == 0x17 || tlv.tag == 0x18 else {
            throw DERError.invalid("Certificate structure is not valid.")
        }
        let content = Array(bytes[tlv.content])
        guard content.allSatisfy({ $0 < 0x80 }), let text = String(bytes: content, encoding: .ascii) else {
            throw DERError.invalid("Certificate structure is not valid.")
        }
        guard text.hasSuffix("Z") else {
            throw DERError.invalid("Certificate structure is not valid.")
        }
        let body = String(text.dropLast())
        if tlv.tag == 0x17 {
            return try utcTime(body)
        }
        return try generalizedTime(body)
    }

    private static func utcTime(_ body: String) throws -> Date {
        let digits: String
        if body.count == 12 {
            digits = body
        } else if body.count == 10 {
            digits = body + "00"
        } else {
            throw DERError.invalid("Certificate structure is not valid.")
        }
        let yearTwo = try integer(digits, from: 0, count: 2)
        let year = yearTwo >= 50 ? 1900 + yearTwo : 2000 + yearTwo
        return try date(
            year: year,
            month: try integer(digits, from: 2, count: 2),
            day: try integer(digits, from: 4, count: 2),
            hour: try integer(digits, from: 6, count: 2),
            minute: try integer(digits, from: 8, count: 2),
            second: try integer(digits, from: 10, count: 2),
            fraction: 0
        )
    }

    private static func generalizedTime(_ body: String) throws -> Date {
        let main: String
        let fraction: Double
        if let dot = body.firstIndex(of: ".") {
            main = String(body[..<dot])
            let fractionText = body[body.index(after: dot)...]
            guard !fractionText.isEmpty, fractionText.allSatisfy(\.isNumber) else {
                throw DERError.invalid("Certificate structure is not valid.")
            }
            var numerator = 0.0
            var denominator = 1.0
            for character in fractionText {
                guard let digit = character.wholeNumberValue else {
                    throw DERError.invalid("Certificate structure is not valid.")
                }
                numerator = numerator * 10 + Double(digit)
                denominator *= 10
            }
            fraction = numerator / denominator
        } else {
            main = body
            fraction = 0
        }
        guard main.count == 14 else {
            throw DERError.invalid("Certificate structure is not valid.")
        }
        return try date(
            year: try integer(main, from: 0, count: 4),
            month: try integer(main, from: 4, count: 2),
            day: try integer(main, from: 6, count: 2),
            hour: try integer(main, from: 8, count: 2),
            minute: try integer(main, from: 10, count: 2),
            second: try integer(main, from: 12, count: 2),
            fraction: fraction
        )
    }

    private static func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int,
        fraction: Double
    ) throws -> Date {
        guard year >= 1, year <= 9999 else {
            throw DERError.invalid("Certificate structure is not valid.")
        }
        guard month >= 1, month <= 12, day >= 1, day <= daysInMonth(year: year, month: month) else {
            throw DERError.invalid("Certificate structure is not valid.")
        }
        guard hour >= 0, hour <= 23, minute >= 0, minute <= 59, second >= 0, second <= 59 else {
            throw DERError.invalid("Certificate structure is not valid.")
        }
        let days = daysFromCivil(year: year, month: month, day: day)
        let whole = TimeInterval(days) * 86_400 + TimeInterval(hour * 3_600 + minute * 60 + second)
        return Date(timeIntervalSince1970: whole + fraction)
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2: return isLeapYear(year) ? 29 : 28
        default: return 0
        }
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        if year % 400 == 0 { return true }
        if year % 100 == 0 { return false }
        return year % 4 == 0
    }

    /// Days from 1970-01-01 for a Gregorian civil date. Valid for the positive
    /// years the time parser accepts.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        var year = year
        if month <= 2 { year -= 1 }
        let era = year / 400
        let yearOfEra = year - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func integer(_ text: String, from offset: Int, count: Int) throws -> Int {
        let start = text.index(text.startIndex, offsetBy: offset)
        let end = text.index(start, offsetBy: count)
        let slice = text[start..<end]
        guard slice.allSatisfy(\.isNumber), let value = Int(slice, radix: 10) else {
            throw DERError.invalid("Certificate structure is not valid.")
        }
        return value
    }

    // MARK: - Keys and algorithms

    private static func readAlgorithmIdentifier(
        _ tlv: TLV,
        in bytes: [UInt8],
        enteredFrom reader: Reader
    ) throws -> String {
        guard tlv.tag == 0x30 else {
            throw DERError.invalid("Certificate structure is not valid.")
        }
        var algorithm = try reader.enter(tlv)
        let oidTLV = try algorithm.readTLV()
        guard oidTLV.tag == 0x06 else {
            throw DERError.invalid("Certificate structure is not valid.")
        }
        let oid = try decodeObjectIdentifier(bytes, range: oidTLV.content)
        if !algorithm.isExhausted {
            _ = try algorithm.readTLV()
            guard algorithm.isExhausted else {
                throw DERError.invalid("Certificate structure is not valid.")
            }
        }
        return oid
    }

    private static func readPublicKey(
        _ tlv: TLV,
        in bytes: [UInt8],
        enteredFrom reader: Reader
    ) throws -> PublicKeyInfo {
        guard tlv.tag == 0x30 else {
            throw DERError.invalid("Certificate structure is not valid.")
        }
        var keyInfo = try reader.enter(tlv)
        let algorithmTLV = try keyInfo.readTLV()
        guard algorithmTLV.tag == 0x30 else {
            throw DERError.invalid("Certificate structure is not valid.")
        }
        var algorithm = try keyInfo.enter(algorithmTLV)
        let oidTLV = try algorithm.readTLV()
        guard oidTLV.tag == 0x06 else {
            throw DERError.invalid("Certificate structure is not valid.")
        }
        let oid = try decodeObjectIdentifier(bytes, range: oidTLV.content)
        var parameter: TLV?
        if !algorithm.isExhausted {
            parameter = try algorithm.readTLV()
            guard algorithm.isExhausted else {
                throw DERError.invalid("Certificate structure is not valid.")
            }
        }
        let bitString = try keyInfo.readTLV()
        guard bitString.tag == 0x03, keyInfo.isExhausted else {
            throw DERError.invalid("Certificate structure is not valid.")
        }
        try validateBitString(bitString, in: bytes)

        if oid == CertificateAlgorithmIdentifiers.rsaEncryption {
            return try rsaPublicKey(bitString, in: bytes, depth: keyInfo.depth)
        }
        if oid == CertificateAlgorithmIdentifiers.ecPublicKey {
            return try ecPublicKey(parameter: parameter, in: bytes)
        }
        return PublicKeyInfo(algorithm: .unknown(oid))
    }

    private static func rsaPublicKey(_ bitString: TLV, in bytes: [UInt8], depth: Int) throws -> PublicKeyInfo {
        guard bitString.length >= 1, bytes[bitString.content.lowerBound] == 0 else {
            throw DERError.invalid("Certificate structure is not valid.")
        }
        let payloadStart = bitString.content.lowerBound + 1
        let payloadEnd = bitString.content.upperBound
        var key = Reader(bytes: bytes, index: payloadStart, end: payloadEnd, depth: depth + 1)
        guard key.depth <= maximumConstructedDepth else {
            throw DERError.invalid("Certificate encoding exceeds the nesting limit.")
        }
        let sequence = try key.readTLV()
        guard sequence.tag == 0x30, key.isExhausted else {
            throw DERError.invalid("Certificate structure is not valid.")
        }
        var fields = try key.enter(sequence)
        let modulus = try fields.readTLV()
        let exponent = try fields.readTLV()
        guard modulus.tag == 0x02, exponent.tag == 0x02, fields.isExhausted else {
            throw DERError.invalid("Certificate structure is not valid.")
        }
        try validatePositiveInteger(bytes, range: modulus.content)
        try validatePositiveInteger(bytes, range: exponent.content)
        let size = integerBitLength(bytes, range: modulus.content)
        guard size > 0 else {
            throw DERError.invalid("Certificate structure is not valid.")
        }
        return PublicKeyInfo(algorithm: .rsa, keySizeInBits: size)
    }

    private static func ecPublicKey(parameter: TLV?, in bytes: [UInt8]) throws -> PublicKeyInfo {
        guard let parameter else {
            return PublicKeyInfo(algorithm: .ec)
        }
        guard parameter.tag == 0x06 else {
            return PublicKeyInfo(algorithm: .ec)
        }
        let identifier = try decodeObjectIdentifier(bytes, range: parameter.content)
        if let curve = CertificateAlgorithmIdentifiers.namedCurve(for: identifier) {
            return PublicKeyInfo(
                algorithm: .ec,
                keySizeInBits: curve.sizeInBits,
                curveName: curve.name,
                curveIdentifier: identifier
            )
        }
        return PublicKeyInfo(algorithm: .ec, curveIdentifier: identifier)
    }

    // MARK: - Integers and identifiers

    private static func serialNumber(from bytes: [UInt8], range: Range<Int>) throws -> CertificateSerialNumber {
        try validatePositiveInteger(bytes, range: range)
        let content = Array(bytes[range])
        guard let serial = CertificateSerialNumber(contentBytes: content) else {
            throw DERError.unavailable("Required certificate metadata is absent.")
        }
        return serial
    }

    private static func validatePositiveInteger(_ bytes: [UInt8], range: Range<Int>) throws {
        guard !range.isEmpty else {
            throw DERError.unavailable("Required certificate metadata is absent.")
        }
        if bytes[range.lowerBound] & 0x80 != 0 {
            throw DERError.invalid("Certificate structure is not valid.")
        }
        if bytes[range].allSatisfy({ $0 == 0 }) {
            throw DERError.invalid("Certificate structure is not valid.")
        }
        if range.count >= 2 && bytes[range.lowerBound] == 0 && bytes[range.lowerBound + 1] & 0x80 == 0 {
            throw DERError.invalid("Certificate structure is not valid.")
        }
    }

    private static func integerBitLength(_ bytes: [UInt8], range: Range<Int>) -> Int {
        var index = range.lowerBound
        while index < range.upperBound && bytes[index] == 0 {
            index += 1
        }
        guard index < range.upperBound else { return 0 }
        var width = 0
        var value = bytes[index]
        while value > 0 {
            width += 1
            value >>= 1
        }
        return (range.upperBound - index - 1) * 8 + width
    }

    private static func validateBitString(_ tlv: TLV, in bytes: [UInt8]) throws {
        guard tlv.length >= 1 else {
            throw DERError.invalid("Certificate structure is not valid.")
        }
        let unused = bytes[tlv.content.lowerBound]
        guard unused <= 7 else {
            throw DERError.invalid("Certificate structure is not valid.")
        }
    }

    private static func decodeObjectIdentifier(_ bytes: [UInt8], range: Range<Int>) throws -> String {
        var index = range.lowerBound
        func readComponent() throws -> UInt64 {
            var value: UInt64 = 0
            guard index < range.upperBound else {
                throw DERError.invalid("Certificate structure is not valid.")
            }
            while index < range.upperBound {
                let byte = bytes[index]
                index += 1
                if value > (UInt64.max >> 7) {
                    throw DERError.invalid("Certificate structure is not valid.")
                }
                value = (value << 7) | UInt64(byte & 0x7F)
                if byte & 0x80 == 0 {
                    return value
                }
            }
            throw DERError.invalid("Certificate structure is not valid.")
        }
        guard range.lowerBound < range.upperBound else {
            throw DERError.invalid("Certificate structure is not valid.")
        }
        let first = try readComponent()
        var arcs: [UInt64] = []
        if first < 40 {
            arcs.append(0)
            arcs.append(first)
        } else if first < 80 {
            arcs.append(1)
            arcs.append(first - 40)
        } else {
            arcs.append(2)
            arcs.append(first - 80)
        }
        while index < range.upperBound {
            arcs.append(try readComponent())
        }
        return arcs.map(String.init).joined(separator: ".")
    }

    // MARK: - Reader

    private struct TLV {
        let tag: UInt8
        let content: Range<Int>
        var length: Int { content.count }
    }

    private struct Reader {
        let bytes: [UInt8]
        var index: Int
        let end: Int
        let depth: Int

        var isExhausted: Bool { index >= end }
        var remaining: Int { end - index }

        func peekTag() throws -> UInt8 {
            guard index < end else {
                throw DERError.truncated("Certificate encoding is truncated.")
            }
            return bytes[index]
        }

        mutating func readTLV() throws -> TLV {
            guard index < end else {
                throw DERError.truncated("Certificate encoding is truncated.")
            }
            let tag = bytes[index]
            index += 1
            if tag & 0x1F == 0x1F {
                throw DERError.invalid("Certificate structure is not valid.")
            }
            let length = try readLength()
            guard length <= end - index else {
                throw DERError.truncated("Certificate encoding is truncated.")
            }
            let start = index
            index += length
            return TLV(tag: tag, content: start..<index)
        }

        func enter(_ tlv: TLV) throws -> Reader {
            guard depth < CertificateDERParser.maximumConstructedDepth else {
                throw DERError.invalid("Certificate encoding exceeds the nesting limit.")
            }
            return Reader(bytes: bytes, index: tlv.content.lowerBound, end: tlv.content.upperBound, depth: depth + 1)
        }

        private mutating func readLength() throws -> Int {
            guard index < end else {
                throw DERError.truncated("Certificate encoding is truncated.")
            }
            let first = bytes[index]
            index += 1
            if first == 0x80 {
                throw DERError.unsupported("Indefinite-length encoding is not supported.")
            }
            if first < 0x80 {
                return Int(first)
            }
            let count = Int(first & 0x7F)
            guard count > 0, count <= 4 else {
                throw DERError.invalid("Certificate length encoding is not valid.")
            }
            guard count <= end - index else {
                throw DERError.truncated("Certificate encoding is truncated.")
            }
            if bytes[index] == 0 {
                throw DERError.invalid("Certificate length encoding is not valid.")
            }
            var value = 0
            for offset in 0..<count {
                value = (value << 8) | Int(bytes[index + offset])
            }
            index += count
            guard count == minimumLongFormOctets(value) else {
                throw DERError.invalid("Certificate length encoding is not valid.")
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

private enum DERError: Error {
    case empty
    case tooLarge
    case unsupported(String)
    case truncated(String)
    case invalid(String)
    case unavailable(String)

    var asZynSignError: ZynSignError {
        switch self {
        case .empty:
            return .emptyCertificateInput(diagnosticDetail: "Certificate input is empty.")
        case .tooLarge:
            return .certificateInputTooLarge(diagnosticDetail: "Certificate input exceeds the accepted size.")
        case .unsupported(let detail):
            return .unsupportedCertificateFormat(diagnosticDetail: detail)
        case .truncated(let detail):
            return .truncatedCertificate(diagnosticDetail: detail)
        case .invalid(let detail):
            return .invalidCertificateStructure(diagnosticDetail: detail)
        case .unavailable(let detail):
            return .unavailableCertificateMetadata(diagnosticDetail: detail)
        }
    }
}
