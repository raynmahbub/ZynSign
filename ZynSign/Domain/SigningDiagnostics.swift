import Foundation

/// A local, read-only pre-sign observation. None of these levels is a verdict
/// from Apple: even a successful check describes only evidence ZynSign read.
enum SigningDiagnosticSeverity: String, Codable, CaseIterable, Hashable {
    case success, info, warning, error, unsupported
}

enum SigningDiagnosticArea: String, Codable, CaseIterable, Hashable {
    case package, metadata, executable, bundleIdentifier, teamIdentifier
    case certificate, profile, entitlements, nestedCode, existingSignature, signingOptions

    var title: String {
        switch self {
        case .package: return "Package"
        case .metadata: return "Metadata"
        case .executable: return "Executable"
        case .bundleIdentifier: return "Bundle ID"
        case .teamIdentifier: return "Team ID"
        case .certificate: return "Certificate"
        case .profile: return "Profile"
        case .entitlements: return "Entitlements"
        case .nestedCode: return "Nested Code"
        case .existingSignature: return "Existing Signature"
        case .signingOptions: return "Options"
        }
    }

    /// The scope of the actual local check, not a platform-acceptance claim.
    var verificationScope: String {
        switch self {
        case .package: return "ZynSign checked that the library package could be read and inspected its archive entry table."
        case .metadata: return "ZynSign read the bundle's information file within its read limit and checked the declarations it supports."
        case .executable: return "ZynSign checked the declared executable's entry and inspected its Mach-O structure where possible."
        case .bundleIdentifier: return "ZynSign compared the application's declared identifier with the authenticated profile's identifier scope."
        case .teamIdentifier: return "ZynSign compared the profile's team declarations and the certificate's structured team attribute, when available."
        case .certificate: return "ZynSign read signing-identity metadata and compared the certificate with the authenticated profile. It did not access the private key."
        case .profile: return "ZynSign checked the profile container signature, parsed the authenticated payload, and evaluated its declared validity and policy fields."
        case .entitlements: return "ZynSign compared the exact claims to be embedded with the authenticated profile's allowlist using its implemented comparison rules."
        case .nestedCode: return "ZynSign inspected supported code locations, bounded binary reads, and the proposed nested signing order without extracting the package."
        case .existingSignature: return "ZynSign inspected code-signature structure on discovered Mach-O images. It did not establish signature trust."
        case .signingOptions: return "ZynSign checked only the options this signing screen actually passes to the pipeline."
        }
    }
}

/// Stable codes are deliberately free of paths, names, team IDs, certificate
/// fingerprints, entitlement keys/values, profile bytes and device IDs. Only
/// these codes (not issue text or evidence objects) are kept in scan history.
enum SigningDiagnosticCode: String, Codable, CaseIterable, Hashable {
    case packageMissing, packageChanged, packageUnreadable, packageInvalid
    case metadataUnavailable, metadataChanged, executableMissing, executableInvalid
    case bundleMismatch, bundleUnverified, teamMismatch, teamUnverified
    case certificateMissing, certificateUnavailable, certificateExpired, certificateNotYetValid
    case certificateExpiring, certificateAlgorithmUnsupported, certificateProfileMismatch, certificateUnverified
    case profileMissing, profileInvalid, profileUnsupported, profileUnverified
    case profileExpired, profileNotYetValid, profileExpiring, profilePolicyMismatch
    case platformMismatch, platformUnverified, deviceMismatch, deviceUnverified
    case entitlementsInvalid, entitlementsMismatch, entitlementsUnverified
    case nestedInvalid, nestedUnsupported, nestedUnverified
    case signaturePresent, signatureMalformed, signatureUnverified
    case legacyEntitlements, derUnavailable

    /// Human-readable names for redacted historical codes. Historical scans
    /// retain only the code, not the text of an issue or any input value.
    var displayName: String {
        var spaced = ""
        for character in rawValue {
            if character.isUppercase { spaced.append(" ") }
            spaced.append(character)
        }
        return spaced.prefix(1).uppercased() + String(spaced.dropFirst())
    }
}

/// One actionable explanation. All text is written from fixed, redacted
/// templates; untrusted archive/profile/Keychain error text never enters it.
struct SigningDiagnostic: Identifiable, Equatable {
    let id: SigningDiagnosticCode
    let area: SigningDiagnosticArea
    let severity: SigningDiagnosticSeverity
    let title: String
    let explanation: String
    let technicalDetails: String
    let suggestedAction: String

