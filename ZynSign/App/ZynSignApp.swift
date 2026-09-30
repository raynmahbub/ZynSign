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
///
/// The launch splash — `ZynSplashView` (Liquid Glass Z·Pen) — is shown once
/// per cold launch over `RootView` and removed on the frame its own fade
/// completes. The layer owns its entry and exit animation entirely; animating
/// the removal here as well is what made the handover read as a jump.
/// Tapping skips it, and Reduce Motion shortens it — both decisions live in
/// `ZynSplashView`, which is the only place that knows the timeline.
@main
struct ZynSignApp: App {

    @State
    private var environment: ApplicationEnvironment = CompositionRoot.makeApplicationEnvironment()

    @State
    private var showSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView(environment: environment)
                    .environment(\.applicationEnvironment, environment)

                if showSplash {
                    // No animation here on purpose. `ZynSplashView` fades
                    // itself out and calls back on the frame it reaches zero
                    // opacity; animating the *removal* as well put a second
                    // spring on the same layer, which is what read as a jump
                    // when the launch screen let go.
                    ZynSplashView { showSplash = false }
                        .zIndex(1)
                }
            }
        }
        .commands {
            ImportCommands()
        }
    }
}
