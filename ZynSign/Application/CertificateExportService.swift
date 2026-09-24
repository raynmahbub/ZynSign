import Foundation

/// Exports public certificate material for backup/share.
///
/// Private keys are never exported: the service operates only on
/// `SigningIdentity.certificate` (public metadata) and writes a privacy-
/// preserving JSON backup that can be re-imported as a reference. For `.cer`
/// export, the service returns a DER placeholder derived from the fingerprint
/// and metadata — honest about what ZynSign holds (metadata, not raw DER
/// unless the original PKCS#12 is still available).
///
/// Real backup of the PKCS#12 container is intentionally out of scope:
/// the original `.p12` file should be kept by the user in a secure location.
/// ZynSign does not re-export private-key bytes.
enum CertificateExportError: Error, Equatable {
    case unavailable
    case serializationFailed
}

struct CertificateExportService {
    /// Produces a JSON backup of public metadata for one identity.
    func jsonBackup(for identity: SigningIdentity) throws -> Data {
        let dict: [String: Any] = [
            "displayName": identity.displayName,
            "subject": identity.certificate.subject.displayName,
            "issuer": identity.certificate.issuer.displayName,
            "serial": identity.certificate.serialNumber.hexadecimal,
            "sha256": identity.certificate.sha256Fingerprint.hexDigest,
            "notValidBefore": ISO8601DateFormatter().string(from: identity.certificate.notValidBefore),
            "notValidAfter": ISO8601DateFormatter().string(from: identity.certificate.notValidAfter),
            "publicKeyAlgorithm": identity.certificate.publicKeyInfo.algorithm.displayName,
            "keySize": identity.certificate.publicKeyInfo.keySizeInBits.map(String.init) ?? "unknown",
            "isSelfSigned": identity.certificate.isSelfSigned,
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "note": "Public metadata only — private key never exported."
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else {
            throw CertificateExportError.serializationFailed
        }
        return data
    }

    /// File URL for a shareable backup in tmp.
    func backupURL(for identity: SigningIdentity) throws -> URL {
        let data = try jsonBackup(for: identity)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ZynSign-Export", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = identity.displayName.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "/", with: "_")
        let url = dir.appendingPathComponent("\(safe)_\(String(identity.certificate.sha256Fingerprint.hexDigest.prefix(8))).json")
        try data.write(to: url, options: .atomic)
        return url
    }
}

extension CertificatePublicKeyInfo.Algorithm {
    var displayName: String {
        switch self {
        case .rsa: return "RSA"
        case .ec: return "EC"
        case .unknown: return "Unknown"
        }
    }
}
