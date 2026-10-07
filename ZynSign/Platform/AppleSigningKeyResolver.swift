#if os(iOS)
import Foundation
import Security

/// Resolves only existing, protected private keys in the app's Keychain scope.
/// No private-key import/export or generation occurs here.
///
/// The protection the resolver requires is the one ZynSign actually depends
/// on — a private key that cannot be read while the device is locked — rather
/// than one exact Keychain class. The distinction is not academic: an identity
/// imported from a `.p12` arrives through `SecPKCS12Import`, which takes no
/// attribute dictionary and therefore stores its items with the Keychain's
/// default class, and iOS offers no supported way to re-protect a private key
/// after it exists (`SecItemUpdate` on `kSecAttrAccessible` needs the item's
/// data, which a private key never returns). Requiring the device-only class
/// *exactly* therefore refused every identity the platform could legally
/// produce for an import, which is what made `.p12` import fail with
/// "The required identity protection is not available" no matter what the
/// user did. `ApplePKCS12Importer` still asks for the device-only class before
/// registering, so a platform that honours the upgrade gets it; the resolver
/// verifies what it actually got.
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
        // The Core Foundation type check above proves the value is a key.
        // The compiler rejects a conditional downcast to a Core Foundation
        // type as always succeeding, so the forced form is the one it accepts;
        // this is the pattern Security.framework's own samples use.
        // swiftlint:disable:next force_cast
        let key = value as! SecKey

        // Exactly the protection `SigningKeyProtectionRule` describes, read
        // from the key itself rather than assumed from how it was made. What
        // the Keychain reported is also what the refusal records, in policy
        // vocabulary: without it a device that refuses an imported key says
        // only "unsupported", and which attribute refused it stays a guess.
        //
        // Which attribute the class is read from is not cosmetic. A query's
        // dictionary carries what the *item* was stored with, and it is not
        // required to say which class of key that is; `SecKeyCopyAttributes`
        // describes the handle the platform actually handed over, which is the
        // fact the rule is about. Asking only the item is how an imported key
        // can be refused for an attribute it never carried, and no re-export
        // fixes that. The item's own answer stays as the fallback, so a key
        // with no handle-level report is judged exactly as it was before.
        let keyAttributes = (SecKeyCopyAttributes(key) as? [String: Any]) ?? [:]
        let reportedClass = keyAttributes[kSecAttrKeyClass as String] as? String
            ?? attributes[kSecAttrKeyClass as String] as? String
        let reportedAccessibility = attributes[kSecAttrAccessible as String] as? String
        let reportedSynchronizable = attributes[kSecAttrSynchronizable as String] as? Bool
        let reportedExtractable = attributes[kSecAttrIsExtractable as String] as? Bool
            ?? keyAttributes[kSecAttrIsExtractable as String] as? Bool
        guard SigningKeyProtectionRule.permits(
            keyClass: reportedClass,
            accessibility: reportedAccessibility,
            synchronizable: reportedSynchronizable,
            isExtractable: reportedExtractable
        ) else {
            throw ZynSignError.identity(
                .platformRestriction,
                diagnosticDetail: SigningKeyProtectionRule.describe(
                    keyClass: reportedClass,
                    accessibility: reportedAccessibility,
                    synchronizable: reportedSynchronizable,
                    isExtractable: reportedExtractable
                )
            )
        }
        return key
    }
}

/// The protection a stored signing key must carry for ZynSign to sign with it.
///
/// The rule is a pure decision over the attributes the Keychain and the key
/// handle report, split out of the resolver so the test suite can exercise it
/// directly: the resolver's other work needs a real Keychain, but this is the
/// part that decides whether an imported key is acceptable — and the part that
/// made `.p12` import impossible when it demanded one exact class.
///
/// What is required is the property signed identities depend on: a private
/// key, never one that can sync to iCloud Keychain, unreadable while the
/// device is locked, and not reported as exportable.
///
/// - `WhenUnlockedThisDeviceOnly` is what ZynSign asks for, and what the
///   importer requests before registering an imported key.
/// - `WhenUnlocked` is the Keychain's default, which `SecPKCS12Import` stores
///   its items under because it takes no attribute dictionary and iOS offers
///   no supported way to re-protect a private key after creation. Refusing it
///   refused every identity the platform could legally produce for an import.
/// - `WhenPasscodeSetThisDeviceOnly` is stronger than either.
///
/// Everything else — `AfterFirstUnlock`, the `Always` family, a class this
/// build does not know, or no reported class at all — fails closed. So does a
/// key the platform reports as exportable. An *unreported* extractability
/// attribute does not: DTS is explicit that an imported private key's raw
/// bytes cannot be read back, and the attribute is not always surfaced, so
/// absence is treated as the platform's own import rather than as evidence
/// the key can be exported. `docs/architecture/on-device-signing-feasibility.md`
/// records that distinction as an attribute report, not as an experimentally
/// proven non-exportability guarantee.
enum SigningKeyProtectionRule {

    /// The accessibility classes a signing key may carry.
    static let permittedAccessibilityClasses: Set<String> = [
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
        kSecAttrAccessibleWhenUnlocked as String,
        kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String
    ]

    /// Whether a key the Keychain reports with these attributes may sign.
    ///
    /// - Parameters:
    ///   - keyClass: `kSecAttrKeyClass`, or `nil` when unreported.
    ///   - accessibility: `kSecAttrAccessible`, or `nil` when unreported.
    ///   - synchronizable: `kSecAttrSynchronizable`, or `nil` when unreported.
    ///   - isExtractable: `kSecAttrIsExtractable`, or `nil` when unreported.
    static func permits(
        keyClass: String?,
        accessibility: String?,
        synchronizable: Bool?,
        isExtractable: Bool?
    ) -> Bool {
        guard keyClass == kSecAttrKeyClassPrivate as String,
              let accessibility,
              permittedAccessibilityClasses.contains(accessibility),
              synchronizable != true else {
            return false
        }
        return isExtractable != true
    }

    /// The policy name of a protection class, for the technical log.
    ///
    /// The Keychain reports protection domains as short codes — "ak", "aku" —
    /// which say nothing to a person reading the log, and a code is exactly
    /// the sort of thing that reads like key material when it is not. The names
    /// are the policy's own words, and a class the rule does not know is
    /// reported as an unrecognised class rather than echoed.
    static func name(ofAccessibility value: String?) -> String {
        guard let value else { return "unreported" }
        if value == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String { return "when-unlocked-this-device-only" }
        if value == kSecAttrAccessibleWhenUnlocked as String { return "when-unlocked" }
        if value == kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String { return "when-passcode-set-this-device-only" }
        return "unrecognised-class"
    }

    /// What the Keychain reported about a key the rule refused, in the policy's
    /// own vocabulary, for the technical log.
    ///
    /// Four facts decide the answer, so all four are recorded: which class of
    /// key it is, which protection class it carries, whether the platform
    /// called it synchronizable, and whether it called it exportable. Nothing
    /// here identifies the key or its owner.
    static func describe(
        keyClass: String?,
        accessibility: String?,
        synchronizable: Bool?,
        isExtractable: Bool?
    ) -> String {
        let classOfKey = keyClass == (kSecAttrKeyClassPrivate as String)
            ? "private"
            : (keyClass == nil ? "unreported" : "not-private")
        return "key=\(classOfKey), accessibility=\(name(ofAccessibility: accessibility)), "
            + "synchronizable=\(synchronizable.map { String($0) } ?? "unreported"), "
            + "extractable=\(isExtractable.map { String($0) } ?? "unreported")"
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
