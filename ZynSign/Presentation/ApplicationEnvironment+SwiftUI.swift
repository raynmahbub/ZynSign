import SwiftUI

/// SwiftUI integration for the application environment.
///
/// The composition root installs the environment once at the root of the view
/// hierarchy; views read it with `@Environment(\.applicationEnvironment)`.
/// This is the only place where the application layer meets SwiftUI.
///
/// The default is a *fallback*, not a second composition. It exists so a view
/// rendered without the shell — a SwiftUI preview, a test that builds one
/// screen directly — has something to read instead of trapping. It is the one
/// shared `CompositionRoot` fallback, built at most once per process, so
/// reading this key, `\.settingsCenter`, and `\.appLock` outside the shell
/// cannot produce three application graphs that disagree about the user's
/// library and preferences. In the running app the shell installs its own
/// environment before any view reads this key, so the fallback is never built
/// on a device.
private struct ApplicationEnvironmentKey: EnvironmentKey {
    static let defaultValue = CompositionRoot.fallbackEnvironment
}

extension EnvironmentValues {
    /// The application-layer dependencies visible to the view hierarchy.
    var applicationEnvironment: ApplicationEnvironment {
        get { self[ApplicationEnvironmentKey.self] }
        set { self[ApplicationEnvironmentKey.self] = newValue }
    }
}
