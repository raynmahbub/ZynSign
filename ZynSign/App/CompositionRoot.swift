import Foundation

/// The composition root for ZynSign.
///
/// This is the single place where application-layer objects are constructed
/// and wired together. The application entry point calls into it and nothing
/// else; views receive dependencies through the SwiftUI environment and never
/// construct application-layer or domain objects themselves.
///
/// The application currently has no services or use cases: the foundation
/// build contains the shell only. As use cases are introduced, they are
/// constructed here and exposed through `ApplicationEnvironment`, which keeps
/// dependency construction centralized and substitution straightforward.
enum CompositionRoot {

    /// Builds the application environment for a fresh launch.
    static func makeApplicationEnvironment() -> ApplicationEnvironment {
        ApplicationEnvironment(
            applicationInfo: ApplicationInfo.current(bundle: .main)
        )
    }
}
