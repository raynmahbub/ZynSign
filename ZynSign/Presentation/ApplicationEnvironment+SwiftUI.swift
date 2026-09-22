import SwiftUI

/// SwiftUI integration for the application environment.
///
/// The composition root installs the environment once at the root of the view
/// hierarchy; views read it with `@Environment(\.applicationEnvironment)`.
/// This is the only place where the application layer meets SwiftUI.
private struct ApplicationEnvironmentKey: EnvironmentKey {
    static let defaultValue = CompositionRoot.makeApplicationEnvironment()
}

extension EnvironmentValues {
    /// The application-layer dependencies visible to the view hierarchy.
    var applicationEnvironment: ApplicationEnvironment {
        get { self[ApplicationEnvironmentKey.self] }
        set { self[ApplicationEnvironmentKey.self] = newValue }
    }
}
