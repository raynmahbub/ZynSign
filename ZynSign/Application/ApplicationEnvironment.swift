import Foundation

/// The application-layer object handed to the presentation layer at launch.
///
/// `ApplicationEnvironment` is the seam between the SwiftUI shell and the
/// application layer: it carries the dependencies the presentation layer is
/// allowed to see, constructed by the composition root. Views read it from
/// the SwiftUI environment; they never construct application-layer or domain
/// objects themselves.
///
/// The foundation build coordinates no use cases yet, so the environment
/// carries only the application's own descriptive information. Future use
/// cases — importing an artifact, inspecting it, managing records, configuring
/// signing — will be constructed by the composition root and surfaced here,
/// which keeps dependency substitution and testing straightforward.
struct ApplicationEnvironment {
    /// Facts about the running application, shown by the shell.
    let applicationInfo: ApplicationInfo
}
