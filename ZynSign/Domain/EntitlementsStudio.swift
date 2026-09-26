import Foundation

/// Inspection statuses are about declared data, never platform authorization.
enum EntitlementStudioStatus: String, CaseIterable, Hashable {
    case compatible = "Compatible", warning = "Warning", blocked = "Blocked", unknown = "Unknown"
    var symbol: String {
        switch self {
        case .compatible: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .blocked: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}

struct EntitlementCapability: Equatable {
    let name: String
    let category: String
    let explanation: String

    /// A presentation registry, not an authorization policy. Unknown keys survive.
    static func mapping(for key: String) -> Self {
        switch key {
        case "application-identifier": return .init(name: "Application Identifier", category: "Identity", explanation: "Identifies the app under the profile's application prefix, which need not equal the team ID.")
        case "com.apple.developer.team-identifier": return .init(name: "Team Identifier", category: "Identity", explanation: "Declares the development team associated with this app.")
        case "get-task-allow": return .init(name: "Debugging", category: "Debugging", explanation: "Requests debugger attachment. Absence is not the same as false.")
        case "aps-environment": return .init(name: "Push Notifications", category: "Push Notifications", explanation: "Selects the requested push notification environment.")
        case "com.apple.security.application-groups": return .init(name: "App Groups", category: "App Groups", explanation: "Requests shared containers for related apps.")
        case "keychain-access-groups": return .init(name: "Keychain Access", category: "Keychain Access", explanation: "Requests access to named keychain groups. Group prefixes can differ from the team ID.")
        case "com.apple.developer.associated-domains": return .init(name: "Associated Domains", category: "Associated Domains", explanation: "Connects the app to declared web domains. Server association files are not checked here.")
        case "com.apple.developer.siri": return .init(name: "Siri", category: "Siri", explanation: "Requests Siri integration.")
        case "com.apple.developer.healthkit", "com.apple.developer.healthkit.access", "com.apple.developer.healthkit.background-delivery": return .init(name: "Health Access", category: "Health", explanation: "Requests health-related access. User consent and runtime permissions are not checked.")
        case "com.apple.developer.homekit": return .init(name: "HomeKit", category: "HomeKit", explanation: "Requests access to home automation capabilities.")
        case "com.apple.developer.pass-type-identifiers", "com.apple.developer.in-app-payments": return .init(name: "Wallet Access", category: "Wallet", explanation: "Declares pass or payment identifiers.")
        case "com.apple.developer.icloud-container-identifiers", "com.apple.developer.icloud-services", "com.apple.developer.ubiquity-container-identifiers", "com.apple.developer.ubiquity-kvstore-identifier", "com.apple.developer.icloud-container-environment": return .init(name: "iCloud Access", category: "iCloud", explanation: "Declares cloud containers, services, or environment.")
        default: return .init(name: key, category: "Other / Unknown", explanation: "ZynSign has no capability-specific interpretation for this key. The raw claim is preserved.")
        }
    }
}

struct EntitlementStudioFinding: Equatable, Identifiable {
    let id: String
    let title: String
    let status: EntitlementStudioStatus
    let message: String
    /// Reuses the diagnostics vocabulary without logging entitlement values.
    var diagnosticCategory: DiagnosticCategory? {
        switch status {
        case .compatible: return nil
        case .blocked: return .invalidInput
        case .warning, .unknown: return .unsupportedInput
        }
    }
}

struct EntitlementStudioRow: Equatable, Identifiable {
    let key: String
    let value: ProvisioningProfileValue
    let profileValue: ProvisioningProfileValue?
    let capability: EntitlementCapability
    let finding: EntitlementStudioFinding
    let searchText: String
    var id: String { key }
}

struct EntitlementStudioAnalysis: Equatable {
    let rows: [EntitlementStudioRow]
    let checks: [EntitlementStudioFinding]
    let teamRelationship: String
    var findings: [EntitlementStudioFinding] { checks + rows.map(\.finding) }
    var status: EntitlementStudioStatus {
        if findings.contains(where: { $0.status == .blocked }) { return .blocked }
        if findings.contains(where: { $0.status != .compatible }) { return .warning }
        return .compatible
    }
    var summary: String {
        switch status {
        case .blocked: return "Detected conflicts — signing should not proceed until reviewed."
        case .warning, .unknown: return "Attention — review the warnings and checks ZynSign could not complete."
        case .compatible: return "No detected conflicts in the implemented checks."
        }
    }
    func count(_ status: EntitlementStudioStatus) -> Int { rows.filter { $0.finding.status == status }.count }
    func filtered(query: String, status: EntitlementStudioStatus?) -> [EntitlementStudioRow] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return rows.filter { (status == nil || $0.finding.status == status) && (query.isEmpty || $0.searchText.contains(query)) }
    }
}

/// Pure, deterministic comparison. No signing mutations and no certificate/key bytes.
/// Profile payloads are compared as declarations: CMS authentication is left to
/// the signing pipeline and explicitly reported as not evaluated here.
enum EntitlementsStudioAnalyzer {
    static func analyze(app: CodeSigningEntitlements?, profile: ProvisioningProfile?,
                        bundleID: BundleIdentifier, certificateTeam: String?, emitDER: Bool,
                        sourceNote: String) -> EntitlementStudioAnalysis {
        var checks: [EntitlementStudioFinding] = []
        func check(_ id: String, _ title: String, _ status: EntitlementStudioStatus, _ message: String) {
            checks.append(.init(id: id, title: title, status: status, message: message))
        }
        check("scope", "Inspection scope", app == nil ? .unknown : .compatible, sourceNote)
        check("authenticity", "Profile authenticity", .warning,
              profile == nil ? "Choose a provisioning profile to compare declared capabilities." : "This is a comparison of parsed declarations. CMS authenticity, certificate membership, validity dates and device eligibility are rechecked by the signing pipeline, not by this inspector.")
        let team: EntitlementStudioFinding
        if let profile, let certificateTeam, let teams = profile.teamIdentifiers, !teams.isEmpty {
            let match = teams.contains(certificateTeam) && (profile.entitlementTeamIdentifier == nil || profile.entitlementTeamIdentifier == certificateTeam)
            team = .init(id: "team", title: "Team consistency", status: match ? .compatible : .blocked,
                         message: match ? "The certificate's declared organizational unit matches the profile's declared team. Certificate membership and trust are not established by this match." : "The certificate's declared team conflicts with the profile. Choose a certificate and profile from the same team.")
        } else {
            team = .init(id: "team", title: "Team consistency", status: .unknown, message: "Select a certificate and profile with team metadata to compare their declared teams.")
        }
        checks.append(team)
        if let profile {
            let outcome = ProvisioningIdentifierCompatibility(profile: profile).outcome(forBundleIdentifier: bundleID)
            let status = identifierStatus(outcome)
            check("bundle", "Bundle ID compatibility", status,
                  status == .compatible ? "The app's bundle ID falls within the profile's declared scope." : status == .blocked ? "The app's bundle ID is outside the profile's scope. Select a profile for this app." : "The profile's bundle ID scope cannot be established from its declared prefix and identifier.")
        } else {
            check("bundle", "Bundle ID compatibility", .unknown, "Select a profile to compare its bundle ID scope.")
        }
        check("encoding", "Signing configuration", .compatible, emitDER ? "DER output is selected. This changes encoding, not the inspected app claims." : "XML output is selected. This changes encoding, not the inspected app claims.")
        check("background", "Background Modes", .unknown, "Background Modes are Info.plist declarations, not code-signing entitlements. They are not inferred or validated here. Nested app extensions are outside this main-executable inspection.")
        let rows = (app?.keys ?? []).compactMap { key -> EntitlementStudioRow? in
            guard !Task.isCancelled, let value = app?[key] else { return nil }
            let capability = EntitlementCapability.mapping(for: key)
            let authorized = profile?.entitlements?[key]
            let comparison = compare(key: key, value: value, profile: profile, bundleID: bundleID)
            let finding = EntitlementStudioFinding(id: key, title: capability.name, status: comparison.0, message: comparison.1)
            return .init(key: key, value: value, profileValue: authorized, capability: capability, finding: finding,
                         searchText: "\(capability.name) \(key) \(capability.category) \(finding.status.rawValue)".lowercased())
        }
        return .init(rows: rows, checks: checks, teamRelationship: team.message)
    }

