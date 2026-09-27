import Foundation

/// An action ZynSign will not perform until the user proves they are the
/// device owner.
///
/// The cases are the actions that either change something irreversibly or
/// reach signing material. Each carries the sentence the system shows when it
/// asks, so the reason a user reads is the reason the action exists.
enum SensitiveAction: String, CaseIterable, Sendable {
    case sign
    case resetLibrary
    case clearStorage
    case exportDiagnostics
    case changeSecuritySettings
    case removeIdentity

    /// The action's name, for the Security Center's list.
    var title: String {
        switch self {
        case .sign: return "Sign an application"
        case .resetLibrary: return "Reset the library"
        case .clearStorage: return "Clear stored files"
        case .exportDiagnostics: return "Export a diagnostic report"
        case .changeSecuritySettings: return "Change security settings"
        case .removeIdentity: return "Remove a signing identity"
        }
    }

    /// The sentence the system shows when it asks.
    var authenticationReason: String {
        switch self {
        case .sign: return "Authenticate to sign with your signing identity."
        case .resetLibrary: return "Authenticate to remove everything in ZynSign's library."
        case .clearStorage: return "Authenticate to remove files ZynSign keeps."
        case .exportDiagnostics: return "Authenticate to export a diagnostic report."
        case .changeSecuritySettings: return "Authenticate to change ZynSign's security settings."
        case .removeIdentity: return "Authenticate to remove a signing identity's registration. The key itself stays in the Keychain."
        }
    }
}

/// ZynSign's own lock.
///
/// The controller owns exactly one question — is the application locked right
/// now — and the two things that answer it: an explicit authentication, and
/// the passage of time. It reads the user's security preferences on demand
/// rather than holding a copy, so a change in Settings takes effect without
/// anything having to be kept in step.
///
/// What it does not do is hold anything worth stealing. It stores no
/// credential, no key, and no certificate: authentication happens through the
/// `BiometricAuthenticating` port, which asks the system and returns an
/// answer. Private key material stays in the Keychain, is never readable
/// through this type, and is never exposed by Settings.
@MainActor
final class AppLockController: ObservableObject {

    /// Whether the application is currently locked.
    @Published private(set) var isLocked = false

    /// What this device can offer, as last reported.
    @Published private(set) var availability: BiometricAvailability

    /// When the user last authenticated, if they have this session.
    @Published private(set) var lastAuthentication: Date?

    /// The outcome of the last attempt, for the Security Center to show.
    @Published private(set) var lastOutcome: AuthenticationOutcome?

    private let authenticator: any BiometricAuthenticating
    private let preferencesProvider: @MainActor () -> ZynSignPreferences

    init(
        authenticator: any BiometricAuthenticating,
        preferences: @escaping @MainActor () -> ZynSignPreferences
    ) {
        self.authenticator = authenticator
        self.preferencesProvider = preferences
        self.availability = authenticator.availability()
    }

    /// The security preferences as they stand right now.
    var preferences: SecurityPreferences { preferencesProvider().security }

    /// Whether Face ID or Touch ID protection is switched on *and* usable.
    ///
    /// A preference to lock on a device that cannot authenticate is not
    /// enforced, and the Security Center says so rather than showing a switch
    /// that does nothing.
    var isProtectionEnabled: Bool {
        preferences.biometricLockEnabled && availability.isAvailable
    }

    /// Re-reads what the device can offer.
    func refreshAvailability() {
        availability = authenticator.availability()
    }

    /// Locks the application.
    func lock() {
        isLocked = true
    }

    /// Locks only when protection is switched on and usable.
    func lockIfProtectionEnabled() {
        if isProtectionEnabled { isLocked = true }
    }

    /// Asks the user to authenticate for `action`.
    @discardableResult
    func authenticate(action: SensitiveAction) async -> AuthenticationOutcome {
        let outcome = await authenticator.authenticate(reason: action.authenticationReason)
        lastOutcome = outcome
        if outcome.isAuthenticated {
            lastAuthentication = Date()
        }
        return outcome
    }

    /// Asks the user to unlock the application.
    ///
    /// Unlocking is its own reason, not a sensitive action: a locked ZynSign
    /// is unlocked by the attempt that needs it, and the sentence the user
    /// reads says exactly that.
    @discardableResult
    func unlock() async -> AuthenticationOutcome {
        let outcome = await authenticator.authenticate(reason: Self.unlockReason)
        lastOutcome = outcome
        if outcome.isAuthenticated {
            isLocked = false
            lastAuthentication = Date()
        }
        return outcome
    }

    /// Whether `action` may proceed.
    ///
    /// A locked application is unlocked by the attempt itself: the user
    /// authenticates once and continues. An unlocked application asks again
    /// only when the user asked for that — requiring authentication before
    /// sensitive actions is a preference, not a default behaviour.
    @discardableResult
    func authorize(_ action: SensitiveAction) async -> AuthenticationOutcome {
        if isLocked { return await unlock() }
        guard preferences.requireAuthenticationForSensitiveActions else { return .authenticated }
        return await authenticate(action: action)
    }

    /// The sentence the system shows when ZynSign asks to be unlocked.
    private static let unlockReason = "Unlock ZynSign."

    /// Whether the unlocked session has lapsed under the timeout.
    func hasSessionLapsed(now: Date = Date()) -> Bool {
        guard let lastAuthentication else { return true }
        guard let seconds = preferences.sessionTimeout.seconds else { return false }
        return now.timeIntervalSince(lastAuthentication) >= seconds
    }

    /// Locks when protection is on and the session has lapsed. Called on a
    /// timer by the shell; it never asks the user anything.
    func evaluateInactivity(now: Date = Date()) {
        guard isProtectionEnabled, !isLocked, hasSessionLapsed(now: now) else { return }
        lock()
    }

    /// Whether a sensitive value must be hidden from the interface right now.
    ///
    /// This is the single place the visibility rule lives, so the Certificates
    /// list, the Profiles list, and the Security Center cannot disagree about
    /// what "masked" means.
    func shouldHideSensitiveValues() -> Bool {
        let security = preferences
        switch security.sensitiveDataVisibility {
        case .hidden:
            return true
        case .masked:
            return security.hideSensitiveInformationWhenLocked && isLocked
        case .visible:
            return false
        }
    }
}
