import Foundation

/// The application-layer object handed to the presentation layer at launch.
///
/// `ApplicationEnvironment` is the seam between the SwiftUI shell and the
/// application layer: it carries the dependencies the presentation layer is
/// allowed to see, constructed by the composition root. Views read it from
/// the SwiftUI environment; they never construct application-layer or domain
/// objects themselves.
///
/// The environment currently carries the application's own descriptive
/// information and the package-import use case. Future use cases — a
/// package library, signing — will be constructed by the composition root
/// and surfaced here, which keeps dependency substitution and testing
/// straightforward.
struct ApplicationEnvironment {
    /// Facts about the running application, shown by the shell.
    let applicationInfo: ApplicationInfo

    /// The package-import use case, coordinated by the Import area.
    let packageImport: IPAPackageImport
}
