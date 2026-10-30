import Foundation

/// A `.mobiledevicepairing` record: the trust anchor for every device session.
///
/// The file carries two certificate chains and the host's private key. The
/// host presents `HostCertificate` + `HostPrivateKey` in TLS, and accepts the
/// device only when its certificate chains to `RootCertificate`. `HostID` is
/// the identifier stored by the device and echoed in `StartSession`. Imported
/// records may use a canonical UUID or the supported certificate-digest form;
/// neither form proves that the certificates and private key match.
///
/// The record is a bearer credential: whoever holds `HostPrivateKey` can talk
/// to the device. ZynSign therefore never writes it to a plain file, never
/// logs it, and stores it through the Keychain-backed `SecureIdentityStore`.
/// The type keeps the bytes and answers questions; it does no I/O.
struct DevicePairingRecord: Equatable, Sendable {

    /// Property-list keys, exactly as a device writes them.
    enum Key {
        static let deviceCertificate = "DeviceCertificate"
        static let rootCertificate = "RootCertificate"
        static let hostCertificate = "HostCertificate"
        static let hostPrivateKey = "HostPrivateKey"
        static let hostID = "HostID"
        static let systemBUID = "SystemBUID"
        static let wifiMACAddress = "Wi-Fi MAC Address"
        static let escrowBag = "EscrowBag"
    }

    static let requiredKeys = [
        Key.deviceCertificate, Key.rootCertificate, Key.hostCertificate,
        Key.hostPrivateKey, Key.hostID, Key.systemBUID,
    ]

    let deviceCertificate: Data
    let rootCertificate: Data
    let hostCertificate: Data
    let hostPrivateKey: Data
    let hostIdentifier: String
    let systemBUID: String
    let wifiMACAddress: String?
    let escrowBag: Data?
    /// When the record was imported, for the device list's "paired" row.
    let importedAt: Date

    init(
        deviceCertificate: Data,
        rootCertificate: Data,
        hostCertificate: Data,
        hostPrivateKey: Data,
        hostIdentifier: String,
        systemBUID: String,
        wifiMACAddress: String? = nil,
        escrowBag: Data? = nil,
        importedAt: Date = Date()
    ) {
        self.deviceCertificate = deviceCertificate
        self.rootCertificate = rootCertificate
        self.hostCertificate = hostCertificate
        self.hostPrivateKey = hostPrivateKey
        self.hostIdentifier = hostIdentifier.uppercased()
        self.systemBUID = systemBUID
        self.wifiMACAddress = wifiMACAddress
        self.escrowBag = escrowBag
        self.importedAt = importedAt
    }

    /// Host identifier for display; UUID-form identifiers are not certificate fingerprints.
    var hostFingerprint: String {
        hostIdentifier
    }

    /// The identity a TLS layer needs, named rather than inlined.
    struct TLSIdentity: Equatable, Sendable {
        let certificate: Data
        let privateKey: Data
        let rootCertificate: Data
    }

    var tlsIdentity: TLSIdentity {
        TLSIdentity(certificate: hostCertificate,
                    privateKey: hostPrivateKey,
                    rootCertificate: rootCertificate)
    }
}

/// Why a pairing file was refused. Each case names the missing or wrong fact.
enum PairingRecordError: Error, Equatable, Hashable, Sendable {
    case unreadablePropertyList
    case notADictionary
    case missingKeys([String])
    case hostIdentifierMismatch(declared: String, computed: String)
    case emptyField(String)
    case recordTooLarge(bytes: Int)

    var message: String {
        switch self {
        case .unreadablePropertyList:
            return "The pairing file is not a property list."
        case .notADictionary:
            return "The pairing file root is not a dictionary."
        case .missingKeys(let keys):
            return "The pairing file is missing \(keys.joined(separator: ", "))."
        case .hostIdentifierMismatch(let declared, let computed):
            return "HostID \(declared) does not match the host certificate (\(computed))."
        case .emptyField(let field):
            return "\(field) is empty."
        case .recordTooLarge(let bytes):
            return "The pairing file is \(bytes) bytes; the limit is 1 MiB."
        }
    }
}

