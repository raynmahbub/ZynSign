import Foundation
import SwiftUI

/// ZynSign design tokens — the single source of truth for spacing, radii,
/// shadows, and typography. ZynSign is a scratch project; these values are
/// chosen for ZynSign’s own Home/Library/Signing experience and are not
/// copied from any other app.
///
/// Using tokens: instead of `RoundedRectangle(cornerRadius: 12)` write
/// `RoundedRectangle(cornerRadius: ZRadius.card)` and instead of
/// `.padding(20)` write `.padding(ZSpacing.lg)`. Changing a value here
/// updates every screen consistently without hunting string literals.
enum ZynSignTokens {

    /// Base spacing scale — 4pt grid.
    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 20
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    /// Corner radii — consistent with iOS 17 card language.
    enum Radius {
        /// Small controls, pills, badges.
        static let sm: CGFloat = 8
        /// Cards, list rows.
        static let card: CGFloat = 12
        /// Large header / featured card (matches Home header).
        static let lg: CGFloat = 16
        /// Icon well (signature mark).
        static let icon: CGFloat = 14
        /// Extra-large featured carousel.
        static let xl: CGFloat = 24
    }

    /// Elevation shadows — soft, as inferred from modern SwiftUI apps.
    enum Shadow {
        static let soft = ShadowToken(color: .black.opacity(0.06), radius: 8, x: 0, y: 4)
        static let card = ShadowToken(color: .black.opacity(0.08), radius: 12, x: 0, y: 6)

        struct ShadowToken {
            let color: Color
            let radius: CGFloat
            let x: CGFloat
            let y: CGFloat
        }
    }

    /// Semantic colors — thin wrappers so a future theme needs only one edit.
    enum Color {
        static let accent = SwiftUI.Color.accentColor
        static let cardBackground = SwiftUI.Color(.secondarySystemBackground)
        static let headerMaterial: Material = .ultraThinMaterial
    }

    /// Reusable typography — keeps Home/Library headings identical.
    enum Typography {
        static let cardTitle: Font = .headline
        static let captionSecondary: Font = .caption
        static let footnoteSecondary: Font = .footnote
    }
}

// Convenience aliases that match the `ZSpacing`-style naming users expect
// from the teardown sketch, while keeping the canonical type `ZynSignTokens`.
typealias ZSpacing = ZynSignTokens.Spacing
typealias ZRadius = ZynSignTokens.Radius
typealias ZShadow = ZynSignTokens.Shadow
typealias ZColors = ZynSignTokens.Color

// MARK: - View helpers

extension View {
    /// Soft card background used by Home header, library rows, etc.
    func zynCardBackground(cornerRadius: CGFloat = ZRadius.card) -> some View {
        background(ZColors.cardBackground, in: RoundedRectangle(cornerRadius: cornerRadius))
    }

    /// Material card background used by Home header.
    func zynHeaderBackground(cornerRadius: CGFloat = ZRadius.lg) -> some View {
        background(ZColors.headerMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
    }

    /// Apply the soft elevation used across cards.
    func zynSoftShadow(_ token: ZShadow.ShadowToken = ZShadow.soft) -> some View {
        shadow(color: token.color, radius: token.radius, x: token.x, y: token.y)
    }
}

// MARK: - Haptics (lightweight, no singleton)

/// ZynSign’s haptics — a stateless helper that never retains state.
/// Call from any view via `ZHaptics.tap()` or `.sensoryFeedback` on iOS 17+.
///
/// `isEnabled` is the user's haptic-feedback preference, applied by the
/// Settings Control Center whenever it loads or the preference changes. It
/// defaults to on, so a call site that has not consulted the settings still
/// gets feedback rather than silence. Access is guarded because the flag is
/// read from views and written from the settings model, which are not
/// guaranteed to be on the same actor at every moment.
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
}
