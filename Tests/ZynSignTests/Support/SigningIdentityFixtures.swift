import Foundation
@testable import ZynSign

/// Registry round-trips the real schema, but never touches Keychain or files.
final class MemoryIdentityRegistry: SigningIdentityRegistry {
    var stored: [Data] = []
    var failure: Error?

    func records() throws -> [StoredSigningIdentity] {
        if let failure { throw failure }
        return try stored.map(StoredSigningIdentity.decode)
    }

    func insert(_ record: StoredSigningIdentity) throws {
        if try records().contains(where: { $0.certificateFingerprint == record.certificateFingerprint }) {
            throw ZynSignError.identity(.duplicateIdentity)
        }
        stored.append(try record.encoded())
    }

    func remove(_ id: SigningIdentityIdentifier) throws {
        stored = try records().filter { try $0.id != id }.map { try $0.encoded() }
    }
}

/// Synthetic operation only; contains no private key or production credential.
final class TestIdentityResolver: SigningIdentityKeyResolver {
    var failure: Error?
    var signingFailure: Error?
    var available = true
    var supported: Set<SigningAlgorithm> = Set(SigningAlgorithm.allCases)
    var signedInputs: [(Data, SigningAlgorithm)] = []
    var resolutions = 0
    let signature = Data("synthetic-signature".utf8)

    func resolve(_ record: StoredSigningIdentity) throws -> any SigningCapability {
        resolutions += 1
        if let failure { throw failure }
        let metadata = try AppleCertificateParser().parseCertificate(derData: record.certificateDER)
        return Capability(identityID: try record.id, publicKeyAlgorithm: metadata.publicKeyInfo.algorithm,
                          owner: self)
    }

    private struct Capability: SigningCapability {
        let identityID: SigningIdentityIdentifier
        let publicKeyAlgorithm: PublicKeyAlgorithm
        let owner: TestIdentityResolver
        var isAvailable: Bool { owner.available }
        var supportedAlgorithms: Set<SigningAlgorithm> {
            Set(owner.supported.filter { $0.publicKeyAlgorithm == publicKeyAlgorithm })
        }
        func sign(data: Data, algorithm: SigningAlgorithm) throws -> Data {
            if let failure = owner.signingFailure { throw failure }
            owner.signedInputs.append((data, algorithm))
            return owner.signature
        }
    }
}

enum SigningIdentityFixtures {
    /// Locator test double, not key material and never used for a real key lookup.
    static let reference = Data("synthetic-key-locator".utf8)

    static func record(id: SigningIdentityIdentifier = SigningIdentityIdentifier(),
                       der: Data = CertificateFixtures.validDER) throws -> StoredSigningIdentity {
        let metadata = try AppleCertificateParser().parseCertificate(derData: der)
        return StoredSigningIdentity(id: id, certificateDER: der,
            certificateFingerprint: metadata.sha256Fingerprint, keyReference: reference)
    }
}
