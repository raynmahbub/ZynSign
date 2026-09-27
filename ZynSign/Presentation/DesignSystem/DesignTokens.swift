import Foundation
import SwiftUI

/// ZynSign design tokens — the single source of truth for spacing, radii,
/// shadows, typography and colors across the entire application. Motion is
/// `ZMotion`, haptics are `ZHaptics` (below); both resolve the user's
/// preferences in one place.
///
/// Every screen uses these unified tokens to ensure consistent rhythm,
/// comfortable touch targets, elegant dark mode contrast, and responsive
/// layouts on iPhone and iPad.
enum ZynSignTokens {

    /// Base spacing scale — 4pt grid.
    enum Spacing {
        /// 4pt
        static let xxs: CGFloat = 4
        /// 8pt
        static let xs: CGFloat = 8
        /// 12pt
        static let sm: CGFloat = 12
        /// 16pt
        static let md: CGFloat = 16
        /// 20pt
        static let lg: CGFloat = 20
        /// 24pt
        static let xl: CGFloat = 24
        /// 32pt
        static let xxl: CGFloat = 32
        /// 48pt
        static let xxxl: CGFloat = 48
    }

    /// Corner radii — consistent with iOS 17/18 card language.
    enum Radius {
        /// Micro elements, small badges (4pt).
        static let xs: CGFloat = 4
        /// Small controls, pills, badges (8pt).
        static let sm: CGFloat = 8
        /// Cards, list rows, standard containers (12pt).
        static let card: CGFloat = 12
        /// Large header / featured card (16pt).
        static let lg: CGFloat = 16
        /// Icon well (14pt).
        static let icon: CGFloat = 14
        /// Extra-large hero / carousel (24pt).
        static let xl: CGFloat = 24
        /// Full capsule / circular pill.
        static let pill: CGFloat = 999

        /// The corner of an app-icon artwork at a given side length — the
        /// iOS icon ratio (22.37 %), so a 56 pt icon gets 12.5 pt and a
        /// 100 pt icon 22 pt, exactly like the home screen.
        static func appIcon(side: CGFloat) -> CGFloat {
            (side * 0.2237).rounded()
        }
    }

    /// Elevation shadows — calibrated for subtle depth in light and dark mode.
    enum Shadow {
        static let subtle = ShadowToken(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
        static let soft = ShadowToken(color: .black.opacity(0.06), radius: 8, x: 0, y: 4)
        static let card = ShadowToken(color: .black.opacity(0.08), radius: 12, x: 0, y: 6)
        static let elevated = ShadowToken(color: .black.opacity(0.12), radius: 16, x: 0, y: 8)

        struct ShadowToken: Sendable, Equatable {
            let color: SwiftUI.Color
            let radius: CGFloat
            let x: CGFloat
            let y: CGFloat
        }
    }

    /// Semantic colors — adaptive across light, dark, and high-contrast modes.
    enum Color {
        static let accent = SwiftUI.Color.accentColor
        static let cardBackground = SwiftUI.Color(.secondarySystemBackground)
        static let groupedBackground = SwiftUI.Color(.systemGroupedBackground)
        static let secondaryGroupedBackground = SwiftUI.Color(.secondarySystemGroupedBackground)
        static let tertiaryCardBackground = SwiftUI.Color(.tertiarySystemBackground)
        static let headerMaterial: Material = .ultraThinMaterial
        static let separator = SwiftUI.Color(.separator)
        static let subtleBorder = SwiftUI.Color.primary.opacity(0.06)

        // Semantic status colors
        static let success = SwiftUI.Color.green
        static let warning = SwiftUI.Color.orange
        static let error = SwiftUI.Color.red
        static let info = SwiftUI.Color.blue
        static let neutral = SwiftUI.Color.secondary
    }

