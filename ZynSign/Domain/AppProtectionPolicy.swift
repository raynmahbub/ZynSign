import Foundation

/// How one library application is guarded inside ZynSign.
///
/// Protection is an interface decision, not encryption: protected records
/// stay in the library store exactly like any other record, but the
/// interface hides them, or asks for authentication before showing them.
/// Nothing here carries biometric state or credentials — the authentication
/// boundary owns those at the moment it asks.
struct AppProtectionPolicy: Equatable, Hashable, Codable, Sendable {

    /// Whether the application requires authentication before its detail
    /// view, signing, or inspection can open.
    var requiresUnlock: Bool

    /// Whether the application is concealed from the library list while the
    /// vault is closed. A concealed application also requires unlock: hiding
    /// a record someone could then open freely would protect nothing.
    var concealed: Bool

    /// When the record was last modified.
    var updatedAt: Date

    /// The unguarded default.
    static let none = AppProtectionPolicy(requiresUnlock: false, concealed: false, updatedAt: Date())

    init(requiresUnlock: Bool, concealed: Bool, updatedAt: Date = Date()) {
        self.requiresUnlock = requiresUnlock
        // Concealment implies unlock: a hidden card that opens freely is not
        // hidden in any meaningful sense.
        self.requiresUnlock = requiresUnlock || concealed
        self.concealed = concealed
        self.updatedAt = updatedAt
    }

    /// Whether the policy guards the record at all.
    var isActive: Bool { requiresUnlock || concealed }
}

/// The vault state the interface renders from.
enum ProtectionVaultState: Equatable, Hashable, Sendable {
    /// The vault is closed: concealed records are hidden and locked records
    /// demand authentication.
    case closed
    /// The vault is open for this session: records show normally until the
    /// vault closes again.
    case open
    /// The device offers no biometric or passcode capability, so the vault
    /// cannot guard anything and says so instead of pretending.
    case unavailable
}

/// The per-record decisions a library listing applies under a vault state.
struct AppProtectionVisibility: Equatable, Hashable, Sendable {
    /// Whether the record appears in listings at all.
    let visible: Bool
    /// Whether opening the record demands authentication right now.
    let demandsUnlock: Bool

    /// The visibility one record receives.
    static func visibility(
        for policy: AppProtectionPolicy?,
        vault: ProtectionVaultState
    ) -> AppProtectionVisibility {
        let active = policy?.isActive ?? false
        switch vault {
        case .unavailable:
            // An unavailable vault cannot guard: show everything, demand
            // nothing, and let the settings screen explain.
            return AppProtectionVisibility(visible: true, demandsUnlock: false)
        case .open:
            return AppProtectionVisibility(visible: true, demandsUnlock: false)
        case .closed:
            guard let policy, active else {
                return AppProtectionVisibility(visible: true, demandsUnlock: false)
            }
            if policy.concealed {
                return AppProtectionVisibility(visible: false, demandsUnlock: true)
            }
            return AppProtectionVisibility(visible: true, demandsUnlock: true)
        }
    }
}
