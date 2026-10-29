import Foundation

/// Portable `.zcert` signing identity archive bundling a PKCS#12 identity,
/// its `.mobileprovision` profile, passphrase, and local operator notes,
/// together with deterministic PKCS#12 passphrase candidate generation.
struct ZynCertificateBundle: Equatable, Sendable {
    var name: String
    var password: String
    var p12Data: Data
    var mobileProvisionData: Data
    var notes: String?
    var createdAt: Date

    init(
        name: String,
        password: String,
        p12Data: Data,
        mobileProvisionData: Data,
        notes: String? = nil,
        createdAt: Date = Date()
    ) {
        self.name = name
        self.password = password
        self.p12Data = p12Data
        self.mobileProvisionData = mobileProvisionData
        self.notes = notes
        self.createdAt = createdAt
    }
}

enum ZynCertificateBundleCodec {

    static let fileExtension = "zcert"
    static let maximumPackageBytes = 16 * 1_024 * 1_024

    enum CodecError: Error, Equatable, Sendable {
        case emptyOrOversized
        case unrecognizedContainer
        case missingCertificateOrProfile

        var message: String {
            switch self {
            case .emptyOrOversized:
                return "The .zcert identity archive is empty or exceeds the 16 MiB bound."
            case .unrecognizedContainer:
                return "The .zcert identity archive is neither valid JSON nor a valid Property List."
            case .missingCertificateOrProfile:
                return "The .zcert identity archive is missing its PKCS#12 or .mobileprovision payload."
            }
        }
    }

    /// Encodes a `.zcert` archive as canonical UTF-8 JSON.
    static func encode(_ package: ZynCertificateBundle) throws -> Data {
        let dict: [String: Any] = [
            "version": 1,
            "name": package.name,
            "password": package.password,
            "p12": package.p12Data.base64EncodedString(),
            "mobileprovision": package.mobileProvisionData.base64EncodedString(),
            "notes": package.notes ?? "",
            "createdAt": ISO8601DateFormatter().string(from: package.createdAt)
        ]
        return try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
    }

    /// Encodes a `.zcert` archive as an XML Property List.
    static func encodePropertyList(_ package: ZynCertificateBundle) throws -> Data {
        let dict: [String: Any] = [
            "version": 1,
            "name": package.name,
            "password": package.password,
            "p12": package.p12Data,
            "mobileprovision": package.mobileProvisionData,
            "notes": package.notes ?? "",
            "createdAt": ISO8601DateFormatter().string(from: package.createdAt)
        ]
        return try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    /// Decodes a `.zcert` archive from JSON or XML/Binary Property List.
    static func decode(_ data: Data) throws -> ZynCertificateBundle {
        guard !data.isEmpty, data.count <= maximumPackageBytes else {
            throw CodecError.emptyOrOversized
        }
        let dict: [String: Any]
        if let jsonObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = jsonObj
        } else if let plistObj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            dict = plistObj
        } else {
            throw CodecError.unrecognizedContainer
        }

        let p12 = extractBinary(from: dict, keys: ["p12", "p12Data", "cert", "certificate", "pkcs12"])
        let mp = extractBinary(from: dict, keys: ["mobileprovision", "provisionData", "mp", "provision", "profile"])
        guard let p12Data = p12, !p12Data.isEmpty,
              let mpData = mp, !mpData.isEmpty else {
            throw CodecError.missingCertificateOrProfile
        }

        let name = (dict["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = (dict["password"] as? String)
            ?? (dict["passphrase"] as? String)
            ?? (dict["pwd"] as? String)
            ?? ""
        let notes = (dict["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let createdAt = (dict["createdAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()

        return ZynCertificateBundle(
            name: (name?.isEmpty == false ? name : nil) ?? "Imported Identity Archive",
            password: password,
            p12Data: p12Data,
            mobileProvisionData: mpData,
            notes: (notes?.isEmpty == false ? notes : nil),
            createdAt: createdAt
        )
    }

    /// Generates an ordered, deduplicated list of PKCS#12 passphrase candidates
    /// combining user-supplied guesses, file stem hints, and common certificate passphrases.
    static func generatePassphraseCandidates(
        fileName: String?,
        customCandidates: [String] = []
    ) -> [String] {
        var ordered: [String] = []
        var seen: Set<String> = []
        let appendUnique: (String) -> Void = { item in
            if seen.insert(item).inserted {
                ordered.append(item)
            }
        }

        for candidate in customCandidates {
            appendUnique(candidate)
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { appendUnique(trimmed) }
        }

        if let fileName {
            let stem = (fileName as NSString).deletingPathExtension
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !stem.isEmpty {
                appendUnique(stem)
                appendUnique(stem.lowercased())
            }
        }

        let builtIn = [
            "", "1", "12", "123", "1234", "12345", "123456", "1234567", "12345678",
            "1111", "0000", "password", "pass", "cert", "certificate", "apple",
            "ios", "dev", "developer", "distribution", "zynsign", "sign"
        ]
        for item in builtIn {
            appendUnique(item)
        }
        return ordered
    }

    private static func extractBinary(from dict: [String: Any], keys: [String]) -> Data? {
        for key in keys {
            if let data = dict[key] as? Data, !data.isEmpty {
                return data
            }
            if let str = dict[key] as? String {
                let cleaned = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if let decoded = Data(base64Encoded: cleaned, options: [.ignoreUnknownCharacters]),
                   !decoded.isEmpty {
                    return decoded
                }
            }
        }
        return nil
    }
}
