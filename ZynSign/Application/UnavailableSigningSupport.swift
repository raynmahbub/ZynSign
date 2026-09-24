import Foundation

/// Fallback identity store for platforms where Security is unavailable.
/// It reports no identities and fails any capability request. The
/// composition root selects this store off-device so the application
/// environment is always constructible, but no signing operation will
/// succeed.
struct UnavailableIdentityStore: IdentityStore {
    func listIdentities() throws -> [SigningIdentity] { [] }
    func identity(withID id: SigningIdentityIdentifier) throws -> SigningIdentity? { nil }
    func signingCapability(for id: SigningIdentityIdentifier) throws -> any SigningCapability {
        throw ZynSignError.identity(.identityNotFound)
    }
    func signingCertificate(for id: SigningIdentityIdentifier) throws -> Certificate {
        throw ZynSignError.identity(.identityNotFound)
    }
}

/// Fallback PKCS#12 importer for non-iOS targets. Every import reports a
/// platform restriction rather than silently succeeding.
struct UnavailablePKCS12Importer: SigningIdentityImporter {
    func importPKCS12(data: Data, password: String) throws -> SigningIdentityIdentifier {
        throw ZynSignError.identity(.platformRestriction)
    }
}
