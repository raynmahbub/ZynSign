import Foundation

/// IdentityStore implementation independent of Security's object types.
/// The Keychain composition remains experimental until device validation.
/// Synchronous calls belong on a serialized worker, not the UI thread.
final class SecureIdentityStore: IdentityStore, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let registry: any SigningIdentityRegistry
    private let resolver: any SigningIdentityKeyResolver
    private let parser: any CertificateParser

    init(registry: any SigningIdentityRegistry, resolver: any SigningIdentityKeyResolver,
         parser: any CertificateParser = AppleCertificateParser()) {
        self.registry = registry
        self.resolver = resolver
        self.parser = parser
    }

    func listIdentities() throws -> [SigningIdentity] {
        try sanitized {
            try records().map { try snapshot($0) }.sorted { $0.id.rawValue < $1.id.rawValue }
        }
    }

    func identity(withID id: SigningIdentityIdentifier) throws -> SigningIdentity? {
        try sanitized {
            guard let record = try record(for: id) else { return nil }
            return try snapshot(record)
        }
    }

    func signingCapability(for id: SigningIdentityIdentifier) throws -> any SigningCapability {
        try sanitized {
            let capability = try resolve(id)
            return ResolvedStoreCapability(store: self, identityID: id,
                                           publicKeyAlgorithm: capability.publicKeyAlgorithm)
        }
    }

    /// Registers an already-stored key. Not a key or PKCS#12 import API.
    /// This method is intentionally absent from the Application port.
    @discardableResult
    func register(certificateDER: Data, keyReference: Data) throws -> SigningIdentityIdentifier {
        try sanitized {
            let certificate = try parse(certificateDER)
            let record = StoredSigningIdentity(id: SigningIdentityIdentifier(),
                certificateDER: certificateDER,
                certificateFingerprint: certificate.sha256Fingerprint, keyReference: keyReference)
            _ = try record.id
            if try records().contains(where: { $0.certificateFingerprint == record.certificateFingerprint }) {
                throw ZynSignError.identity(.duplicateIdentity)
            }
            _ = try checkedCapability(record, certificate: certificate)
            try registry.insert(record)
            return try record.id
        }
    }

    /// Forgets only the registration. Borrowed keys remain owned by their
    /// provisioning component. Previously issued capabilities recheck membership.
    func removeRegistration(_ id: SigningIdentityIdentifier) throws {
        try sanitized { try registry.remove(id) }
    }

    fileprivate func resolve(_ id: SigningIdentityIdentifier) throws -> any SigningCapability {
        try sanitized {
            guard let record = try record(for: id) else {
                throw ZynSignError.identity(.identityNotFound)
            }
            return try checkedCapability(record, certificate: metadata(record))
        }
    }

    private func records() throws -> [StoredSigningIdentity] {
        let records = try registry.records()
        var ids = Set<SigningIdentityIdentifier>()
        var fingerprints = Set<String>()
        for record in records {
            guard ids.insert(try record.id).inserted,
                  fingerprints.insert(record.certificateFingerprint).inserted else {
                throw ZynSignError.identity(.malformedStoredIdentity)
            }
        }
        return records
    }

    private func record(for id: SigningIdentityIdentifier) throws -> StoredSigningIdentity? {
        try records().first { try $0.id == id }
    }

    private func parse(_ der: Data) throws -> CertificateMetadata {
        guard !der.isEmpty else { throw ZynSignError.identity(.certificateUnavailable) }
        do { return try parser.parseCertificate(derData: der) }
        catch { throw ZynSignError.identity(.malformedStoredIdentity) }
    }

    private func metadata(_ record: StoredSigningIdentity) throws -> CertificateMetadata {
        let certificate = try parse(record.certificateDER)
        guard certificate.sha256Fingerprint.hexDigest == record.certificateFingerprint else {
            throw ZynSignError.identity(.malformedStoredIdentity)
        }
        return certificate
    }

    private func checkedCapability(_ record: StoredSigningIdentity,
                                   certificate: CertificateMetadata) throws -> any SigningCapability {
        let capability = try resolver.resolve(record)
        guard capability.identityID == (try record.id),
              capability.publicKeyAlgorithm == certificate.publicKeyInfo.algorithm else {
            throw ZynSignError.identity(.certificateKeyMismatch)
        }
        guard capability.isAvailable else { throw ZynSignError.identity(.capabilityUnavailable) }
        guard !capability.supportedAlgorithms.isEmpty else {
            throw ZynSignError.identity(.unsupportedSigningAlgorithm)
        }
        return capability
    }

    private func snapshot(_ record: StoredSigningIdentity) throws -> SigningIdentity {
        let certificate = try metadata(record)
        var availability: SigningKeyAvailability = .unknown
        var association: CertificateKeyAssociation = .unknown
        var state: SigningCapabilityState = .unknown
        do {
            _ = try checkedCapability(record, certificate: certificate)
            availability = .available
            association = .matched
            state = .ready
        } catch {
            switch (error as? ZynSignError)?.identityFailure {
            case .privateKeyUnavailable, .capabilityUnavailable:
                availability = .unavailable
                state = .unavailable
            case .certificateKeyMismatch:
                availability = .available
                association = .mismatched
                state = .unavailable
            case .authorizationFailure:
                state = .authorizationRequired
            case .unsupportedKeyType, .unsupportedSigningAlgorithm, .platformRestriction:
                state = .unsupported
            default: throw error
            }
        }
        return SigningIdentity(id: try record.id, certificate: certificate,
            keyAvailability: availability,
            association: association, capabilityState: state, storage: .keychain)
    }

    private func sanitized<T>(_ operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch { throw ZynSignError.sanitizedIdentityFailure(error) }
    }

    var description: String { "SecureIdentityStore(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Does not cache a SecKey or an availability decision across operations.
private final class ResolvedStoreCapability: SigningCapability, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let store: SecureIdentityStore
    let identityID: SigningIdentityIdentifier
    let publicKeyAlgorithm: PublicKeyAlgorithm

    init(store: SecureIdentityStore, identityID: SigningIdentityIdentifier,
         publicKeyAlgorithm: PublicKeyAlgorithm) {
        self.store = store
        self.identityID = identityID
        self.publicKeyAlgorithm = publicKeyAlgorithm
    }

    var isAvailable: Bool { (try? store.resolve(identityID)) != nil }
    var supportedAlgorithms: Set<SigningAlgorithm> {
        (try? store.resolve(identityID).supportedAlgorithms) ?? []
    }

    func sign(data: Data, algorithm: SigningAlgorithm) throws -> Data {
        do {
            try algorithm.validate(data: data, keyAlgorithm: publicKeyAlgorithm)
            let capability = try store.resolve(identityID)
            guard capability.supportedAlgorithms.contains(algorithm) else {
                throw ZynSignError.identity(.unsupportedSigningAlgorithm)
            }
            return try capability.sign(data: data, algorithm: algorithm)
        } catch { throw ZynSignError.sanitizedIdentityFailure(error) }
    }

    var description: String { "SigningCapability(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}
