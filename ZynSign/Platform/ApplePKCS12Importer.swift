#if os(iOS)
import Foundation
import Security

/// Platform implementation of `SigningIdentityImporter` that uses Security's
/// PKCS#12 import and the secure identity store's registry.
///
/// The importer is deliberately narrow: it handles only `.p12` / `.pfx` files
/// presented through the system document picker, validates the container's
/// size, extracts the first identity, resolves the private-key persistent
/// reference through the Keychain, and registers the pair with the store.
/// No private-key bytes are read through `kSecReturnData` and no key material
/// is logged or persisted outside the Keychain.
///
/// The store remains the owner of registration records. This type only bridges
/// the Security import result to the store's `register(certificateDER:keyReference:)`
/// contract. Duplicate certificates are rejected by the store, and the caller
/// receives a typed duplicate error.
struct ApplePKCS12Importer: SigningIdentityImporter {

    private let store: SecureIdentityStore

    /// Maximum PKCS#12 container size accepted. Application policy, not a
    /// platform limit. Far above ordinary single-identity containers (a few
    /// kilobytes) but bounded so inspection cannot be asked to retain an
    /// unbounded buffer.
    private static let maximumByteCount = 10 * 1024 * 1024

    /// The Security statuses that mean a passphrase did not open the container.
    ///
    /// `errSecPkcs12VerifyFailure` is `-25264`; its name is not exported to
    /// Swift by every SDK. `-25260` is `errSecPassphraseRequired`. The nearby
    /// values `-25294` and `-25295` are keychain errors, not PKCS#12
    /// passphrase errors, so they must remain generic import failures.
    private static let statusPassphraseRequired: OSStatus = -25260
    private static let statusPkcs12VerifyFailure: OSStatus = -25264

    init(store: SecureIdentityStore) {
        self.store = store
    }

    @discardableResult
    func importPKCS12(data: Data, password: String) throws -> SigningIdentityIdentifier {
        try Self.validate(data)

        var items: CFArray?
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: password
        ]
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess else {
            throw Self.importFailure(for: status)
        }

        guard let array = items as? [[String: Any]], let first = array.first else {
            throw ZynSignError.identity(.certificateUnavailable)
        }

        // The imported identity — the platform may vend it as SecIdentity or as
        // CFTypeRef. Prove the dynamic type the way the key resolver does, then
        // take it in the forced form the compiler accepts: a conditional
        // downcast to a Core Foundation type is rejected as always succeeding.
        guard let rawIdentity = first[kSecImportItemIdentity as String],
              CFGetTypeID(rawIdentity as CFTypeRef) == SecIdentityGetTypeID() else {
            throw ZynSignError.identity(.certificateUnavailable)
        }
        // swiftlint:disable:next force_cast
        let secIdentity = rawIdentity as! SecIdentity

        // Extract the leaf certificate and its DER.
        var certRef: SecCertificate?
        guard SecIdentityCopyCertificate(secIdentity, &certRef) == errSecSuccess, let cert = certRef else {
            throw ZynSignError.identity(.certificateUnavailable)
        }
        let certData = SecCertificateCopyData(cert) as Data
        // Defensive bound — the store enforces this again, but we check early
        // so we never hand an oversized buffer to the parser.
        guard certData.count <= CertificateInput.maximumByteCount else {
            throw ZynSignError.identity(.malformedStoredIdentity)
        }

        // Validate the certificate is parseable before touching the Keychain
        // for a persistent reference. This fails closed on malformed DER.
        do {
            _ = try AppleCertificateParser().parseCertificate(derData: certData)
        } catch {
            throw ZynSignError.identity(.malformedStoredIdentity)
        }

        // Resolve the private key and its persistent reference. The key is
        // already in the Keychain after SecPKCS12Import; we query it back
        // with the non-interactive context so no authentication prompt is
        // presented during import.
        var keyRef: SecKey?
        guard SecIdentityCopyPrivateKey(secIdentity, &keyRef) == errSecSuccess, let key = keyRef else {
            throw ZynSignError.identity(.privateKeyUnavailable)
        }

        let persistentRef = try persistentReference(for: key)

        // The platform stored this key with the Keychain's default protection.
        // Ask for the device-only class before registering — and do not assume
        // the answer: the resolver reads the key's actual attributes back and
        // refuses anything readable while the device is locked, so a platform
        // that cannot re-protect an existing private key still gets a working,
        // verified identity instead of a dead end.
        Self.advanceProtection(ofKeyMatching: persistentRef)

