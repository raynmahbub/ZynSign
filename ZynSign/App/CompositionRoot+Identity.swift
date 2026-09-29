import Foundation

/// Signing identities: the Keychain store, the PKCS#12 importer, and the inspector.
///
/// Part of `CompositionRoot`, which chooses every concrete
/// implementation and wires the layers together. Split out of the
/// original single file for readability; the members are unchanged.
extension CompositionRoot {

    /// Builds the file-backed local annotation store the Certificates area
    /// drives: display labels, import dates, and the default identity. The
    /// catalog holds public certificate fingerprints and user-chosen labels
    /// only — no key material, no passwords — and lives next to the other
    /// local workspaces under Application Support.
    static func makeIdentityAnnotationsStore() -> any IdentityAnnotationsStore {
        FileIdentityAnnotationsStore(catalogLocation: identityAnnotationsCatalogLocation())
    }

    /// Builds the file-backed provisioning profile library, lazily created
    /// at the canonical Application Support location.
    static func makeProvisioningProfileLibrary() -> ProvisioningProfileLibrary {
        FileProvisioningProfileLibrary(catalogLocation: provisioningProfileCatalogLocation())
    }

    /// The signing identity store for this launch.
    ///
    /// On iOS the store is the experimental Keychain composition: registrations
    /// live as generic-password items, private keys remain in the Keychain with
    /// `WhenUnlockedThisDeviceOnly` and non-extractable protection, and
    /// resolution re-checks public-key association and algorithm support on
    /// every operation. On other platforms the store reports no identities
    /// rather than fabricating one.
    static func makeIdentityStore() -> any IdentityStore {
        #if os(iOS)
        return SecureIdentityStore.experimentalKeychainStore()
        #else
        return UnavailableIdentityStore()
        #endif
    }

    /// The PKCS#12 importer for this launch. It bridges Security's import to
    /// the store's registration. On non-iOS targets it reports a platform
    /// restriction.
    static func makePKCS12Importer(identityStore: any IdentityStore) -> any SigningIdentityImporter {
        #if os(iOS)
        if let secure = identityStore as? SecureIdentityStore {
            return ApplePKCS12Importer(store: secure)
        }
        #endif
        return UnavailablePKCS12Importer()
    }

    /// Builds a certificate inspector.
    ///
    /// The parser and the clock are selected here. Inspection is not installed
    /// in the application environment and is not reachable from the interface:
    /// nothing in the shell imports, exports, or manages certificates, and
    /// inspection does not persist the bytes it reads.
    static func makeCertificateInspector(
        parser: any CertificateParser = AppleCertificateParser(),
        clock: any EvaluationClock = SystemEvaluationClock()
    ) -> CertificateInspector {
        CertificateInspector(parser: parser, clock: clock)
    }
}
