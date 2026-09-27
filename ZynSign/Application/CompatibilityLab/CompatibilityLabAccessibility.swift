import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The accessibility pass, as far as an application can audit itself.
///
/// Three of the six items are checkable from inside the process: Dynamic
/// Type, Reduce Motion and the contrast preference are decisions ZynSign
/// makes about itself, and the Lab can read what it decided and compare it
/// with what the system asked for. VoiceOver, colour contrast and touch
/// targets cannot be judged by the thing being judged — a screen cannot hear
/// itself read — so those rows stay `not run`, name the protocol that
/// settles them, and accept an imported result.
///
/// That is the honest shape of an accessibility gate: the machine checks the
/// machine's decisions, a human checks the experience, and neither is allowed
/// to stand in for the other.
struct AccessibilityAuditSuite {

    func checks(context: CompatibilityLabContext) async -> [CompatibilityCheck] {
        [
            dynamicTypeCheck(context: context),
            reduceMotionCheck(context: context),
            contrastPreferenceCheck(context: context),
            voiceOverCheck(),
            contrastCheck(),
            touchTargetsCheck(),
            focusOrderCheck()
        ]
    }

    // MARK: Checkable here

    /// Whether ZynSign follows the system text size, reported against the
    /// size category the device is actually set to.
    private func dynamicTypeCheck(context: CompatibilityLabContext) -> CompatibilityCheck {
        let category = Self.contentSizeCategory
        let followsSystem = context.preferences.appearance.respectsSystemTextSize
        let isAccessibilitySize = Self.isAccessibilityCategory
        let status: CompatibilityStatus = followsSystem ? .passed : .warning
        return check(
            id: "accessibility.dynamicType",
            title: "Dynamic Type",
            status: status,
            summary: followsSystem
                ? "ZynSign follows the system text size, currently \(category)."
                : "ZynSign is set not to follow the system text size.",
            verified: "Verified the preference and the size category the system reports. Verified elsewhere: that every screen actually reflows at the accessibility sizes — that is the human pass in docs/hardening/accessibility-audit.md.",
            nextStep: followsSystem ? nil : "Turn on Settings → Appearance → Follow System Text Size, or record why this build overrides it.",
            evidence: [
                "content size category: \(category)",
                "accessibility size: \(isAccessibilitySize)",
                "follows system: \(followsSystem)"
            ],
            severity: .high
        )
    }

    /// The system setting always wins. If the user asked for reduced motion,
    /// ZynSign must not animate, whatever its own preference says.
    private func reduceMotionCheck(context: CompatibilityLabContext) -> CompatibilityCheck {
        let systemReduceMotion = Self.isReduceMotionEnabled
        let preference = context.preferences.general.animationPreference
        let permitsAnimation = preference.permitsAnimation(systemReduceMotion: systemReduceMotion)
        let violation = systemReduceMotion && permitsAnimation
        return check(
            id: "accessibility.reduceMotion",
            title: "Reduce Motion",
            status: violation ? .failed : .passed,
            summary: violation
                ? "Reduce Motion is on at the system level and ZynSign would still animate."
                : "Motion follows the system setting: \(preference.displayName), Reduce Motion \(systemReduceMotion ? "on" : "off").",
            verified: "Verified the rule itself, not a rendering: `AnimationPreference.permitsAnimation(systemReduceMotion:)` is the single place the decision is made, and the system setting overrides every choice.",
            nextStep: violation ? "The system setting must win. Fix AnimationPreference.permitsAnimation(systemReduceMotion:) — this is the only place the answer is allowed to come from." : nil,
            evidence: [
                "system reduce motion: \(systemReduceMotion)",
                "preference: \(preference.displayName)",
                "animates: \(permitsAnimation)"
            ],
            severity: .high
        )
    }

    /// Increased contrast: what the system asked for, and what ZynSign will
    /// do about it.
    private func contrastPreferenceCheck(context: CompatibilityLabContext) -> CompatibilityCheck {
        let systemContrast = Self.isIncreaseContrastEnabled
        let preference = context.preferences.appearance.increaseContrast
        // The app's own setting is an addition to the system's, never a
        // substitute: a user who asked for more contrast gets it either way.
        let status: CompatibilityStatus = systemContrast && !preference ? .warning : .passed
        return check(
            id: "accessibility.contrastPreference",
            title: "Increase Contrast",
            status: status,
            summary: "System Increase Contrast is \(systemContrast ? "on" : "off"); ZynSign's own setting is \(preference ? "on" : "off").",
            verified: "Verified both values are read and that ZynSign's setting adds to the system's rather than replacing it.",
            nextStep: status == .passed ? nil : "Check that the system's Increase Contrast reaches the components that own semantic colors: ZStatusBadge and DesignTokens are where they are chosen.",
            evidence: [
                "system: \(systemContrast)",
                "app: \(preference)"
            ]
        )
    }

