import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Pure-Swift GrandSlam (`GsService2`) SRP-6a (RFC 5054 2048-bit group, SHA-256)
/// client and session-envelope decryptor for Apple Developer Portal sign-in.
enum AppleGSASRP6a {

    enum Failure: Error, Equatable, Sendable {
        case invalidServerChallenge
        case invalidPublicKey
        case keyDerivationFailed
        case serverProofMismatch
        case negotiatedProtocolMismatch
        case payloadDecryptionFailed
    }

    /// RFC 5054 2048-bit safe prime `N` (256 bytes, big-endian).
    static let prime2048Hex =
        "AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050"
        + "A37329CBB4A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA04FD50"
        + "E8083969EDB767B0CF6095179A163AB3661A05FBD5FAAAE82918A9962F0B93B8"
        + "55F97993EC975EEAA80D740ADBF4FF747359D041D5C33EA71D281E446B14773B"
        + "CA97B43A23FB801676BD207A436C6481F1D2B9078717461A5B9D32E688F87748"
        + "544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB3786160279004E57AE6"
        + "AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DBFBB6"
        + "94B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F9E4AFF73"

    static let primeByteCount = 256
    static let primeBytes: Data = decodeHex(prime2048Hex)
    private static let primeN = BigUInt(bigEndian: primeBytes)
    private static let generatorG = BigUInt(word: 2)

    struct ClientHandshake: Sendable {
        let ephemeralSecretA: Data
        /// 256-byte big-endian client public ephemeral `A = g^a mod N` (`A2k`).
        let publicEphemeralA: Data
    }

    struct ChallengeResponse: Equatable, Sendable {
        /// Client proof `M1` sent in `"o": "complete"`.
        let clientProofM1: Data
        /// Expected server proof `M2` returned in `"o": "complete"`.
        let expectedServerProofM2: Data
        /// 32-byte SRP session key `K = SHA256(PAD(S))`.
        let sessionKeyK: Data
    }

