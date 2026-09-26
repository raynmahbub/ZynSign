import Foundation
#if os(iOS)
import LocalAuthentication
#endif

/// The LocalAuthentication implementation of `BiometricAuthenticating`.
///
/// Face ID and Touch ID are asked for through the system's own policy, with a
/// reason the user reads before deciding. When no biometric is enrolled the
/// implementation falls back to the device passcode rather than refusing, so
/// "require authentication" still means something on a device without
/// biometrics; when neither is available it reports `.unavailable` and the
/// Security Center says so instead of offering a switch that cannot work.
///
/// Nothing is cached, stored, or remembered here: no authentication context
/// survives a call, and no outcome is written anywhere the user cannot see.
struct LocalAuthenticationBiometricAuthenticator: BiometricAuthenticating {

    init() {}

    func availability() -> BiometricAvailability {
        #if os(iOS)
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            // Distinguish "no biometric enrolled" from "no passcode set": the
            // remedy is different, and the user should be told which one it is.
            if let laError = error as? LAError, laError.code == .passcodeNotSet {
                return BiometricAvailability(
                    kind: .none,
                    isAvailable: false,
                    unavailableReason: "Set a passcode on this device to use Face ID or Touch ID."
                )
            }
            return BiometricAvailability(
                kind: .none,
                isAvailable: false,
                unavailableReason: "Face ID or Touch ID is not set up on this device."
            )
        }
        switch context.biometryType {
        case .faceID:
            return BiometricAvailability(kind: .faceID, isAvailable: true, unavailableReason: "")
        case .touchID:
            return BiometricAvailability(kind: .touchID, isAvailable: true, unavailableReason: "")
        case .none:
            return BiometricAvailability(
                kind: .none,
                isAvailable: false,
                unavailableReason: "Face ID or Touch ID is not set up on this device."
            )
        @unknown default:
            return BiometricAvailability(
                kind: .none,
                isAvailable: false,
                unavailableReason: "Face ID or Touch ID is not set up on this device."
            )
        }
        #else
        return BiometricAvailability(
            kind: .none,
            isAvailable: false,
            unavailableReason: "Face ID and Touch ID are available on iPhone and iPad."
        )
        #endif
    }

    func authenticate(reason: String) async -> AuthenticationOutcome {
        #if os(iOS)
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        let policy: LAPolicy = availability().isAvailable
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication
        do {
            let succeeded = try await context.evaluatePolicy(policy, localizedReason: reason)
            return succeeded ? .authenticated : .failed
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel:
                return .cancelled
            case .biometryNotAvailable, .biometryNotEnrolled, .biometryLockout, .passcodeNotSet:
                return .unavailable
            default:
                return .failed
            }
        } catch {
            return .failed
        }
        #else
        return .unavailable
        #endif
    }
}

/// The authentication mechanism for a target that has none.
///
/// ZynSign reports authentication as unavailable rather than pretending a
/// check happened, so a security preference can never appear to be enforced
/// where nothing enforces it.
struct UnavailableBiometricAuthenticator: BiometricAuthenticating {
    init() {}

    func availability() -> BiometricAvailability {
        BiometricAvailability(
            kind: .none,
            isAvailable: false,
            unavailableReason: "Authentication is not available on this device."
        )
    }

    func authenticate(reason: String) async -> AuthenticationOutcome {
        .unavailable
    }
}
