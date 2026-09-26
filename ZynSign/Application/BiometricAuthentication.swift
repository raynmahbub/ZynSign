import Foundation

/// What biometric authentication this device can offer.
struct BiometricAvailability: Equatable, Sendable {

    /// Which biometric the device offers.
    enum Kind: String, Sendable {
        case faceID
        case touchID
        case none

        /// The name Apple's interfaces use.
        var displayName: String {
            switch self {
            case .faceID: return "Face ID"
            case .touchID: return "Touch ID"
            case .none: return "None"
            }
        }
    }

    /// The biometric the device offers, or `.none`.
    var kind: Kind

    /// Whether authentication can actually be asked for right now.
    var isAvailable: Bool

    /// Why it cannot, in one presentation-safe sentence. Empty when it can.
    var unavailableReason: String

    /// The status the Security Center shows.
    var statusText: String {
        isAvailable ? kind.displayName : "Not available"
    }
}

/// The outcome of asking the user to prove they are the device owner.
///
/// ZynSign learns only that the attempt succeeded, was cancelled, failed, or
/// could not be made. It never learns why beyond that, and it never receives
/// anything from the device's authentication system except the answer.
enum AuthenticationOutcome: Equatable, Sendable {
    case authenticated
    case cancelled
    case failed
    case unavailable

    /// Whether the user proved who they are.
    var isAuthenticated: Bool { self == .authenticated }

    /// One presentation-safe sentence.
    var message: String {
        switch self {
        case .authenticated: return "Authenticated."
        case .cancelled: return "Authentication was cancelled."
        case .failed: return "Authentication did not succeed."
        case .unavailable: return "Authentication is not available on this device."
        }
    }
}

/// The boundary through which ZynSign asks the user to authenticate.
///
/// The port is deliberately narrow: what is available, and one attempt. It
/// names no framework, exposes no key, and returns no credential. The
/// platform implementation owns LocalAuthentication and nothing else does.
protocol BiometricAuthenticating: Sendable {

    /// What this device can offer right now.
    func availability() -> BiometricAvailability

    /// Asks the user to authenticate, with `reason` shown by the system.
    func authenticate(reason: String) async -> AuthenticationOutcome
}
