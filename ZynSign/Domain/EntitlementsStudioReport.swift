import Foundation

/// An explicit export projection. It cannot carry a certificate, profile body,
/// private key, filesystem URL, or identity-store handle.
struct EntitlementsStudioReport: Encodable {
    let schemaVersion: Int
    let generatedAt: Date
    let applicationName: String
    let bundleIdentifier: String
    let target: String
    let summary: String
    let status: String
    let totalEntitlements: Int
    let supportedMatches: Int
    let warnings: Int
    let blockingMismatches: Int
    let unknown: Int
    let scope: String
    let checks: [Check]
    let entitlements: [Claim]

    struct Check: Encodable {
        let title: String
        let status: String
        let explanation: String
    }
    struct Claim: Encodable {
        let name: String
        let key: String
        let capability: String
        let valueType: String
        let appValue: String
        let profileValue: String
        let status: String
        let explanation: String
    }

    init(name: String, bundleID: String, target: String, analysis: EntitlementStudioAnalysis, date: Date = Date()) {
        schemaVersion = 1
        generatedAt = date
        applicationName = name
        bundleIdentifier = bundleID
        self.target = target
        summary = analysis.summary
        status = analysis.status.rawValue
        totalEntitlements = analysis.rows.count
        supportedMatches = analysis.count(.compatible)
        warnings = analysis.count(.warning)
        blockingMismatches = analysis.count(.blocked)
        unknown = analysis.count(.unknown)
        scope = "Read-only declared-data comparison, not platform acceptance. Main executable / selected architecture only. Binary contents and unknown-key values are omitted for privacy. No certificate, credential, private key or profile body is included."
        checks = analysis.checks.map { Check(title: $0.title, status: $0.status.rawValue, explanation: $0.message) }
        entitlements = analysis.rows.map { row in
            let known = row.capability.category != "Other / Unknown"
            return Claim(name: row.capability.name, key: row.key, capability: row.capability.category,
                         valueType: EntitlementStudioValue.typeName(row.value),
                         appValue: known ? Self.safeValue(row.value) : "[Unknown-key value omitted]",
                         profileValue: row.profileValue.map { known ? Self.safeValue($0) : "[Unknown-key value omitted]" } ?? "Not declared / unavailable",
                         status: row.finding.status.rawValue, explanation: row.finding.message)
        }
    }

    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    private static func safeValue(_ value: ProvisioningProfileValue) -> String {
        switch value {
        case .data: return "[Binary content omitted]"
        case .dictionary: return "[Structured value omitted for privacy]"
        case .array(let values): return "[" + values.map(safeValue).joined(separator: ", ") + "]"
        case .string(let text) where text.contains("-----BEGIN") || text.lowercased().contains("password") || text.lowercased().contains("secret"):
            return "[Sensitive-looking value omitted]"
        default: return EntitlementStudioValue.raw(value)
        }
    }
}
