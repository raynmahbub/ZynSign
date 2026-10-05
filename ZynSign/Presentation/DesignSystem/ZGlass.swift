import Foundation
import SwiftUI

/// Liquid Glass — ZynSign's app-wide glass material system.
///
/// One layer decides what "glass" means for every surface, so the whole
/// interface turns with one switch: cards, bars, chrome, and floating
/// controls all ask this file what to render.
///
/// * **iOS 26 and later** hands the real thing to the system: surfaces render
///   with SwiftUI's `glassEffect`, so refraction and specular highlighting
///   follow the platform's own liquid glass.
/// * **iOS 17 – 18** has no platform glass, so ZynSign paints the closest
///   honest approximation: an ultra-thin material substrate, a diagonal
///   specular stroke, and a soft elevation shadow — the same recipe the card
///   system has used since the theme shipped.
/// * **Turned off** — in Settings → Appearance → Liquid Glass — every
///   surface resolves to its plain, opaque material. Nothing else changes:
///   the toggle never removes a feature, it removes the translucency.
///
/// The switch itself is one preference (`AppearancePreferences.liquidGlass`,
/// mirrored by the Liquid Glass *theme*), resolved once at the shell into
/// `ResolvedAppTheme.liquidGlass`. Views read it through the theme
/// environment; the static `ZGlass.isEnabled` mirrors it for the few call
/// sites that cannot hold an environment — the split `ZMotion` and `ZHaptics`
/// already use.
enum ZGlass {

    private static let lock = NSLock()
    private static var storedIsEnabled = false

    /// Process-wide mirror of the user's preference, applied by the shell
    /// whenever the resolved theme changes. Default off until the shell has
    /// resolved preferences, so a first frame never guesses.
    static var isEnabled: Bool {
        get { lock.withLock { storedIsEnabled } }
        set { lock.withLock { storedIsEnabled = newValue } }
    }

    /// Whether the platform paints its own liquid glass. Where it does,
    /// ZynSign adds none of its own on top of system chrome — the system's
    /// morphing bar is never overpainted.
    static var systemGlassAvailable: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// The specular edge every ZynSign glass surface carries: a diagonal
    /// highlight, brightest at the leading top, the way real glass catches
    /// light. Never applied when the platform already draws its own.
    static var highlight: LinearGradient {
        LinearGradient(
            colors: [Color.white.opacity(0.35), Color.white.opacity(0.08)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// The glass substrate for a rounded-rectangle surface.
    ///
    /// Glass on: the system `glassEffect` where the platform has it; the
    /// material-plus-specular recipe everywhere else. Glass off: `plain`, the
    /// opaque card material the interface used before the theme existed.
    @ViewBuilder
    static func substrate<Content: View>(
        _ content: Content,
        cornerRadius: CGFloat,
        glass: Bool
    ) -> some View {
        if glass {
            if #available(iOS 26.0, *) {
                content
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                content
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(highlight, lineWidth: 1)
                    }
            }
        } else {
            content
                .background(ZColors.cardBackground, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(ZColors.subtleBorder, lineWidth: 0.5)
                }
        }
    }
}

private struct ZGlassSurfaceModifier: ViewModifier {
    @Environment(\.appTheme) private var appTheme
    var cornerRadius: CGFloat
    var elevation: Bool

    func body(content: Content) -> some View {
        Group {
            if appTheme.liquidGlass, ZGlass.systemGlassAvailable {
                // The platform effect already carries its own depth.
                ZGlass.substrate(content, cornerRadius: cornerRadius, glass: true)
            } else {
                ZGlass.substrate(content, cornerRadius: cornerRadius, glass: appTheme.liquidGlass)
                    .modifier(ZOptionalElevation(active: elevation))
            }
        }
    }
}

/// The soft card shadow, suppressed where the platform's glass already
/// renders depth, so a surface is never shadowed twice.
private struct ZOptionalElevation: ViewModifier {
    var active: Bool
    func body(content: Content) -> some View {
        if active {
            content.zynSoftShadow()
        } else {
            content
        }
    }
}

private struct ZGlassBarChromeModifier: ViewModifier {
    @Environment(\.appTheme) private var appTheme

    /// Floating glass chrome for bars the shell draws itself (the tab bar).
    ///
    /// On iOS 26 the bar floats as a real glass island; on earlier systems it
    /// keeps the material + specular treatment as a capsule; with glass off
    /// it is the classic solid `.bar` background.
    func body(content: Content) -> some View {
        if appTheme.liquidGlass {
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular, in: Capsule())
            } else {
                content
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(ZGlass.highlight, lineWidth: 0.75)
                    }
            }
        } else {
            content
                .background(.bar, in: Rectangle())
        }
    }
}

private struct ZGlassNavigationChromeModifier: ViewModifier {
    @Environment(\.appTheme) private var appTheme

    /// Glass navigation chrome for a stack the shell hosts.
    ///
    /// Only ever paints anything on pre-26 systems, where toolbars and bars
    /// are opaque by default and the material is what makes the interface
    /// read as glass; iOS 26 draws its own, and glass-off changes nothing.
    func body(content: Content) -> some View {
        if appTheme.liquidGlass, !ZGlass.systemGlassAvailable {
            content
                .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
                .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        } else {
            content
        }
    }
}

extension View {

    /// Renders this surface through the liquid-glass system: glass material
    /// and specular edge while the preference is on, the plain card material
    /// when it is off. The sanctioned way for a ZynSign surface to claim a
    /// background — cards, the command center, and floating controls route
    /// through here so one switch turns them all.
    func zGlassSurface(cornerRadius: CGFloat = ZRadius.card, elevation: Bool = true) -> some View {
        modifier(ZGlassSurfaceModifier(cornerRadius: cornerRadius, elevation: elevation))
    }

    /// Floating glass chrome for bars the shell draws itself.
    func zGlassBarChrome() -> some View {
        modifier(ZGlassBarChromeModifier())
    }

    /// Glass navigation chrome for the stacks under the shell.
    func zGlassNavigationChrome() -> some View {
        modifier(ZGlassNavigationChromeModifier())
    }
}
