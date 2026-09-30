import SwiftUI

/// Resolves a `#RRGGBB` hex string to a SwiftUI color, falling back to the
/// accent when the string does not parse. Theme data is the single source;
/// this file is the only place hex becomes a color.
extension Color {

    /// Creates a color from a `#RRGGBB` theme stop.
    init(themeHex hex: String) {
        if let stop = ThemeColorStop(hex: hex) {
            self.init(red: stop.red, green: stop.green, blue: stop.blue)
        } else {
            self = .accentColor
        }
    }
}

/// The theme the interface is currently rendering with, resolved once at
/// the shell and read everywhere else.
struct ResolvedAppTheme: Equatable {

    /// The definition the catalog resolved.
    let definition: AppThemeDefinition

    /// The accent override, when the user set one and it parses.
    let accentOverride: Color?

    /// Whether the interface renders in reduced-visual-density mode.
    let minimalInterface: Bool

    /// The accent to apply: the override when valid, else the theme's own.
    var accent: Color {
        accentOverride ?? Color(themeHex: definition.accentHex)
    }

    /// The gradient hero surfaces render. Diagonal, two-stop; a minimal
    /// interface substitutes a single washed-out tint for the gradient.
    var heroGradient: LinearGradient {
        let stops = definition.gradientHex.map { Color(themeHex: $0) }
        if minimalInterface, let first = stops.first {
            return LinearGradient(colors: [first.opacity(0.35), first.opacity(0.15)], startPoint: .top, endPoint: .bottom)
        }
        guard stops.count >= 2 else {
            return LinearGradient(colors: stops.isEmpty ? [.accentColor] : stops, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        return LinearGradient(colors: stops, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Resolves the theme preferences describe.
    static func resolve(_ appearance: AppearancePreferences) -> ResolvedAppTheme {
        ResolvedAppTheme(
            definition: AppThemeCatalog.theme(identifier: appearance.themeIdentifier),
            accentOverride: appearance.accentOverrideHex.flatMap { hex in
                ThemeColorStop(hex: hex) == nil ? nil : Color(themeHex: hex)
            },
            minimalInterface: appearance.minimalInterface
        )
    }
}

private struct AppThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = ResolvedAppTheme.resolve(AppearancePreferences())
}

extension EnvironmentValues {

    /// The resolved theme every screen renders with. The shell sets it once
    /// from preferences; screens read it instead of re-resolving.
    var appTheme: ResolvedAppTheme {
        get { self[AppThemeEnvironmentKey.self] }
        set { self[AppThemeEnvironmentKey.self] = newValue }
    }
}

extension View {

    /// Applies the resolved theme's accent. Screens call this once near the
    /// root of their hierarchy; controls below inherit.
    func zThemeTint() -> some View {
        modifier(ZThemeTintModifier())
    }
}

private struct ZThemeTintModifier: ViewModifier {
    @Environment(\.appTheme) private var theme
    func body(content: Content) -> some View {
        content.tint(theme.accent)
    }
}
