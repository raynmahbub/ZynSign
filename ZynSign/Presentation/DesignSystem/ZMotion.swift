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

    // MARK: Presets — the only curves ZynSign animates with

    /// The curves, defined once. Call sites never name a duration.
    enum Curve {
        /// 200 ms ease-out: content replacing content, a row toggling, a chip.
        static let fast: Animation = .easeOut(duration: 0.20)
        /// 300 ms ease-in-out: a state change the user caused.
        static let standard: Animation = .easeInOut(duration: 0.30)
        /// 450 ms spring: the ribbon drawing itself, a success tick, a ring filling.
        static let relaxed: Animation = .spring(response: 0.45, dampingFraction: 0.82)
        /// Interactive spring: things that follow a finger or settle after a tap.
        static let interactive: Animation = .spring(response: 0.35, dampingFraction: 0.80)
    }

    /// `nil` when animation is off, which SwiftUI treats as an immediate change.
    var fast: Animation? { permitsAnimation ? Curve.fast : nil }
    var standard: Animation? { permitsAnimation ? Curve.standard : nil }
    var relaxed: Animation? { permitsAnimation ? Curve.relaxed : nil }
    var interactive: Animation? { permitsAnimation ? Curve.interactive : nil }

    /// Older names, kept so existing call sites read the same.
    var quick: Animation? { fast }
    var arrive: Animation? { interactive }
    var hero: Animation? { relaxed }

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

// MARK: - Static access (call sites without an environment)

extension ZMotion {

    private static let lock = NSLock()
    private static var storedPermitsAnimation = true

    /// The policy the shell resolved — the same value it puts in the
    /// environment. `RootView` sets it; view models, static helpers and
    /// one-line `withAnimation` calls read it through the presets below.
    static var permitsAnimationGlobally: Bool {
        get { lock.withLock { storedPermitsAnimation } }
        set { lock.withLock { storedPermitsAnimation = newValue } }
    }

    /// 200 ms ease-out, or no animation.
    static var fast: Animation? { permitsAnimationGlobally ? Curve.fast : nil }
    /// 300 ms ease-in-out, or no animation.
    static var standard: Animation? { permitsAnimationGlobally ? Curve.standard : nil }
    /// 450 ms spring, or no animation.
    static var relaxed: Animation? { permitsAnimationGlobally ? Curve.relaxed : nil }
    /// Interactive spring, or no animation.
    static var interactive: Animation? { permitsAnimationGlobally ? Curve.interactive : nil }
}
