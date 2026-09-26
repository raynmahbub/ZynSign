import SwiftUI

/// The SwiftUI application entry point for ZynSign.
///
/// This type only boots the application: it asks the composition root for the
/// application environment and installs it into the view hierarchy. All
/// behaviour lives behind that environment; nothing is constructed, decided,
/// or coordinated here.
///
/// The environment is handed to the shell explicitly rather than only through
/// the SwiftUI environment, because the shell builds the Settings Control
/// Center and the lock over it: one environment, one settings model, one
/// lock — the same objects the rest of the interface reads.
@main
struct ZynSignApp: App {

    @State
    private var environment: ApplicationEnvironment = CompositionRoot.makeApplicationEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView(environment: environment)
                .environment(\.applicationEnvironment, environment)
        }
        .commands {
            ImportCommands()
        }
    }
}
