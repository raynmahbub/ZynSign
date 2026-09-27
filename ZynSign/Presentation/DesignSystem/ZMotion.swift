import SwiftUI

/// The animations ZynSign's own transitions use, chosen once for the
/// user's motion settings.
///
/// Every screen that animates a state change asks `ZMotion` rather than
/// naming a curve, so the same change costs the same everywhere and the
/// system's Reduce Motion setting and the animation preference are
/// honoured in one place. The curves are short and non-repeating: a
/// library of a thousand rows animates an insertion with one cheap
/// opacity fade, never a spring per row.
struct ZMotion {

    /// Whether ZynSign's own transitions animate at all.
    let permitsAnimation: Bool

    init(permitsAnimation: Bool) {
        self.permitsAnimation = permitsAnimation
    }

    /// Motion for the system's Reduce Motion setting and the user's
    /// animation preference.
    init(reduceMotion: Bool, preference: AnimationPreference) {
        self.permitsAnimation = preference.permitsAnimation(systemReduceMotion: reduceMotion)
    }

    /// Motion that follows the system setting alone.
    static func system(reduceMotion: Bool) -> ZMotion {
        ZMotion(permitsAnimation: !reduceMotion)
    }

    /// A short fade for content replacing content in place. `nil` when
    /// animation is off, which SwiftUI treats as an immediate change.
    var quick: Animation? {
        permitsAnimation ? .easeOut(duration: 0.15) : nil
    }

    /// The default for a state change the user caused.
    var standard: Animation? {
        permitsAnimation ? .easeInOut(duration: 0.22) : nil
    }

    /// A settle for something arriving: a toast, a sheet's content.
    var arrive: Animation? {
        permitsAnimation ? .spring(response: 0.35, dampingFraction: 0.85) : nil
    }

    /// The transition for content appearing in a list. A fade only: no
    /// offset, so a long list never lays out twice per row.
    var fade: AnyTransition {
        permitsAnimation ? .opacity : .identity
    }

    /// Runs `body` with the standard animation, or without one.
    func animate<Result>(_ animation: Animation?? = nil, _ body: () throws -> Result) rethrows -> Result {
        let resolved = animation ?? standard
        if let resolved {
            return try withAnimation(resolved, body)
        }
        return try body()
    }
}

private struct ZMotionKey: EnvironmentKey {
    static let defaultValue = ZMotion(permitsAnimation: true)
}

extension EnvironmentValues {

    /// The motion the shell chose for the user's settings. Views read it
    /// with `@Environment(\.zMotion)`.
    var zMotion: ZMotion {
        get { self[ZMotionKey.self] }
        set { self[ZMotionKey.self] = newValue }
    }
}
