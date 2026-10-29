import Foundation
#if canImport(Security)
import Security
#endif

/// Keychain-backed store for `.mobiledevicepairing` records (`HostPrivateKey`,
/// `HostCertificate`, and `RootCertificate` never touch plaintext disk).
final class KeychainPairingRecordStore: PairingRecordStoring, @unchecked Sendable {

    private let service: String
    private let digest: any MessageDigest
    private let fallbackLock = NSLock()
    private var inMemoryFallback: [String: Data] = [:]

    init(
        service: String = "io.zynsign.device-pairing-records.v1",
        digest: any MessageDigest = CryptoKitMessageDigest()
    ) {
        self.service = service
        self.digest = digest
    }

    func save(_ record: DevicePairingRecord) throws {
        let encoded = try PairingRecordCoding.encode(record)
        let account = record.hostIdentifier.uppercased()
        #if os(iOS)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: encoded
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ZynSignError.identity(.keychainAccessFailure, diagnosticDetail: "SecItemAdd pairing status \(status)")
        }
        #else
        fallbackLock.lock()
        inMemoryFallback[account] = encoded
        fallbackLock.unlock()
        #endif
    }

    func all() throws -> [DevicePairingRecord] {
        #if os(iOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw ZynSignError.identity(.keychainAccessFailure, diagnosticDetail: "SecItemCopyMatching pairing status \(status)")
        }
        let payloads: [Data]
        if let multi = result as? [Data] {
            payloads = multi
        } else if let single = result as? Data {
            payloads = [single]
        } else {
            return []
        }
        return payloads.compactMap { try? PairingRecordCoding.decode($0, digest: digest) }
        #else
        fallbackLock.lock()
        let values = Array(inMemoryFallback.values)
        fallbackLock.unlock()
        return values.compactMap { try? PairingRecordCoding.decode($0, digest: digest) }
        #endif
    }

    func remove(hostIdentifier: String) throws {
        let account = hostIdentifier.uppercased()
        #if os(iOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ZynSignError.identity(.keychainAccessFailure, diagnosticDetail: "SecItemDelete pairing status \(status)")
        }
        #else
        fallbackLock.lock()
        inMemoryFallback.removeValue(forKey: account)
        fallbackLock.unlock()
        #endif
    }
}