    /// Reusable typography tokens — Dynamic Type enabled throughout.
    enum Typography {
        static let largeTitle: Font = .largeTitle.weight(.bold)
        static let title: Font = .title.weight(.bold)
        static let title2: Font = .title2.weight(.bold)
        static let title3: Font = .title3.weight(.semibold)
        static let headline: Font = .headline
        static let subheadline: Font = .subheadline
        static let cardTitle: Font = .headline
        static let body: Font = .body
        static let callout: Font = .callout
        static let footnote: Font = .footnote
        static let caption: Font = .caption
        static let captionBold: Font = .caption.weight(.semibold)
        static let caption2: Font = .caption2
        static let captionSecondary: Font = .caption
        static let footnoteSecondary: Font = .footnote
        static let code: Font = .system(.subheadline, design: .monospaced)
        static let codeCaption: Font = .system(.caption, design: .monospaced)
    }

}

// Motion lives in ZMotion.swift: one policy (Reduce Motion + the animation
// preference) resolves the four presets for the environment and for static
// call sites alike.

// Convenience aliases that match ZSpacing-style naming across the app.
typealias ZSpacing = ZynSignTokens.Spacing
typealias ZRadius = ZynSignTokens.Radius
typealias ZShadow = ZynSignTokens.Shadow
typealias ZColors = ZynSignTokens.Color
typealias ZTypography = ZynSignTokens.Typography

// MARK: - View helpers

extension View {
    /// Soft card background used by Home header, library rows, etc.
    func zynCardBackground(cornerRadius: CGFloat = ZRadius.card) -> some View {
        background(ZColors.cardBackground, in: RoundedRectangle(cornerRadius: cornerRadius))
    }

    /// Material card background used by Home header and floating overlays.
    func zynHeaderBackground(cornerRadius: CGFloat = ZRadius.lg) -> some View {
        background(ZColors.headerMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
    }

    /// Apply the soft elevation used across cards.
    func zynSoftShadow(_ token: ZShadow.ShadowToken = ZShadow.soft) -> some View {
        shadow(color: token.color, radius: token.radius, x: token.x, y: token.y)
    }

    /// Standard comfortable hit target for buttons (minimum 44x44pt).
    func zComfortableHitTarget() -> some View {
        frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

// MARK: - Haptics (lightweight, stateful preferences guarded)

/// ZynSign’s haptics — a stateless helper that never retains view state.
/// Call from any view via `ZHaptics.tap()`, `ZHaptics.success()`, etc.
///
/// `isEnabled` is the user's haptic-feedback preference, applied by the
/// Settings Control Center whenever it loads or the preference changes. It
/// defaults to true, so call sites get feedback out of the box.
enum ZHaptics {

    private static let lock = NSLock()
    private static var storedIsEnabled = true

    /// Whether haptic feedback is allowed.
    static var isEnabled: Bool {
        get { lock.withLock { storedIsEnabled } }
        set { lock.withLock { storedIsEnabled = newValue } }
    }

    static func tap() {
        guard isEnabled else { return }
#if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
#endif
    }

    static func success() {
        guard isEnabled else { return }
#if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
#endif
    }

    static func warning() {
        guard isEnabled else { return }
#if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
#endif
    }

    static func error() {
        guard isEnabled else { return }
#if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
#endif
    }

    static func selection() {
        guard isEnabled else { return }
#if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
#endif
    }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        guard isEnabled else { return }
#if os(iOS)
        UIImpactFeedbackGenerator(style: style).impactOccurred()
#endif
    }

    // MARK: - Haptic language

    /// The vocabulary. Screens name the *moment*, not the generator, so
    /// every import feels like an import and every sign like a sign.
    ///
    /// | Moment | Feedback |
    /// |---|---|
    /// | `imported` | light impact — something small arrived |
    /// | `sign` | medium impact — the user committed to work |
    /// | `succeeded` | notification success |
    /// | `failed` | notification error |
    /// | `attention` | notification warning — a refusal, not a crash |
    /// | `select` | selection change — pickers, segmented controls |
    /// | `navigate` | light impact — opening a section |
    enum Moment: Sendable {
        case imported, sign, succeeded, failed, attention, select, navigate
    }

    /// Play the feedback for a moment. Honours the haptics preference.
    static func play(_ moment: Moment) {
        switch moment {
        case .imported, .navigate: tap()
        case .sign: impact(.medium)
        case .succeeded: success()
        case .failed: error()
        case .attention: warning()
        case .select: selection()
        }
    }
}