    /// Starts a fresh client SRP-6a exchange.
    static func startAuthentication(ephemeralSecret overrideSecret: Data? = nil) -> ClientHandshake {
        let secretData: Data
        if let overrideSecret, !overrideSecret.isEmpty {
            secretData = overrideSecret
        } else {
            var random = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, random.count, &random)
            secretData = Data(random)
        }
        let a = BigUInt(bigEndian: secretData)
        let capA = BigUInt.modPow(base: generatorG, exponent: a, modulus: primeN)
        return ClientHandshake(
            ephemeralSecretA: secretData,
            publicEphemeralA: capA.toBigEndian(paddedTo: primeByteCount)
        )
    }

    /// Derives the PBKDF2-HMAC-SHA256 password key for GSA `s2k` or `s2k_fo`.
    static func derivePasswordKey(
        password: String,
        protocolVariant: String,
        salt: Data,
        iterations: Int
    ) throws -> Data {
        guard !salt.isEmpty, iterations > 0, iterations <= 500_000 else {
            throw Failure.keyDerivationFailed
        }
        let rawDigest = Data(SHA256.hash(data: Data(password.utf8)))
        let pbkdfInput: Data
        if protocolVariant == "s2k" {
            pbkdfInput = rawDigest
        } else {
            let hex = rawDigest.map { String(format: "%02x", $0) }.joined()
            pbkdfInput = Data(hex.utf8)
        }
        var derived = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        let status: Int32 = pbkdfInput.withUnsafeBytes { pwPtr in
            salt.withUnsafeBytes { saltPtr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwPtr.baseAddress?.assumingMemoryBound(to: Int8.self),
                    pwPtr.count,
                    saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    saltPtr.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    &derived,
                    derived.count
                )
            }
        }
        guard status == kCCSuccess else {
            throw Failure.keyDerivationFailed
        }
        return Data(derived)
    }

    /// Processes the server's `"o": "init"` challenge and computes `M1`, `M2`, and `K`.
    static func processChallenge(
        handshake: ClientHandshake,
        username: String,
        password: String,
        protocolVariant: String,
        salt: Data,
        iterations: Int,
        serverPublicB: Data
    ) throws -> ChallengeResponse {
        guard !serverPublicB.isEmpty, serverPublicB.count <= primeByteCount else {
            throw Failure.invalidPublicKey
        }
        let capB = BigUInt(bigEndian: serverPublicB)
        let bModN = BigUInt.mod(capB, primeN)
        guard !bModN.isZero else {
            throw Failure.invalidPublicKey
        }

        let passwordKey = try derivePasswordKey(
            password: password,
            protocolVariant: protocolVariant,
            salt: salt,
            iterations: iterations
        )

        // k = SHA256(N || PAD(g))
        var paddedG = Data(repeating: 0, count: primeByteCount - 1)
        paddedG.append(0x02)
        let kHash = Data(SHA256.hash(data: primeBytes + paddedG))
        let k = BigUInt(bigEndian: kHash)

        // u = SHA256(PAD(A) || PAD(B))
        let paddedA = padLeft(handshake.publicEphemeralA, to: primeByteCount)
        let paddedB = padLeft(serverPublicB, to: primeByteCount)
        let uHash = Data(SHA256.hash(data: paddedA + paddedB))
        let u = BigUInt(bigEndian: uHash)
        guard !u.isZero else {
            throw Failure.invalidServerChallenge
        }

        // Apple GrandSlam uses `noUsernameInX`: x = SHA256(salt || SHA256(":" || passwordKey))
        var innerX = Data([0x3A]) // ":"
        innerX.append(passwordKey)
        let innerXHash = Data(SHA256.hash(data: innerX))
        let xHash = Data(SHA256.hash(data: salt + innerXHash))
        let x = BigUInt(bigEndian: xHash)

        // v = g^x mod N
        let v = BigUInt.modPow(base: generatorG, exponent: x, modulus: primeN)
        // kv = (k * v) mod N
        let kv = BigUInt.modMul(k, v, modulus: primeN)
        // base = (B - kv) mod N
        let diff = BigUInt.modSub(bModN, kv, modulus: primeN)
        // exp = a + u * x
        let a = BigUInt(bigEndian: handshake.ephemeralSecretA)
        let ux = BigUInt.mul(u, x)
        let exp = BigUInt.add(a, ux)
        // S = base^exp mod N
        let sharedS = BigUInt.modPow(base: diff, exponent: exp, modulus: primeN)
        let sessionKeyK = Data(SHA256.hash(data: sharedS.toBigEndian(paddedTo: primeByteCount)))

        // M1 = SHA256((SHA256(N) ^ SHA256(g_min)) || SHA256(username) || salt || A_min || B_min || K)
        let hashN = Array(SHA256.hash(data: primeBytes))
        let hashG = Array(SHA256.hash(data: Data([0x02])))
        let xorNG = Data(zip(hashN, hashG).map { $0 ^ $1 })
        let hashUser = Data(SHA256.hash(data: Data(username.utf8)))
        let trimA = trimLeadingZeros(paddedA)
        let trimB = trimLeadingZeros(paddedB)

        var m1Input = Data()
        m1Input.append(xorNG)
        m1Input.append(hashUser)
        m1Input.append(salt)
        m1Input.append(trimA)
        m1Input.append(trimB)
        m1Input.append(sessionKeyK)
        let clientM1 = Data(SHA256.hash(data: m1Input))

        // M2 = SHA256(A_pad || M1 || K) (padded A per RFC 5054 / ccsrp)
        var m2Input = Data()
        m2Input.append(paddedA)
        m2Input.append(clientM1)
        m2Input.append(sessionKeyK)
        let expectedM2 = Data(SHA256.hash(data: m2Input))

        return ChallengeResponse(
            clientProofM1: clientM1,
            expectedServerProofM2: expectedM2,
            sessionKeyK: sessionKeyK
        )
    }

    /// Derives a named GrandSlam subkey from SRP session key `K` via `HMAC-SHA256(K, label)`.
    static func deriveSessionSubkey(sessionKeyK: Data, label: String) -> Data {
        let key = SymmetricKey(data: sessionKeyK)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(label.utf8), using: key)
        return Data(mac)
    }

    /// Decrypts the `"spd"` AES-256-CBC PKCS#7 session dictionary returned in `"o": "complete"`.
    static func decryptSessionPayloadCBC(spd: Data, sessionKeyK: Data) throws -> Data {
        guard !spd.isEmpty else { throw Failure.payloadDecryptionFailed }
        let keyData = deriveSessionSubkey(sessionKeyK: sessionKeyK, label: "extra data key:")
        let ivData = deriveSessionSubkey(sessionKeyK: sessionKeyK, label: "extra data iv:").prefix(kCCBlockSizeAES128)

        var outBuffer = [UInt8](repeating: 0, count: spd.count + kCCBlockSizeAES128)
        var outMoved = 0
        let status: CCCryptorStatus = spd.withUnsafeBytes { spdPtr in
            keyData.withUnsafeBytes { keyPtr in
                Data(ivData).withUnsafeBytes { ivPtr in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyPtr.baseAddress,
                        kCCKeySizeAES256,
                        ivPtr.baseAddress,
                        spdPtr.baseAddress,
                        spdPtr.count,
                        &outBuffer,
                        outBuffer.count,
                        &outMoved
                    )
                }
            }
        }
        guard status == kCCSuccess, outMoved >= 0, outMoved <= outBuffer.count else {
            throw Failure.payloadDecryptionFailed
        }
        return Data(outBuffer.prefix(outMoved))
    }

    /// Computes the `"apptokens"` request checksum: `HMAC-SHA256(sk, "apptokens" || adsid || apps...)`.
    static func computeAppTokensChecksum(sk: Data, adsid: String, apps: [String]) -> Data {
        var message = Data("apptokens".utf8)
        message.append(Data(adsid.utf8))
        for app in apps {
            message.append(Data(app.utf8))
        }
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: sk))
        return Data(mac)
    }

    /// Decrypts the `"et"` `"XYZ"` AES-256-GCM envelope returned by `"o": "apptokens"`.
    /// Envelope layout: `3-byte header ("XYZ")` + `16-byte nonce` + `ciphertext` + `16-byte GCM tag`.
    static func decryptAppTokensGCM(encryptedToken: Data, sk: Data) throws -> Data {
        guard encryptedToken.count >= 35, sk.count == 32 else {
            throw Failure.payloadDecryptionFailed
        }
        let header = encryptedToken.prefix(3)
        guard header == Data("XYZ".utf8) else {
            throw Failure.payloadDecryptionFailed
        }
        let iv = encryptedToken.subdata(in: 3..<19)
        let tagStart = encryptedToken.count - 16
        let ciphertext = encryptedToken.subdata(in: 19..<tagStart)
        let tag = encryptedToken.subdata(in: tagStart..<encryptedToken.count)

        do {
            let nonce = try AES.GCM.Nonce(data: iv)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(box, using: SymmetricKey(data: sk), authenticating: header)
        } catch {
            throw Failure.payloadDecryptionFailed
        }
    }

    /// Computes a server SRP-6a public challenge `B = (k * v + g^b) mod N` for round-trip verification.
    static func makeServerPublicEphemeral(
        password: String,
        protocolVariant: String,
        salt: Data,
        iterations: Int,
        serverSecretB: Data
    ) throws -> Data {
        let v = try computeVerifierV(
            password: password,
            protocolVariant: protocolVariant,
            salt: salt,
            iterations: iterations
        )
        var paddedG = Data(repeating: 0, count: primeByteCount - 1)
        paddedG.append(0x02)
        let k = BigUInt(bigEndian: Data(SHA256.hash(data: primeBytes + paddedG)))
        let kv = BigUInt.modMul(k, v, modulus: primeN)
        let gb = BigUInt.modPow(
            base: generatorG,
            exponent: BigUInt(bigEndian: serverSecretB),
            modulus: primeN
        )
        let capB = BigUInt.mod(BigUInt.add(kv, gb), primeN)
        return capB.toBigEndian(paddedTo: primeByteCount)
    }

    /// Computes the server SRP-6a session key `K = SHA256(PAD((A * v^u)^b mod N))` for round-trip verification.
    static func deriveServerSessionKey(
        clientPublicA: Data,
        serverSecretB: Data,
        serverPublicB: Data,
        password: String,
        protocolVariant: String,
        salt: Data,
        iterations: Int
    ) throws -> Data {
        let v = try computeVerifierV(
            password: password,
            protocolVariant: protocolVariant,
            salt: salt,
            iterations: iterations
        )
        let paddedA = padLeft(clientPublicA, to: primeByteCount)
        let paddedB = padLeft(serverPublicB, to: primeByteCount)
        let u = BigUInt(bigEndian: Data(SHA256.hash(data: paddedA + paddedB)))
        let vu = BigUInt.modPow(base: v, exponent: u, modulus: primeN)
        let avu = BigUInt.modMul(BigUInt(bigEndian: paddedA), vu, modulus: primeN)
        let sharedS = BigUInt.modPow(
            base: avu,
            exponent: BigUInt(bigEndian: serverSecretB),
            modulus: primeN
        )
        return Data(SHA256.hash(data: sharedS.toBigEndian(paddedTo: primeByteCount)))
    }

    private static func computeVerifierV(
        password: String,
        protocolVariant: String,
        salt: Data,
        iterations: Int
    ) throws -> BigUInt {
        let passwordKey = try derivePasswordKey(
            password: password,
            protocolVariant: protocolVariant,
            salt: salt,
            iterations: iterations
        )
        var innerX = Data([0x3A])
        innerX.append(passwordKey)
        let xHash = Data(SHA256.hash(data: salt + Data(SHA256.hash(data: innerX))))
        return BigUInt.modPow(base: generatorG, exponent: BigUInt(bigEndian: xHash), modulus: primeN)
    }

    // MARK: - Byte Helpers

    private static func padLeft(_ data: Data, to length: Int) -> Data {
        if data.count >= length {
            return Data(data.suffix(length))
        }
        return Data(repeating: 0, count: length - data.count) + data
    }

    private static func trimLeadingZeros(_ data: Data) -> Data {
        guard let firstNonZero = data.firstIndex(where: { $0 != 0 }) else {
            return Data([0])
        }
        return Data(data[firstNonZero...])
    }

    private static func decodeHex(_ hex: String) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            if let byte = UInt8(hex[idx..<next], radix: 16) {
                bytes.append(byte)
            }
            idx = next
        }
        return Data(bytes)
    }
}