        // The Security import leaves the identity, certificate, and key in
        // the Keychain. The registry only needs the leaf DER and the key's
        // persistent reference; the store will validate association and
        // protection before accepting the registration. If registration fails
        // (duplicate, malformed, or platform restriction) the imported
        // Keychain items remain. They are not automatically deleted — the
        // caller that provisioned the key owns its lifecycle, and a duplicate
        // import is reported as a duplicate identity, not as a silent
        // Keychain cleanup. The next import of the same material will be
        // recognised as a duplicate by fingerprint rather than by Keychain
        // presence.
        do {
            return try store.register(certificateDER: certData, keyReference: persistentRef)
        } catch {
            throw ZynSignError.sanitizedIdentityFailure(error)
        }
    }

    /// The three ways bytes can fail to be a PKCS#12 container at all.
    ///
    /// Each says so in its own words. One vague failure shared by an empty
    /// file, an oversized one, and a text export is what left a user checking
    /// the password of a file that never was a `.p12`.
    private static func validate(_ data: Data) throws {
        guard !data.isEmpty else {
            throw ZynSignError.emptyCertificateInput(
                diagnosticDetail: "The PKCS#12 container handed to the importer held no bytes."
            )
        }
        guard data.count <= maximumByteCount else {
            throw ZynSignError.certificateInputTooLarge(
                diagnosticDetail: "The PKCS#12 container is \(data.count) bytes, above the accepted ceiling."
            )
        }
        // A PKCS#12 file is a DER `SEQUENCE`, so it begins with 0x30. Nothing
        // else can be one, and the platform's importer says no in a way that
        // does not distinguish "not a container" from "could not open".
        guard data.first == 0x30 else {
            throw ZynSignError.identity(.unsupportedContainerFormat)
        }
    }

    /// What to tell the user about a rejected `SecPKCS12Import`.
    ///
    /// The status is read as a *cause* only where the platform's own code is
    /// specific about one. Everything else becomes the container-reading
    /// failure, whose message names both remedies that can still work — check
    /// the password, re-export the identity — because a status the importer
    /// does not explain is as much use to a person as to this type. The number
    /// itself goes into the diagnostic, where a report can quote it.
    static func importFailure(for status: OSStatus) -> ZynSignError {
        if status == errSecAuthFailed
            || status == statusPassphraseRequired
            || status == statusPkcs12VerifyFailure {
            return .identity(.invalidPassphrase)
        }
        if status == errSecDecode || status == errSecParam {
            return .identity(.unsupportedContainerFormat)
        }
        return .identity(
            .containerImportFailed,
            diagnosticDetail: "SecPKCS12Import reported status \(status)."
        )
    }

    /// Asks the Keychain to move an imported private key to the device-only
    /// protection class.
    ///
    /// `SecPKCS12Import` accepts no attribute dictionary, so an imported key
    /// carries the Keychain's default class. This call is the only way to ask
    /// for something stronger, and it is deliberately best-effort: the status
    /// is discarded because the outcome is not this call's to claim. iOS may
    /// refuse the change (`errSecParam`, typically, when the update needs the
    /// item's data — which a private key never returns), may refuse it while
    /// the device is in a state the new class cannot be applied in, or may not
    /// report the requested attribute at all. Whatever happened, what is true
    /// afterwards is what the resolver reads from the key itself.
    ///
    /// The advancement never goes the other way: only the device-only class is
    /// ever written, so this cannot weaken a key that already has it.
    private static func advanceProtection(ofKeyMatching reference: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecValuePersistentRef as String: reference,
            kSecUseAuthenticationContext as String: IdentityKeychainAccess.noninteractiveContext()
        ]
        let attributes: [String: Any] = [
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        _ = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    private func persistentReference(for key: SecKey) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: key,
            kSecReturnPersistentRef as String: true,
            kSecUseAuthenticationContext as String: IdentityKeychainAccess.noninteractiveContext()
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, !data.isEmpty, data.count <= 4096 else {
            throw ZynSignError.identity(.privateKeyUnavailable)
        }
        return data
    }
}

#else

// swiftlint:disable:next duplicate_imports -- only Foundation import in this `#else` branch; the iOS branch's import above is a separate conditional.
import Foundation

/// Unavailable on non-iOS targets. The composition root never constructs this
/// type off-device; any call is a programmer error.
struct ApplePKCS12Importer: SigningIdentityImporter {
    let store: Any
    init(store: Any) { self.store = store }
    func importPKCS12(data: Data, password: String) throws -> SigningIdentityIdentifier {
        throw ZynSignError.identity(.platformRestriction)
    }
}

#endif
