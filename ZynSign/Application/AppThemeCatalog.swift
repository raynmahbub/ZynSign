import Foundation

/// One color stop in a theme, expressed as sRGB components so the
/// presentation layer can render it on any material without reaching into
/// this catalog's internals.
struct ThemeColorStop: Equatable, Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    /// Parses a `#RRGGBB` hex string, or returns `nil` for anything else.
    init?(hex: String) {
        var text = hex
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        red = Double((value >> 16) & 0xFF) / 255
        green = Double((value >> 8) & 0xFF) / 255
        blue = Double(value & 0xFF) / 255
    }

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// The complete visual description of one application theme.
///
/// A theme is a design decision, not a pile of overrides: it names the
/// accent, the gradient the hero surfaces carry, and whether the theme
/// prefers dark surfaces. The presentation layer maps these values onto
/// SwiftUI colors; nothing here imports SwiftUI.
struct AppThemeDefinition: Equatable, Hashable, Sendable {

    /// The stable identifier stored in preferences.
    let identifier: String

    /// The name the interface shows.
    let displayName: String

    /// A one-line description of the theme's character.
    let summary: String

    /// The single accent the theme uses for interactive elements.
    let accentHex: String

    /// The gradient the hero surfaces render, top to bottom. Two stops
    /// minimum; rendering joins them diagonally.
    let gradientHex: [String]

    /// The SF Symbol the theme picker shows next to the theme.
    let symbolName: String

    /// Whether the theme looks best on dark surfaces. The interface may
    /// suggest dark mode without forcing it.
    let prefersDarkSurfaces: Bool
}

/// The themes ZynSign ships, and the rules for resolving one.
///
/// Four themes ship: the original look, a warm flame gradient for
/// signing-focused sessions, a cold deep-blue night look, and a graphite
/// look that leans entirely on system materials. The catalog is the single
/// place a theme is defined; presentation and settings both read it.
enum AppThemeCatalog {

    /// Every shipped theme, in picker order.
    static let all: [AppThemeDefinition] = [
        AppThemeDefinition(
            identifier: ZynSignTheme.zynSign.rawValue,
            displayName: "ZynSign",
            summary: "The original look — system materials, indigo accents.",
            accentHex: "#6D6AF0",
            gradientHex: ["#6D6AF0", "#8E8AF6"],
            symbolName: "seal.fill",
            prefersDarkSurfaces: false
        ),
        AppThemeDefinition(
            identifier: ZynSignTheme.ember.rawValue,
            displayName: "Ember",
            summary: "A warm flame gradient for focused signing sessions.",
            accentHex: "#FF6A3D",
            gradientHex: ["#FF6A3D", "#FF9F45"],
            symbolName: "flame.fill",
            prefersDarkSurfaces: true
        ),
        AppThemeDefinition(
            identifier: ZynSignTheme.midnight.rawValue,
            displayName: "Midnight",
            summary: "A cold deep-blue night look, easy on the eyes.",
            accentHex: "#5E8BFF",
            gradientHex: ["#2743A6", "#5E8BFF"],
            symbolName: "moon.stars.fill",
            prefersDarkSurfaces: true
        ),
        AppThemeDefinition(
            identifier: ZynSignTheme.graphite.rawValue,
            displayName: "Graphite",
            summary: "Quiet monochrome — the system does the talking.",
            accentHex: "#8E8E93",
            gradientHex: ["#48484A", "#8E8E93"],
            symbolName: "circle.hexagongrid.fill",
            prefersDarkSurfaces: false
        ),
    ]

    /// Resolves a theme by identifier, falling back to the default.
    static func theme(identifier: String) -> AppThemeDefinition {
        all.first { $0.identifier == identifier } ?? all[0]
    }

    /// The default theme.
    static var defaultTheme: AppThemeDefinition { all[0] }
}
