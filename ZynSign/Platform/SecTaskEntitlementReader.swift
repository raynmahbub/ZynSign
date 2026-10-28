import Foundation
import Security

/// Reads the entitlements of the running process from its own code signature.
///
/// This is the only implementation that talks to Security services. It answers
/// with `ProcessEntitlements.unmeasured` — never with a set of `false` answers —
/// whenever the signature cannot be read: a SwiftUI preview, a simulator
/// runtime that does not expose the task, or any environment where
/// `SecTaskCreateFromSelf` returns nothing. That distinction is the whole point
/// of the type: "this build was not granted the entitlement" and "this build's
/// signature could not be inspected" lead a person to different actions, and
/// the screen says which one it means.
///
/// Nothing here writes, signs, or caches. The read happens once, when the
/// composition root builds the environment, and the result is a value.
struct SecTaskEntitlementReader: ProcessEntitlementReading {

    func read() -> ProcessEntitlements {
        // The task's type is not nameable from Swift on iOS: the Security
        // functions are imported, the `SecTask` type is not. So it is only ever
        // held by inference and passed straight back to Security — never
        // annotated, never stored.
        guard let task = SecTaskCreateFromSelf(nil) else { return .unmeasured }

        var granted: Set<String> = []
        var applicationIdentifier: String?
        var teamIdentifier: String?
        for key in ProcessEntitlements.probedKeys {
            guard let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil) else {
                continue
            }
            granted.insert(key)
            switch key {
            case ProcessEntitlements.applicationIdentifierKey:
                applicationIdentifier = value as? String
            case ProcessEntitlements.teamIdentifierKey:
                teamIdentifier = value as? String
            default:
                break
            }
        }

        // A signature that answers nothing at all is a signature this build
        // could not read — on a simulator every one of these comes back empty
        // even for a fully entitled app, so an empty answer is reported as
        // "not measured" rather than "nothing granted".
        guard !granted.isEmpty else { return .unmeasured }

        return ProcessEntitlements(
            isMeasured: true,
            grantedKeys: granted,
            applicationIdentifier: applicationIdentifier,
            teamIdentifier: teamIdentifier
        )
    }
}
