#if os(iOS)
import Foundation
import Security
import LocalAuthentication

/// The iOS composition `CompositionRoot.makeIdentityStore()` installs. The
/// adapter is still provisional in what it *grants* — a registration and a key
/// handle, never certificate trust — which is the sense its "experimental"
/// label carries in docs/architecture/architecture.md.
extension SecureIdentityStore {
    static func experimentalKeychainStore() -> SecureIdentityStore {
        SecureIdentityStore(registry: KeychainIdentityRegistry(), resolver: AppleSigningKeyResolver())
    }
}

/// Owns only registrations; it never adds, updates, or deletes private keys.
final class KeychainIdentityRegistry: SigningIdentityRegistry, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let service: String

    init(service: String = "io.github.davinelion.ZynSign.signing-identities.v1") {
        self.service = service
    }

    func records() throws -> [StoredSigningIdentity] {
        try itemAttributes().map { try Self.record(in: $0) }
    }

    func insert(_ record: StoredSigningIdentity) throws {
        // Account is the certificate fingerprint, so Keychain atomically refuses
        // duplicate registration across store instances. Identity IDs are minted
        // only by SecureIdentityStore, never supplied by an external caller.
        var attributes = baseQuery()
        attributes[kSecAttrAccount as String] = record.certificateFingerprint
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecValueData as String] = try record.encoded()
        try IdentityKeychainAccess.check(SecItemAdd(attributes as CFDictionary, nil))
    }

    func remove(_ id: SigningIdentityIdentifier) throws {
        // Forgetting an identity must not be gated on every *other*
        // registration decoding cleanly. `records()` is deliberately
        // fail-closed — a damaged record must not be quietly skipped while the
        // app decides what it may sign with — but reusing it here meant one
        // unreadable registration blocked deleting every identity, including
        // itself, and the re-import that followed failed as a duplicate: a
        // dead end the user cannot clear. Each item is therefore judged on its
        // own for the purpose of finding this id, and an unreadable item is
        // only ever a reason to refuse, never a reason to report success.
        var match: StoredSigningIdentity?
        var sawUnreadableItem = false
        let items = try itemAttributes()
        for attributes in items {
            guard let record = try? Self.record(in: attributes) else {
                sawUnreadableItem = true
                continue
            }
            guard (try? record.id) == id else { continue }
            // Two registrations answering to one id is the duplicate case the
            // list read already refuses; deleting one of them would hide it.
            guard match == nil else { throw ZynSignError.identity(.malformedStoredIdentity) }
            match = record
        }
        guard let record = match else {
            if sawUnreadableItem { throw ZynSignError.identity(.malformedStoredIdentity) }
            return
        }
        var query = baseQuery()
        query[kSecAttrAccount as String] = record.certificateFingerprint
        query[kSecUseAuthenticationContext as String] = IdentityKeychainAccess.noninteractiveContext()
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try IdentityKeychainAccess.check(status) }
    }

    /// The raw attribute dictionaries of every registration in this service.
    private func itemAttributes() throws -> [[String: Any]] {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecUseAuthenticationContext as String] = IdentityKeychainAccess.noninteractiveContext()
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try IdentityKeychainAccess.check(status)
        guard let items = result as? [[String: Any]] else {
            throw ZynSignError.identity(.malformedStoredIdentity)
        }
        return items
    }

    /// One registration's record, refusing anything that is not exactly the
    /// shape this registry writes: the payload, its account, and the
    /// device-only accessibility a signing key must carry.
    private static func record(in attributes: [String: Any]) throws -> StoredSigningIdentity {
        guard let data = attributes[kSecValueData as String] as? Data,
              let account = attributes[kSecAttrAccount as String] as? String,
              attributes[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String else {
            throw ZynSignError.identity(.malformedStoredIdentity)
        }
        let record = try StoredSigningIdentity.decode(data)
        guard record.certificateFingerprint == account else {
            throw ZynSignError.identity(.malformedStoredIdentity)
        }
        return record
    }

    private func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrSynchronizable as String: false]
    }

    var description: String { "KeychainIdentityRegistry(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Sanitizes at the framework boundary. Never retains CFError, OSStatus text,
/// authentication context, query dictionaries, or key handles in errors.
enum IdentityKeychainAccess {
    static func noninteractiveContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    static func check(_ status: OSStatus,
                      missing: SigningIdentityFailure = .keychainAccessFailure) throws {
        guard status != errSecSuccess else { return }
        throw ZynSignError.identity(reason(for: status, missing: missing))
    }

    static func reason(for status: OSStatus,
                       missing: SigningIdentityFailure = .keychainAccessFailure) -> SigningIdentityFailure {
        switch status {
        case errSecItemNotFound: return missing
        case errSecDuplicateItem: return .duplicateIdentity
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled:
            return .authorizationFailure
        case errSecMissingEntitlement, errSecUnimplemented: return .platformRestriction
        case errSecDecode: return .malformedStoredIdentity
        default: return .keychainAccessFailure
        }
    }

    static func signingError(_ error: CFError?) -> ZynSignError {
        if let error, CFErrorGetDomain(error) as String == NSOSStatusErrorDomain,
           let status = OSStatus(exactly: CFErrorGetCode(error)) {
            switch status {
            case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled:
                return .identity(.authorizationFailure)
            case errSecItemNotFound: return .identity(.privateKeyUnavailable)
            case errSecMissingEntitlement, errSecUnimplemented: return .identity(.platformRestriction)
            default: break
            }
        }
        return .identity(.signingFailure)
    }
}
#endif