    var whatWasVerified: String { area.verificationScope }

    static let platformBoundary = "These are local input checks, not a signed-output or device test. External macOS codesign validation has rejected this build's application resource seal; DER and other iOS-format requirements are still outstanding. iOS alone decides trust, provisioning, signature acceptance and installation. See the external-validation record for known limitations."
}

enum SigningCheckState: String, Codable, Hashable {
    case passed, attention, blocked, notChecked, unsupported

    var title: String {
        switch self {
        case .passed: return "Checked"
        case .attention: return "Attention"
        case .blocked: return "Blocked"
        case .notChecked: return "Not checked"
        case .unsupported: return "Unsupported"
        }
    }
}

struct SigningDiagnosticCheck: Equatable, Identifiable {
    let area: SigningDiagnosticArea
    let state: SigningCheckState
    var id: SigningDiagnosticArea { area }
}

enum SigningReadiness: String, Codable, Equatable {
    case ready, attention, blocked

    var title: String {
        switch self {
        case .ready: return "Ready to sign"
        case .attention: return "Needs attention"
        case .blocked: return "Blocked"
        }
    }
}

/// A score is the share of these eleven implemented checks that passed (an
/// attention state gets half credit). Unchecked and unsupported are NEVER
/// scored as passes. 100 means these checks passed, not that iOS will accept
/// the result. A blocked condition always wins over the numerical score.
struct SigningDiagnosticsReport: Equatable {
    let recordID: ApplicationRecordIdentifier
    let analyzedAt: Date
    let checks: [SigningDiagnosticCheck]
    let issues: [SigningDiagnostic]

    var score: Int {
        guard !checks.isEmpty else { return 0 }
        let points = checks.reduce(0) { sum, check in
            switch check.state {
            case .passed: return sum + 2
            case .attention: return sum + 1
            case .blocked, .notChecked, .unsupported: return sum
            }
        }
        return (points * 100) / (checks.count * 2)
    }

    var status: SigningReadiness {
        if checks.isEmpty || checks.contains(where: { $0.state == .blocked || $0.state == .unsupported }) {
            return .blocked
        }
        if checks.contains(where: { $0.state != .passed }) { return .attention }
        return .ready
    }

    var readyToSign: Bool { status == .ready }
    var warningCount: Int { issues.filter { $0.severity == .warning }.count }
    var errorCount: Int { issues.filter { $0.severity == .error }.count }
    var unsupportedCount: Int { issues.filter { $0.severity == .unsupported }.count }

    func state(for area: SigningDiagnosticArea) -> SigningCheckState {
        checks.first(where: { $0.area == area })?.state ?? .notChecked
    }
}

/// A bounded, non-sensitive history entry. No report text, selected identity,
/// profile, package fingerprint, entitlement, path or signing input is stored.
struct SigningDiagnosticSnapshot: Codable, Equatable, Identifiable {
    let scanID: UUID // opaque, unique even with an injected or low-resolution clock
    let recordID: String // opaque library UUID, never a bundle identifier
    let analyzedAt: Date
    let score: Int
    let status: SigningReadiness
    let issueCodes: [SigningDiagnosticCode]
    let warningCount: Int
    let errorCount: Int

    var id: UUID { scanID }

    init(report: SigningDiagnosticsReport) {
        scanID = UUID()
        recordID = report.recordID.rawValue
        analyzedAt = report.analyzedAt
        score = report.score
        status = report.status
        issueCodes = report.issues.map(\.id)
        warningCount = report.warningCount
        errorCount = report.errorCount
    }

    /// Compare codes, never details or identities. A repeated scan with the
    /// same observations need not consume another history slot.
    func changes(since previous: SigningDiagnosticSnapshot?) -> SigningDiagnosticChanges? {
        guard let previous else { return nil }
        let before = Set(previous.issueCodes)
        let after = Set(issueCodes)
        return SigningDiagnosticChanges(
            added: after.subtracting(before).sorted { $0.rawValue < $1.rawValue },
            resolved: before.subtracting(after).sorted { $0.rawValue < $1.rawValue }
        )
    }
}

struct SigningDiagnosticChanges: Equatable {
    let added: [SigningDiagnosticCode]
    let resolved: [SigningDiagnosticCode]
    var isEmpty: Bool { added.isEmpty && resolved.isEmpty }
}