// MARK: - Self-Contained Arbitrary-Precision Unsigned Integer (Little-Endian Limbs)

private struct BigUInt: Equatable, Sendable {
    /// Little-endian 64-bit limbs, trimmed of trailing zero limbs.
    var limbs: [UInt64]

    init(limbs: [UInt64]) {
        var copy = limbs
        while let last = copy.last, last == 0 {
            copy.removeLast()
        }
        self.limbs = copy
    }

    init(word: UInt64) {
        self.init(limbs: word == 0 ? [] : [word])
    }

    init(bigEndian data: Data) {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else {
            self.init(limbs: [])
            return
        }
        var built: [UInt64] = []
        built.reserveCapacity((bytes.count + 7) / 8)
        var cursor = bytes.count
        while cursor > 0 {
            let start = max(0, cursor - 8)
            var word: UInt64 = 0
            for idx in start..<cursor {
                word = (word << 8) | UInt64(bytes[idx])
            }
            built.append(word)
            cursor = start
        }
        self.init(limbs: built)
    }

    var isZero: Bool { limbs.isEmpty }

    var bitWidth: Int {
        guard let top = limbs.last else { return 0 }
        return (limbs.count - 1) * 64 + (64 - top.leadingZeroBitCount)
    }

    func testBit(_ index: Int) -> Bool {
        let limbIndex = index >> 6
        guard limbIndex < limbs.count else { return false }
        return ((limbs[limbIndex] >> (index & 63)) & 1) == 1
    }

