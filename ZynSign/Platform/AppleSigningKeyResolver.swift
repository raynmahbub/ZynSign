#if os(iOS)
import Foundation
import Security

/// Resolves only existing, protected private keys in the app's Keychain scope.
/// No private-key import/export, protection mutation, or generation occurs here.
struct AppleSigningKeyResolver: SigningIdentityKeyResolver {
    func resolve(_ record: StoredSigningIdentity) throws -> any SigningCapability {
        let id = try record.id
        let metadata: CertificateMetadata
        do { metadata = try AppleCertificateParser().parseCertificate(derData: record.certificateDER) }
        catch { throw ZynSignError.identity(.malformedStoredIdentity) }
        guard metadata.sha256Fingerprint.hexDigest == record.certificateFingerprint else {
            throw ZynSignError.identity(.malformedStoredIdentity)
        }
        guard let certificate = SecCertificateCreateWithData(nil, record.certificateDER as CFData) else {
            throw ZynSignError.identity(.certificateUnavailable)
        }
        guard let certificatePublicKey = SecCertificateCopyKey(certificate) else {
            throw ZynSignError.identity(.unsupportedKeyType)
        }
        let key = try loadKey(reference: record.keyReference)
        guard let signingPublicKey = SecKeyCopyPublicKey(key) else {
            throw ZynSignError.identity(.capabilityUnavailable)
        }
        try ApplePublicKeyAssociation.validate(certificatePublicKey: certificatePublicKey,
            signingPublicKey: signingPublicKey, expected: metadata.publicKeyInfo)
        let algorithms = Set(SigningAlgorithm.allCases.filter {
            $0.publicKeyAlgorithm == metadata.publicKeyInfo.algorithm
                && SecKeyIsAlgorithmSupported(key, .sign, $0.securityAlgorithm)
        })
        guard !algorithms.isEmpty else { throw ZynSignError.identity(.unsupportedSigningAlgorithm) }
        return AppleKeySigningCapability(identityID: id,
            publicKeyAlgorithm: metadata.publicKeyInfo.algorithm, key: key, supportedAlgorithms: algorithms)
    }

    private func loadKey(reference: Data) throws -> SecKey {
        // Synchronizable items are excluded by the default query behavior.
        // No kSecReturnData is ever requested for a private key.
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecValuePersistentRef as String: reference,
            kSecReturnRef as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: IdentityKeychainAccess.noninteractiveContext()
        ]
        var result: CFTypeRef?
        try IdentityKeychainAccess.check(SecItemCopyMatching(query as CFDictionary, &result),
                                         missing: .privateKeyUnavailable)
        guard let attributes = result as? [String: Any],
              let value = attributes[kSecValueRef as String],
              CFGetTypeID(value as CFTypeRef) == SecKeyGetTypeID() else {
            throw ZynSignError.identity(.unexpectedSecurityFailure)
        }
        guard attributes[kSecAttrKeyClass as String] as? String == kSecAttrKeyClassPrivate as String,
              attributes[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
              (attributes[kSecAttrSynchronizable as String] as? Bool ?? false) == false,
              attributes[kSecAttrIsExtractable as String] as? Bool == false else {
            throw ZynSignError.identity(.platformRestriction)
        }
        // The Core Foundation type check above proves the value is a key.
        // The compiler rejects a conditional downcast to a Core Foundation
        // type as always succeeding, so the forced form is the one it accepts;
        // this is the pattern Security.framework's own samples use.
        // swiftlint:disable:next force_cast
        let key = value as! SecKey
        return key
    }
}