    private static func identifierStatus(_ outcome: ProvisioningIdentifierCompatibilityOutcome) -> EntitlementStudioStatus {
        switch outcome {
        case .exactMatch, .wildcardMatch: return .compatible
        case .mismatch: return .blocked
        case .indeterminate: return .unknown
        }
    }

    private static func compare(key: String, value: ProvisioningProfileValue, profile: ProvisioningProfile?, bundleID: BundleIdentifier) -> (EntitlementStudioStatus, String) {
        let name = EntitlementCapability.mapping(for: key).name
        guard let profile, let authorized = profile.entitlements else {
            return (.unknown, "\(name) requires a readable profile entitlement allowlist for comparison.")
        }
        if key == "application-identifier" {
            guard case .string(let claim) = value else { return (.unknown, "The application identifier is not a string; it cannot be compared.") }
            let compatibility = ProvisioningIdentifierCompatibility(profile: profile)
            let status = identifierStatus(compatibility.outcome(forApplicationIdentifierValue: claim))
            if let expected = compatibility.expectedApplicationIdentifier(for: bundleID), expected != claim {
                return (.blocked, "This claim does not describe the app under the profile's declared application prefix. Select a matching app and profile; the Studio will not rewrite it.")
            }
            return (status, status == .compatible ? "The application identifier is within the profile's declared scope." : "The application identifier is outside or cannot be compared with the profile's declared scope.")
        }
        if key == "get-task-allow" {
            guard case .boolean(let requested) = value else { return (.unknown, "The debugging claim is not a boolean.") }
            if let allowed = authorized[key], case .boolean(let flag) = allowed {
                if flag == requested { return (.compatible, "The declared debugging values match.") }
                return requested ? (.blocked, "The profile does not allow the requested debugging access.") : (.warning, "The app declines debugging but the profile allows it. This combination is not established by ZynSign's policy.")
            }
            if authorized[key] != nil { return (.unknown, "The profile's debugging claim is not a boolean.") }
            return requested ? (.blocked, "The profile lacks the requested debugging claim.") : (.warning, "The profile has no debugging claim. Absence is not treated as false.")
        }
        if key == "com.apple.developer.team-identifier" {
            guard case .string(let team) = value, let teams = profile.teamIdentifiers, !teams.isEmpty else {
                return (.unknown, "Team metadata is incomplete or has an unsupported type.")
            }
            guard teams.contains(team) else { return (.blocked, "The app's declared team is not among the profile's teams.") }
        }
        // Generic comparison has no wildcard semantics. Do not invent a
        // conflict when a profile's group/domain pattern needs a specialized rule.
        if let allowed = authorized[key], containsWildcard(allowed), allowed != value {
            return (.warning, "\(name) uses a profile wildcard. ZynSign has no capability-specific pattern rule for this combination; review the values.")
        }
        let outcome = ProvisioningEntitlementComparator.compare(requested: value, authorized: authorized[key] ?? value)
        guard authorized[key] != nil else { return (.blocked, "\(name) is absent from the profile allowlist. Choose a profile that declares this capability.") }
        switch outcome {
        case .claimMatchesAuthorization:
            if EntitlementCapability.mapping(for: key).category == "Other / Unknown" {
                return (.unknown, "The declared values match, but ZynSign has no capability-specific interpretation for this unknown key.")
            }
            guard hasKnownValueShape(key: key, value: value) else {
                return (.unknown, "The declared values match, but this capability uses an unsupported value form. Review the value type rather than treating equality as support.")
            }
            return (.compatible, "\(name) matches the profile's declared value under the implemented comparison rules. This is not platform authorization.")
        case .claimNotAuthorized, .claimValueConflicts:
            return (.blocked, "\(name) conflicts with the profile's declared value. Compare both values and select a compatible profile.")
        case .cannotBeEvaluated:
            return (.warning, "\(name) cannot be fully compared: array ordering, subsets or numeric representations are not established by the implemented rules.")
        case .unsupportedByPolicy, .requiresSpecialHandling:
            return (.unknown, "This value type or capability combination has no implemented compatibility rule.")
        }
    }