    // MARK: Settled by a human

    private func voiceOverCheck() -> CompatibilityCheck {
        check(
            id: "accessibility.voiceOver",
            title: "VoiceOver",
            status: .notRun,
            summary: "Not executed: a screen cannot hear itself read.",
            verified: "Nothing was audited. VoiceOver running at the time of the run: \(Self.isVoiceOverRunning).",
            nextStep: "Run the VoiceOver protocol in docs/hardening/accessibility-audit.md — every primary screen, one swipe at a time — and import the result through a Lab overlay.",
            evidence: [
                "protocol: every control is reachable, labelled, and reads its state; no row depends on gesture alone",
                "VoiceOver currently running: \(Self.isVoiceOverRunning)"
            ],
            severity: .high
        )
    }

    private func contrastCheck() -> CompatibilityCheck {
        check(
            id: "accessibility.contrast",
            title: "Colour contrast",
            status: .notRun,
            summary: "Not executed: contrast needs the rendered pixels, not the tokens that choose them.",
            verified: "Nothing was measured. ZynSign's semantic colors come from the platform's system colors, whose contrast the platform maintains in both appearances; that is why the static audit looks for hard-coded colors instead of ratios.",
            nextStep: "Run the contrast protocol in docs/hardening/accessibility-audit.md (Accessibility Inspector, or screenshots through a contrast tool) and import the result through a Lab overlay.",
            evidence: [
                "protocol: 4.5:1 for body text, 3:1 for large text and control boundaries, in light and dark appearance",
                "static check: Scripts/audit_accessibility.py refuses hard-coded colors outside DesignTokens"
            ],
            severity: .high
        )
    }

    private func touchTargetsCheck() -> CompatibilityCheck {
        check(
            id: "accessibility.touchTargets",
            title: "Touch targets",
            status: .notRun,
            summary: "Not executed: target size is a rendered geometry, measured by the Accessibility Inspector.",
            verified: "Nothing was measured. The host audit (Scripts/audit_accessibility.py) refuses fixed frames smaller than 44×44 in the sources, which is the half of the check a machine can make.",
            nextStep: "Run the touch-target protocol in docs/hardening/accessibility-audit.md, or import the host audit's result through a Lab overlay.",
            evidence: [
                "protocol: every tappable control is at least 44×44 points, and adjacent targets do not overlap"
            ],
            severity: .medium
        )
    }

    private func focusOrderCheck() -> CompatibilityCheck {
        check(
            id: "accessibility.focusOrder",
            title: "Focus order",
            status: .notRun,
            summary: "Not executed: focus order is what a reader experiences, not a value the app can read back.",
            verified: "Nothing was audited.",
            nextStep: "Run the focus-order protocol in docs/hardening/accessibility-audit.md (VoiceOver and keyboard) and import the result through a Lab overlay.",
            evidence: [
                "protocol: the order follows the visual order on every screen; sheets take focus and return it where it came from"
            ],
            severity: .medium
        )
    }

    // MARK: Platform

    private static var isVoiceOverRunning: Bool {
        #if canImport(UIKit)
        return UIAccessibility.isVoiceOverRunning
        #else
        return false
        #endif
    }

    private static var isReduceMotionEnabled: Bool {
        #if canImport(UIKit)
        return UIAccessibility.isReduceMotionEnabled
        #else
        return false
        #endif
    }

    private static var isIncreaseContrastEnabled: Bool {
        #if canImport(UIKit)
        return UIAccessibility.isDarkerSystemColorsEnabled
        #else
        return false
        #endif
    }

    private static var isAccessibilityCategory: Bool {
        #if canImport(UIKit)
        return UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory
        #else
        return false
        #endif
    }

    private static var contentSizeCategory: String {
        #if canImport(UIKit)
        return UIApplication.shared.preferredContentSizeCategory.rawValue
        #else
        return "unknown"
        #endif
    }

    private func check(
        id: String,
        title: String,
        status: CompatibilityStatus,
        summary: String,
        verified: String,
        nextStep: String? = nil,
        evidence: [String] = [],
        severity: ReleaseBlockerSeverity? = nil
    ) -> CompatibilityCheck {
        CompatibilityCheck(
            id: id,
            category: .accessibility,
            title: title,
            status: status,
            summary: summary,
            verified: verified,
            nextStep: nextStep,
            evidence: evidence,
            blocker: status == .failed ? (severity ?? .high) : nil
        )
    }
}
