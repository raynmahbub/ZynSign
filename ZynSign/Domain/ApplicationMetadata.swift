/// The metadata one application bundle declares about itself.
///
/// A pure domain value: it records what a bundle's information file claims —
/// nothing more. It carries no file references, no archive paths, no platform
/// objects, and no verification results. A constructible `ApplicationMetadata`
/// means only that the declared values satisfied ZynSign's rules; it is not
/// evidence that the bundle is genuine, signed, loadable, or installable.
///
/// Raw declared values are preserved exactly as recorded. The resolved
/// display name is the one derived value in the record, and its fallback
/// policy is stated on the type that computes it, so raw observed values and
/// derived display values stay distinguishable.
struct ApplicationMetadata: Equatable, Hashable {

    /// The bundle's declared identity. The bundle identifier is required for
    /// a valid metadata record; the declared name and version values are
    /// optional.
    let identity: ApplicationIdentity

    /// The executable name the bundle declares (CFBundleExecutable), or
    /// `nil` when it declares none. A name is a declaration only: it is not
    /// evidence that an executable with that name exists, is complete, or is
    /// a valid executable.
    let executableName: String?

    /// The minimum OS version the bundle declares (MinimumOSVersion),
    /// preserved exactly as declared, or `nil` when it declares none. No
    /// version-format system is imposed on the value.
    let minimumOSVersion: String?

    /// The device families the bundle declares support for (UIDeviceFamily),
    /// or `nil` when it declares none. Values ZynSign does not recognize are
    /// preserved rather than dropped.
    let deviceFamily: [ApplicationDeviceFamily]?

    /// The application icon name the bundle declares (CFBundleIconName),
    /// preserved exactly as declared, or `nil` when it declares none.
    let iconName: String?

    /// Records declared metadata.
    init(
        identity: ApplicationIdentity,
        executableName: String? = nil,
        minimumOSVersion: String? = nil,
        deviceFamily: [ApplicationDeviceFamily]? = nil,
        iconName: String? = nil
    ) {
        self.identity = identity
        self.executableName = executableName
        self.minimumOSVersion = minimumOSVersion
        self.deviceFamily = deviceFamily
        self.iconName = iconName
    }
}

/// One device family a bundle declares support for, from the UIDeviceFamily
/// entry of its information file.
///
/// The known cases are the families the platform documentation defines. A
/// declared value outside that set is preserved as `unknown` rather than
/// dropped or approximated, so a bundle declaring a family introduced after
/// ZynSign's knowledge cannot break extraction.
enum ApplicationDeviceFamily: Equatable, Hashable {

    /// An iPhone or iPod family device.
    case phone

    /// An iPad family device.
    case pad

    /// An Apple TV device.
    case tv

    /// An Apple Watch device.
    case watch

    /// An Apple Vision Pro device.
    case visionOS

    /// A declared value ZynSign does not recognize, preserved verbatim.
    case unknown(Int)

    /// Interprets one declared value.
    static func interpret(rawValue: Int) -> ApplicationDeviceFamily {
        switch rawValue {
        case 1: return .phone
        case 2: return .pad
        case 3: return .tv
        case 4: return .watch
        case 6: return .visionOS
        default: return .unknown(rawValue)
        }
    }
}
