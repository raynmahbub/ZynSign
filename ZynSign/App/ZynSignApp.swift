import SwiftUI

/// The SwiftUI application entry point for ZynSign.
///
/// This type only boots the application: it asks the composition root for the
/// application environment and installs it into the view hierarchy. All
/// behaviour lives behind that environment; nothing is constructed, decided,
/// or coordinated here.
@main
struct ZynSignApp: App {

    @State
    private var environment: ApplicationEnvironment = CompositionRoot.makeApplicationEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.applicationEnvironment, environment)
        }
    }
}
