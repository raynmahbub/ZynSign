#if os(iOS)
import Foundation
import Security

/// Creates a development signing identity on this device.
///
/// A development identity is a permanent, non-extractable RSA-2048 private
/// key generated in the application's Keychain together with a self-signed
/// certificate shaped for code signing (digital-signature key usage, the
/// code-signing extended key usage, not a CA). The key never leaves the
/// Keychain, the certificate is issued by the key itself, and the pair is
/// registered through `SecureIdentityStore.register`, which re-resolves the
/// capability before the record is stored — a registration that cannot be
/// resolved is refused rather than half-recorded.
///
/// A development identity is **not an Apple-issued certificate**: no Apple
/// chain, no team, and it will not be present inside an Apple-issued
/// provisioning profile. It exists so the signing pipeline can be
/// exercised end to end on a device and so the identity boundary itself
/// can be validated. Nothing here establishes trust, compatibility with a
/// real profile, or installability.
///
/// The factory belongs to the platform layer on purpose: key generation and
/// registration are not on the application's `IdentityStore` port, and this
/// type is reached only from the composition root.
final class DevelopmentSigningIdentityFactory {

    private let store: SecureIdentityStore

    init(store: SecureIdentityStore) {
        self.store = store
    }

    /// Generates the key, issues its certificate, and registers the pair.
    ///
    /// On any failure after key generation the key is deleted, so a refused
    /// registration never leaves an orphan key in the Keychain.
    func create(commonName: String = "ZynSign Development Signing") throws -> SigningIdentityIdentifier {
        let tag = Data(("io.github.davinelion.ZynSign.development-identity." + UUID().uuidString).utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                kSecAttrSynchronizable as String: false,
                kSecAttrIsExtractable as String: false,
            ],
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, nil) else {
            throw ZynSignError.identity(.platformRestriction)
        }
        do {
            var lookup = query
            lookup[kSecReturnPersistentRef as String] = true
            var result: CFTypeRef?
            try IdentityKeychainAccess.check(SecItemCopyMatching(lookup as CFDictionary, &result))
            guard let reference = result as? Data else {
                throw ZynSignError.identity(.unexpectedSecurityFailure)
            }
            guard let publicKey = SecKeyCopyPublicKey(key),
                  let publicBytes = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
                throw ZynSignError.identity(.capabilityUnavailable)
            }
            let der = try Self.certificateDER(signingKey: key, publicKey: publicBytes)
            return try store.register(certificateDER: der, keyReference: reference)
        } catch {
            // No orphan keys: the registration either stands or the key goes.
            SecItemDelete(query as CFDictionary)
            throw error
        }
    }

    // MARK: - Certificate issuance

    /// Issues the self-signed development certificate.
    ///
    /// This is test-grade issuance moved into the platform so the device
    /// flow can run: it produces bytes `AppleCertificateParser` accepts and
    /// `AppleSigningKeyResolver` can pair with the generated key. It
    /// establishes nothing about trust.
    private static func certificateDER(signingKey: SecKey, publicKey: Data) throws -> Data {
        let rsaEncryption = Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01])
        let sha256WithRSA = Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B])
        let algorithm = der(0x30, sha256WithRSA + Data([0x05, 0x00]))
        let commonName = Data([0x06, 0x03, 0x55, 0x04, 0x03])
            + der(0x0C, Data("ZynSign Development Signing".utf8))
        let name = der(0x30, der(0x31, der(0x30, commonName)))
        let now = Date()
        let notBefore = der(0x17, Data(utcTime(now.addingTimeInterval(-86_400)).utf8))
        let notAfter = der(0x17, Data(utcTime(now.addingTimeInterval(365 * 86_400)).utf8))
        let validity = der(0x30, notBefore + notAfter)
        let subjectPublicKeyInfo = der(0x30,
            der(0x30, rsaEncryption + Data([0x05, 0x00])) + der(0x03, Data([0x00]) + publicKey))
        let critical = Data([0x01, 0x01, 0xFF])
        let basicConstraints = der(0x30,
            Data([0x06, 0x03, 0x55, 0x1D, 0x13]) + critical + der(0x04, der(0x30, Data())))
        let keyUsage = der(0x30,
            Data([0x06, 0x03, 0x55, 0x1D, 0x0F]) + critical + der(0x04, Data([0x03, 0x02, 0x07, 0x80])))
        let codeSigning = Data([0x06, 0x08, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x03])
        let extendedKeyUsage = der(0x30,
            Data([0x06, 0x03, 0x55, 0x1D, 0x25]) + critical + der(0x04, der(0x30, codeSigning)))
        let extensions = der(0xA3, der(0x30, basicConstraints + keyUsage + extendedKeyUsage))
        let version = der(0xA0, Data([0x02, 0x01, 0x02]))
        let serialNumber = Data([0x02, 0x01, 0x31])
        let body = version + serialNumber + algorithm + name + validity
        let tbs = der(0x30, body + name + subjectPublicKeyInfo + extensions)
        guard let signature = SecKeyCreateSignature(
            signingKey, .rsaSignatureMessagePKCS1v15SHA256, tbs as CFData, nil) as Data? else {
            throw ZynSignError.crypto(.signingFailure)
        }
        return der(0x30, tbs + algorithm + der(0x03, Data([0x00]) + signature))
    }

    private static func utcTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return formatter.string(from: date)
    }

    /// Minimal DER assembler for the development certificate.
    private static func der(_ tag: UInt8, _ content: Data) -> Data {
        precondition(content.count < 65536)
        let count = content.count
        let length: [UInt8]
        if count < 128 {
            length = [UInt8(count)]
        } else if count < 256 {
            length = [0x81, UInt8(count)]
        } else {
            length = [0x82, UInt8(count >> 8), UInt8(count & 255)]
        }
        return Data([tag]) + Data(length) + content
    }
}
#endif