    func toBigEndian(paddedTo byteCount: Int) -> Data {
        var raw = [UInt8]()
        raw.reserveCapacity(limbs.count * 8)
        for word in limbs.reversed() {
            for shift in stride(from: 56, through: 0, by: -8) {
                raw.append(UInt8((word >> shift) & 0xFF))
            }
        }
        while raw.first == 0 && raw.count > 1 {
            raw.removeFirst()
        }
        if raw.isEmpty { raw = [0] }
        if raw.count >= byteCount {
            return Data(raw.suffix(byteCount))
        }
        return Data(repeating: 0, count: byteCount - raw.count) + Data(raw)
    }

    static func compare(_ lhs: BigUInt, _ rhs: BigUInt) -> ComparisonResult {
        if lhs.limbs.count != rhs.limbs.count {
            return lhs.limbs.count < rhs.limbs.count ? .orderedAscending : .orderedDescending
        }
        for idx in stride(from: lhs.limbs.count - 1, through: 0, by: -1) {
            if lhs.limbs[idx] != rhs.limbs[idx] {
                return lhs.limbs[idx] < rhs.limbs[idx] ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }

    static func add(_ lhs: BigUInt, _ rhs: BigUInt) -> BigUInt {
        let count = max(lhs.limbs.count, rhs.limbs.count)
        var out = [UInt64](repeating: 0, count: count + 1)
        var carry: UInt64 = 0
        for idx in 0..<count {
            let a = idx < lhs.limbs.count ? lhs.limbs[idx] : 0
            let b = idx < rhs.limbs.count ? rhs.limbs[idx] : 0
            let (sum1, ov1) = a.addingReportingOverflow(b)
            let (sum2, ov2) = sum1.addingReportingOverflow(carry)
            out[idx] = sum2
            carry = (ov1 ? 1 : 0) + (ov2 ? 1 : 0)
        }
        out[count] = carry
        return BigUInt(limbs: out)
    }

    /// Precondition: `lhs >= rhs`.
    static func sub(_ lhs: BigUInt, _ rhs: BigUInt) -> BigUInt {
        var out = [UInt64](repeating: 0, count: lhs.limbs.count)
        var borrow: UInt64 = 0
        for idx in 0..<lhs.limbs.count {
            let a = lhs.limbs[idx]
            let b = idx < rhs.limbs.count ? rhs.limbs[idx] : 0
            let (diff1, b1) = a.subtractingReportingOverflow(b)
            let (diff2, b2) = diff1.subtractingReportingOverflow(borrow)
            out[idx] = diff2
            borrow = (b1 ? 1 : 0) + (b2 ? 1 : 0)
        }
        return BigUInt(limbs: out)
    }

    static func mul(_ lhs: BigUInt, _ rhs: BigUInt) -> BigUInt {
        guard !lhs.isZero, !rhs.isZero else { return BigUInt(limbs: []) }
        var out = [UInt64](repeating: 0, count: lhs.limbs.count + rhs.limbs.count)
        for i in 0..<lhs.limbs.count {
            var carry: UInt64 = 0
            let a = lhs.limbs[i]
            for j in 0..<rhs.limbs.count {
                let (high, low) = a.multipliedFullWidth(by: rhs.limbs[j])
                let (sum1, ov1) = out[i + j].addingReportingOverflow(low)
                let (sum2, ov2) = sum1.addingReportingOverflow(carry)
                out[i + j] = sum2
                carry = high &+ (ov1 ? 1 : 0) &+ (ov2 ? 1 : 0)
            }
            out[i + rhs.limbs.count] &+= carry
        }
        return BigUInt(limbs: out)
    }

    /// Bitwise restoring modulo reduction `value mod modulus`.
    static func mod(_ value: BigUInt, _ modulus: BigUInt) -> BigUInt {
        guard !modulus.isZero else { return BigUInt(limbs: []) }
        if compare(value, modulus) == .orderedAscending {
            return value
        }
        var remainder = BigUInt(limbs: [])
        for bit in stride(from: value.bitWidth - 1, through: 0, by: -1) {
            remainder = shiftLeftOne(remainder, lowBit: value.testBit(bit) ? 1 : 0)
            if compare(remainder, modulus) != .orderedAscending {
                remainder = sub(remainder, modulus)
            }
        }
        return remainder
    }

    private static func shiftLeftOne(_ value: BigUInt, lowBit: UInt64) -> BigUInt {
        if value.isZero {
            return lowBit == 0 ? value : BigUInt(word: 1)
        }
        var out = [UInt64](repeating: 0, count: value.limbs.count + 1)
        var carry = lowBit
        for idx in 0..<value.limbs.count {
            let word = value.limbs[idx]
            out[idx] = (word << 1) | carry
            carry = word >> 63
        }
        out[value.limbs.count] = carry
        return BigUInt(limbs: out)
    }

    static func modSub(_ lhs: BigUInt, _ rhs: BigUInt, modulus: BigUInt) -> BigUInt {
        let a = mod(lhs, modulus)
        let b = mod(rhs, modulus)
        if compare(a, b) != .orderedAscending {
            return sub(a, b)
        }
        return sub(add(a, modulus), b)
    }

    static func modMul(_ lhs: BigUInt, _ rhs: BigUInt, modulus: BigUInt) -> BigUInt {
        mod(mul(lhs, rhs), modulus)
    }

    static func modPow(base: BigUInt, exponent: BigUInt, modulus: BigUInt) -> BigUInt {
        if exponent.isZero { return BigUInt(word: 1) }
        var result = BigUInt(word: 1)
        var currentBase = mod(base, modulus)
        let bits = exponent.bitWidth
        for bit in 0..<bits {
            if exponent.testBit(bit) {
                result = modMul(result, currentBase, modulus: modulus)
            }
            if bit + 1 < bits {
                currentBase = modMul(currentBase, currentBase, modulus: modulus)
            }
        }
        return result
    }
}
