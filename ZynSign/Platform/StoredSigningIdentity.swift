import Foundation

/// Platform-only registry schema. `keyReference` is a Keychain locator, not a
/// key encoding. Never move this type into the application catalog or UI.
struct StoredSigningIdentity: Codable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private enum CodingKeys: String, CodingKey {
        case version, identifier, certificateDER, certificateFingerprint, keyReference
    }

    let version: Int
    private let identifier: String
    let certificateDER: Data
    let certificateFingerprint: String
    let keyReference: Data

    init(id: SigningIdentityIdentifier, certificateDER: Data,
         certificateFingerprint: CertificateFingerprint, keyReference: Data) {
        version = 1
        identifier = id.rawValue
        self.certificateDER = certificateDER
        self.certificateFingerprint = certificateFingerprint.hexDigest
        self.keyReference = keyReference
    }

    var id: SigningIdentityIdentifier {
        get throws {
            guard version == 1,
                  let id = SigningIdentityIdentifier(rawValue: identifier),
                  identifier == id.rawValue,
                  CertificateFingerprint(hexDigest: certificateFingerprint) != nil,
                  !certificateDER.isEmpty,
                  certificateDER.count <= CertificateInput.maximumByteCount,
                  !keyReference.isEmpty, keyReference.count <= 4096 else {
                throw ZynSignError.identity(.malformedStoredIdentity)
            }
            return id
        }
    }

    static func decode(_ data: Data) throws -> StoredSigningIdentity {
        guard data.count <= maximumEncodedByteCount else {
            throw ZynSignError.identity(.malformedStoredIdentity)
        }
        do {
            let record = try JSONDecoder().decode(Self.self, from: data)
            _ = try record.id
            return record
        } catch {
            throw ZynSignError.identity(.malformedStoredIdentity)
        }
    }

    func encoded() throws -> Data {
        _ = try id
        do { return try JSONEncoder().encode(self) }
        catch { throw ZynSignError.identity(.malformedStoredIdentity) }
    }

    static let maximumEncodedByteCount = 2 * CertificateInput.maximumByteCount
    var description: String { "StoredSigningIdentity(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Owns registration records only; deleting a record must not delete a key.
protocol SigningIdentityRegistry {
    func records() throws -> [StoredSigningIdentity]
    /// Must atomically reject duplicate certificate fingerprints.
    func insert(_ record: StoredSigningIdentity) throws
    func remove(_ id: SigningIdentityIdentifier) throws
}

/// Platform-only seam. Resolution must validate storage protections and the
/// actual public-key relationship, not just certificate metadata or a label.
protocol SigningIdentityKeyResolver {
    func resolve(_ record: StoredSigningIdentity) throws -> any SigningCapability
}
