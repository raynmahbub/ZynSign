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
/// per cold launch over `RootView` until its 1.9s fluid timeline completes
/// (tap skips). It is the same Liquid Glass mark used everywhere else, animated
/// with a brief, quiet fade that respects Reduce Motion.
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
                    ZynSplashView {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                            showSplash = false
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(1)
                }
            }
        }
        .commands {
            ImportCommands()
        }
    }
}
