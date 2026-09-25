import Foundation

/// One of the things Reset & Recovery can restore.
///
/// The kind is named in the application layer rather than in the view that
/// offers it, because which action needs authentication is a security
/// decision rather than a presentation one: `SensitiveAction.forRecovery(_:)`
/// is the single place that decides, and it is the same answer for every
/// screen that could ever offer a recovery action.
///
/// The order is deliberate: the safe actions first, the one destructive reset
/// last, so a screen that lists them in order cannot put the destructive one
/// where a user reaches for it by habit.
enum RecoveryActionKind: String, CaseIterable, Sendable, Identifiable {

    /// Every setting returns to its shipped default.
    case preferences

    /// Derived data the system may reclaim at any time: working copies,
    /// staging files, and leftovers from interrupted operations.
    case workspace

    /// The library's own records, re-read from disk.
    case libraryIndex

    /// Every imported application and its package file.
    case library

    var id: String { rawValue }

    /// Whether the action deletes something the user put into ZynSign.
    ///
    /// Exactly one action does. It is the reason Reset & Recovery is the only
    /// settings area marked destructive, and it is the reason that action
    /// asks twice.
    var isDestructive: Bool { self == .library }

    /// One sentence describing what the action does, written for a
    /// confirmation.
    var confirmationMessage: String {
        switch self {
        case .preferences:
            return "Every setting returns to its shipped default. Your library, certificates, profiles, and the record of finished onboarding are untouched."
        case .workspace:
            return "Staged imports and working copies are removed. Exported reports are kept, and imported applications are never touched."
        case .libraryIndex:
            return "ZynSign re-reads its library and removes artifacts no record refers to. No imported application is removed by this."
        case .library:
            return "Every imported application and its package file will be permanently deleted. This cannot be undone."
        }
    }
}

extension SensitiveAction {

    /// The authentication an action of this kind needs, or `nil` when the
    /// user did not ask for it to be guarded.
    ///
    /// Preferences are configuration: resetting them costs the user nothing
    /// they built, so asking for a fingerprint to restore defaults would be
    /// theatre rather than protection. Everything that removes a file ZynSign
    /// holds is guarded, and the library reset is guarded as what it is.
    static func forRecovery(_ kind: RecoveryActionKind) -> SensitiveAction? {
        switch kind {
        case .preferences: return nil
        case .workspace, .libraryIndex: return .clearStorage
        case .library: return .resetLibrary
        }
    }
}