    /// Recognized names do not make arbitrary matching types meaningful.
    /// This is a structural expectation, not an entitlement authorization table.
    private static func hasKnownValueShape(key: String, value: ProvisioningProfileValue) -> Bool {
        switch key {
        case "aps-environment", "com.apple.developer.team-identifier",
             "com.apple.developer.ubiquity-kvstore-identifier", "com.apple.developer.icloud-container-environment":
            if case .string = value { return true }
        case "com.apple.developer.siri", "com.apple.developer.homekit", "com.apple.developer.healthkit",
             "com.apple.developer.healthkit.background-delivery":
            if case .boolean = value { return true }
        default:
            if case .array(let values) = value {
                return values.allSatisfy { if case .string = $0 { return true }; return false }
            }
        }
        return false
    }

    private static func containsWildcard(_ value: ProvisioningProfileValue) -> Bool {
        switch value {
        case .string(let text): return text.contains("*")
        case .array(let values): return values.contains(where: containsWildcard)
        case .dictionary(let values): return values.values.contains(where: containsWildcard)
        default: return false
        }
    }
}

/// Formatting is separate from analysis. Full values are generated only for
/// visible cards, an opened inspector, or an explicit export, not cached twice.
enum EntitlementStudioValue {
    static func typeName(_ value: ProvisioningProfileValue) -> String {
        switch value {
        case .string: return "String"
        case .boolean: return "Boolean"
        case .integer: return "Integer"
        case .real: return "Real"
        case .data: return "Data"
        case .date: return "Date"
        case .array: return "Array"
        case .dictionary: return "Dictionary"
        }
    }
    static func summary(_ value: ProvisioningProfileValue) -> String {
        switch value {
        case .array(let values): return "\(values.count) items"
        case .dictionary(let values): return "\(values.count) keys"
        default: return String(raw(value).prefix(180))
        }
    }
    static func preview(_ value: ProvisioningProfileValue) -> String {
        switch value {
        case .array(let values):
            return values.prefix(3).map(summary).joined(separator: ", ") + (values.count > 3 ? " … (\(values.count) items)" : "")
        case .dictionary(let values):
            return values.keys.sorted().prefix(3).joined(separator: ", ") + " (\(values.count) keys)"
        default: return summary(value)
        }
    }
    static func raw(_ value: ProvisioningProfileValue) -> String {
        switch value {
        case .string(let text): return String(reflecting: text)
        case .boolean(let flag): return flag ? "true" : "false"
        case .integer(let number): return String(number)
        case .real(let number): return String(number)
        case .data(let data): return "<Data: \(data.count) bytes; binary content omitted>"
        case .date(let date): return ISO8601DateFormatter().string(from: date)
        case .array(let values): return "[\n" + values.map(raw).joined(separator: ",\n") + "\n]"
        case .dictionary(let values): return "{\n" + values.keys.sorted().map { "\(String(reflecting: $0)): \(raw(values[$0]!))" }.joined(separator: ",\n") + "\n}"
        }
    }
}
