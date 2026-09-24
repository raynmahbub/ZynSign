import Foundation

/// The application-layer object handed to the presentation layer at launch.
///
/// `ApplicationEnvironment` is the seam between the SwiftUI shell and the
/// application layer: it carries the dependencies the presentation layer is
/// allowed to see, constructed by the composition root. Views read it from
/// the SwiftUI environment; they never construct application-layer or domain
/// objects themselves.
///
/// The environment carries the application's own descriptive information,
/// the package-import use case coordinated by the Import area, the library
/// and bundle-inspection use cases coordinated by the Applications area,
/// and the signing facade coordinated by the Signing area.
struct ApplicationEnvironment {
    /// Facts about the running application, shown by the shell.
    let applicationInfo: ApplicationInfo

    /// The package-import use case, coordinated by the Import area.
    let packageImport: IPAPackageImport

    /// The library use case: lists, admits, and removes the application
    /// records behind the Applications area.
    let library: ApplicationLibrary

    /// The bundle contents inspection use case: describes, read-only, the
    /// structure of a library application's bundle for the explorer.
    let bundleInspection: IPABundleContentsInspection

    /// The signing facade: identity creation, standalone profile
    /// validation, and the nine-stage pipeline behind the Signing area.
    let signing: ApplicationSigning
}