enum PairingRecordCoding {

    /// A pairing file is a few kilobytes. Anything far larger is refused
    /// before it is parsed.
    static let maximumBytes = 1 * 1_024 * 1_024

    /// Parse a `.mobiledevicepairing` file and check it against its own
    /// certificate. `digest` supplies SHA-1 — Domain has no crypto library.
    static func decode(_ data: Data, digest: any MessageDigest) throws -> DevicePairingRecord {
        guard data.count <= maximumBytes else {
            throw PairingRecordError.recordTooLarge(bytes: data.count)
        }
        let value: Any
        do {
            value = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil)
        } catch {
            throw PairingRecordError.unreadablePropertyList
        }
        guard let root = value as? [String: Any] else {
            throw PairingRecordError.notADictionary
        }
        let missing = DevicePairingRecord.requiredKeys.filter { root[$0] == nil }
        guard missing.isEmpty else {
            throw PairingRecordError.missingKeys(missing)
        }
        func field(_ key: String) throws -> Data {
            guard let value = root[key] as? Data, !value.isEmpty else {
                throw PairingRecordError.emptyField(key)
            }
            return value
        }
        let hostCertificate = try field(DevicePairingRecord.Key.hostCertificate)
        let computed = try hostIdentifier(forCertificate: hostCertificate, digest: digest)
        let declared = (root[DevicePairingRecord.Key.hostID] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !declared.isEmpty else {
            throw PairingRecordError.emptyField(DevicePairingRecord.Key.hostID)
        }
        let isCanonicalHostUUID = declared.count == 36 && UUID(uuidString: declared) != nil
        guard declared == computed || isCanonicalHostUUID else {
            throw PairingRecordError.hostIdentifierMismatch(declared: declared,
                                                            computed: computed)
        }
        guard let rawBUID = root[DevicePairingRecord.Key.systemBUID] as? String else {
            throw PairingRecordError.emptyField(DevicePairingRecord.Key.systemBUID)
        }
        let buid = rawBUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !buid.isEmpty, buid.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw PairingRecordError.emptyField(DevicePairingRecord.Key.systemBUID)
        }
        return DevicePairingRecord(
            deviceCertificate: try field(DevicePairingRecord.Key.deviceCertificate),
            rootCertificate: try field(DevicePairingRecord.Key.rootCertificate),
            hostCertificate: hostCertificate,
            hostPrivateKey: try field(DevicePairingRecord.Key.hostPrivateKey),
            hostIdentifier: declared,
            systemBUID: buid,
            wifiMACAddress: root[DevicePairingRecord.Key.wifiMACAddress] as? String,
            escrowBag: root[DevicePairingRecord.Key.escrowBag] as? Data
        )
    }

    /// `HostID` is SHA-1 of the host certificate, uppercase hexadecimal.
    static func hostIdentifier(forCertificate certificate: Data,
                               digest: any MessageDigest) throws -> String {
        let value = try digest.digest(certificate, algorithm: .sha1)
        return value.bytes.map { String(format: "%02X", $0) }.joined()
    }

    /// Re-encode for the Keychain-backed store. The bytes are the same
    /// format the device expects, so an exported record still pairs.
    static func encode(_ record: DevicePairingRecord) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: record.propertyList(), format: .binary, options: 0)
    }
}

extension DevicePairingRecord {

    /// The property-list form, used for export and for the `Pair` request.
    func propertyList() -> [String: Any] {
        var values: [String: Any] = [
            Key.deviceCertificate: deviceCertificate,
            Key.rootCertificate: rootCertificate,
            Key.hostCertificate: hostCertificate,
            Key.hostPrivateKey: hostPrivateKey,
            Key.hostID: hostIdentifier,
            Key.systemBUID: systemBUID,
        ]
        if let wifiMACAddress { values[Key.wifiMACAddress] = wifiMACAddress }
        if let escrowBag { values[Key.escrowBag] = escrowBag }
        return values
    }

    /// What a screen may show: no key material, no certificate bytes.
    var redactedSummary: String {
        "Paired host \(hostIdentifier.prefix(8))… · BUID \(systemBUID.prefix(8))…"
    }
}