/// Compares public encodings only. Class checks precede the only export call.
enum ApplePublicKeyAssociation {
    static func validate(certificatePublicKey: SecKey, signingPublicKey: SecKey,
                         expected: PublicKeyInfo) throws {
        guard expected.appearsAdequateForCodeSigning,
              expected.algorithm == .rsa || expected.algorithm == .ec else {
            throw ZynSignError.identity(.unsupportedKeyType)
        }
        let certificate = try representation(ofPublicKey: certificatePublicKey)
        let signing = try representation(ofPublicKey: signingPublicKey)
        guard certificate.algorithm == expected.algorithm,
              certificate.size == expected.keySizeInBits else {
            throw ZynSignError.identity(.unsupportedKeyType)
        }
        guard signing.algorithm == certificate.algorithm, signing.size == certificate.size,
              signing.bytes == certificate.bytes else {
            throw ZynSignError.identity(.certificateKeyMismatch)
        }
    }

    private static func representation(ofPublicKey publicKey: SecKey) throws
        -> (algorithm: PublicKeyAlgorithm, size: Int, bytes: Data) {
        guard let attributes = SecKeyCopyAttributes(publicKey) as? [String: Any],
              attributes[kSecAttrKeyClass as String] as? String == kSecAttrKeyClassPublic as String,
              let size = attributes[kSecAttrKeySizeInBits as String] as? Int else {
            throw ZynSignError.identity(.unsupportedKeyType)
        }
        let algorithm: PublicKeyAlgorithm
        let rsaKeyType = kSecAttrKeyTypeRSA as String
        let ecKeyType = kSecAttrKeyTypeECSECPrimeRandom as String
        switch attributes[kSecAttrKeyType as String] as? String {
        case rsaKeyType: algorithm = .rsa
        case ecKeyType: algorithm = .ec
        default: throw ZynSignError.identity(.unsupportedKeyType)
        }
        guard let bytes = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw ZynSignError.identity(.unsupportedKeyType)
        }
        return (algorithm, size, bytes)
    }
}

/// Internal, short-lived handle; callers receive ResolvedStoreCapability instead.
private final class AppleKeySigningCapability: SigningCapability, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let identityID: SigningIdentityIdentifier
    let publicKeyAlgorithm: PublicKeyAlgorithm
    let supportedAlgorithms: Set<SigningAlgorithm>
    private let key: SecKey

    init(identityID: SigningIdentityIdentifier, publicKeyAlgorithm: PublicKeyAlgorithm,
         key: SecKey, supportedAlgorithms: Set<SigningAlgorithm>) {
        self.identityID = identityID
        self.publicKeyAlgorithm = publicKeyAlgorithm
        self.key = key
        self.supportedAlgorithms = supportedAlgorithms
    }

    var isAvailable: Bool { true } // Resolved handle, not a successful operation.

    func sign(data: Data, algorithm: SigningAlgorithm) throws -> Data {
        try algorithm.validate(data: data, keyAlgorithm: publicKeyAlgorithm)
        guard supportedAlgorithms.contains(algorithm),
              SecKeyIsAlgorithmSupported(key, .sign, algorithm.securityAlgorithm) else {
            throw ZynSignError.identity(.unsupportedSigningAlgorithm)
        }
        var error: Unmanaged<CFError>?
        let signature = SecKeyCreateSignature(key, algorithm.securityAlgorithm, data as CFData, &error)
        let failure = error?.takeRetainedValue()
        guard let signature else { throw IdentityKeychainAccess.signingError(failure) }
        return signature as Data
    }

    var description: String { "SigningCapability(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The Security key operation each signing operation maps to, shared by the
/// signing capability and the signature-verification primitive.
extension SigningAlgorithm {
    var securityAlgorithm: SecKeyAlgorithm {
        switch self {
        case .rsaPKCS1SHA256Message: return .rsaSignatureMessagePKCS1v15SHA256
        case .rsaPKCS1SHA256Digest: return .rsaSignatureDigestPKCS1v15SHA256
        case .ecdsaX962SHA256Message: return .ecdsaSignatureMessageX962SHA256
        case .ecdsaX962SHA256Digest: return .ecdsaSignatureDigestX962SHA256
        }
    }
}
#endif
