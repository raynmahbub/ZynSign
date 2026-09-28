import SwiftUI

private struct PreferredColorSchemeContrastKey: EnvironmentKey {
    static let defaultValue = ColorSchemeContrast.standard
}

extension EnvironmentValues {

    /// The contrast ZynSign's appearance settings ask the interface to use.
    /// Views read it with `@Environment(\.preferredColorSchemeContrast)`.
    ///
    /// The system's own `colorSchemeContrast` is deliberately read-only —
    /// an app cannot override the user's choice — so ZynSign's preference
    /// travels through this app-owned key instead: `RootView` writes it once
    /// for the whole hierarchy (the appearance preference's `increaseContrast`
    /// when it is on, the system's value otherwise), and screens such as
    /// `EntitlementsStudioView` read it back.
    var preferredColorSchemeContrast: ColorSchemeContrast {
        get { self[PreferredColorSchemeContrastKey.self] }
        set { self[PreferredColorSchemeContrastKey.self] = newValue }
    }
}
