import SwiftUI

// MARK: - Surface Styling & Navigation Chrome

/// Surface and chrome helpers used across ZynSign's presentation layer.
///
/// Content cards use crisp grouped-background fills and hairline strokes rather
/// than per-row backdrop blurs or offscreen drop shadows, keeping `List` and
/// `ScrollView` scrolling locked at full ProMotion frame rates while native
/// `TabView` and `NavigationStack` bars handle system translucency.
enum ZGlass {

    /// Mirrored from `ResolvedAppTheme.liquidGlass` by the shell.
    static var isEnabled: Bool = true

    /// Subtle specular hairline gradient used by `ZCard`.
    static var highlight: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(0.18),
                Color.white.opacity(0.05)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Whether the running OS provides iOS 26's native system glass bars.
    static var systemGlassAvailable: Bool {
        if #available(iOS 26.0, *) {
            return true
        }
        return false
    }

    /// Clean, opaque-fast card substrate suitable for scrolling lists and grids.
    @ViewBuilder
    static func substrate<Content: View>(
        _ content: Content,
        cornerRadius: CGFloat,
        glass: Bool
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(ZColors.cardBackground, in: shape)
            .overlay {
                shape.strokeBorder(
                    glass ? Color.primary.opacity(0.08) : ZColors.hairline,
                    lineWidth: 0.5
                )
            }
    }
}

// MARK: - View Modifiers

struct ZGlassCardModifier: ViewModifier {
    @Environment(\.appTheme) private var appTheme
    let padding: CGFloat
    let cornerRadius: CGFloat
    let elevation: Bool

    func body(content: Content) -> some View {
        ZGlass.substrate(
            content.padding(padding),
            cornerRadius: cornerRadius,
            glass: appTheme.liquidGlass
        )
    }
}

struct ZGlassBarModifier: ViewModifier {
    @Environment(\.appTheme) private var appTheme
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if appTheme.liquidGlass {
            content
                .background(.thinMaterial, in: shape)
                .overlay {
                    shape.strokeBorder(ZColors.hairline, lineWidth: 0.5)
                }
        } else {
            content
                .background(ZColors.secondaryGroupedBackground, in: shape)
                .overlay {
                    shape.strokeBorder(ZColors.hairline, lineWidth: 0.5)
                }
        }
    }
}

struct ZGlassPillModifier: ViewModifier {
    @Environment(\.appTheme) private var appTheme
    let tint: Color?

    func body(content: Content) -> some View {
        let shape = Capsule(style: .continuous)
        content
            .background {
                if let tint {
                    shape.fill(tint.opacity(appTheme.liquidGlass ? 0.14 : 0.12))
                } else {
                    shape.fill(Color(.tertiarySystemFill))
                }
            }
            .overlay {
                if let tint {
                    shape.strokeBorder(tint.opacity(0.24), lineWidth: 0.5)
                }
            }
    }
}

extension View {

    /// Card container with clean grouped fill and hairline border.
    func zGlassCard(
        padding: CGFloat = ZSpacing.md,
        cornerRadius: CGFloat = ZRadius.lg,
        elevation: Bool = true
    ) -> some View {
        modifier(ZGlassCardModifier(padding: padding, cornerRadius: cornerRadius, elevation: elevation))
    }

    /// Surface fill without inner padding, for rows that manage their own insets.
    func zGlassSurface(
        cornerRadius: CGFloat = ZRadius.md,
        elevation: Bool = false
    ) -> some View {
        modifier(ZGlassCardModifier(padding: 0, cornerRadius: cornerRadius, elevation: elevation))
    }

    /// Floating bar or banner surface.
    func zGlassBar(cornerRadius: CGFloat = ZRadius.xl) -> some View {
        modifier(ZGlassBarModifier(cornerRadius: cornerRadius))
    }

    /// Alias for chrome bars and headers.
    func zGlassChrome(cornerRadius: CGFloat = ZRadius.xl) -> some View {
        modifier(ZGlassBarModifier(cornerRadius: cornerRadius))
    }

    /// Compact pill / badge background.
    func zGlassPill(tint: Color? = nil) -> some View {
        modifier(ZGlassPillModifier(tint: tint))
    }

    /// Delegates navigation and tab bar materials to native UIKit/SwiftUI chrome
    /// so pushed destinations and tab switches never trigger extra backdrop passes.
    @ViewBuilder
    func zGlassNavigationChrome() -> some View {
        self
    }
}
