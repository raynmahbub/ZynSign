import Foundation

/// Versioned, redacted observations, never an authorization to install.
enum ReleaseReadinessCategory: String, Codable, CaseIterable, Identifiable {
    case structure, identity, profile, entitlements, signature, package
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var weight: Int {
        switch self {
        case .structure, .signature: return 20
        default: return 15
        }
    }
}

enum ReleaseCheckState: String, Codable {
    case verified, warning, blocked, unsupported, notChecked
    var title: String {
        switch self {
        case .verified: return "Verified"
        case .warning: return "Warning"
        case .blocked: return "Blocked"
        case .unsupported: return "Unsupported"
        case .notChecked: return "Not checked"
        }
    }
    var rank: Int {
        switch self {
        case .verified: return 0
        case .warning: return 1
        case .notChecked: return 2
        case .unsupported: return 3
        case .blocked: return 4
        }
    }
}

struct ReleaseReadinessCheck: Codable, Equatable, Identifiable {
    let id: String
    let category: ReleaseReadinessCategory
    let state: ReleaseCheckState
    let title: String
    let explanation: String
    let technicalDetails: String
    let nextAction: String
}

struct ReleaseReadinessReport: Codable, Identifiable {
    static let schemaVersion = 1
    let id: UUID
    let recordID: String
    let exportID: String?
    let validatedAt: Date
    let checks: [ReleaseReadinessCheck]

    static let boundary = "Local validation only. Certificate trust, revocation, device compatibility and installation are not established. External macOS validation has rejected this build's resource seal; DER and other iOS requirements remain outstanding. Do not treat this report as platform acceptance."

    func state(for category: ReleaseReadinessCategory) -> ReleaseCheckState {
        checks.filter { $0.category == category }.map(\.state).max { $0.rank < $1.rank } ?? .notChecked
    }
    func points(for category: ReleaseReadinessCategory) -> Int {
        switch state(for: category) {
        case .verified: return category.weight
        case .warning: return category.weight / 2
        default: return 0
        }
    }
    var score: Int { ReleaseReadinessCategory.allCases.reduce(0) { $0 + points(for: $1) } }
    var blockers: [ReleaseReadinessCheck] { checks.filter { $0.state == .blocked } }
    var warnings: [ReleaseReadinessCheck] { checks.filter { $0.state == .warning } }
    var information: [ReleaseReadinessCheck] { checks.filter { $0.state == .unsupported || $0.state == .notChecked } }
    var successfulCount: Int { checks.filter { $0.state == .verified }.count }
    var status: String {
        if !blockers.isEmpty { return "Blocked" }
        return ReleaseReadinessCategory.allCases.allSatisfy { state(for: $0) == .verified } ? "Ready" : "Attention"
    }
    var summary: String { "\(status), \(score) out of 100. \(blockers.count) blocking issues, \(warnings.count) warnings, \(information.count) inconclusive checks." }

    /// Only fixed templates and opaque record IDs are exported. No profile,
    /// entitlement values, certificate names, paths or key material.
    var plainText: String {
        var lines = ["ZynSign Release Readiness — schema \(Self.schemaVersion)",
                     "App record: \(recordID)", "Export record: \(exportID ?? "None selected")",
                     "Validation time: \(ISO8601DateFormatter().string(from: validatedAt))", summary,
                     Self.boundary, "Historical observation; run again after any input changes."]
        for category in ReleaseReadinessCategory.allCases {
            lines.append("\(category.title): \(state(for: category).title), \(points(for: category))/\(category.weight) points; deduction \(category.weight - points(for: category)).")
        }
        for check in checks {
            lines.append("\(check.title) [\(check.state.title)]\n\(check.explanation)\n\(check.technicalDetails)\nNext: \(check.nextAction)")
        }
        return lines.joined(separator: "\n\n")
    }
}
