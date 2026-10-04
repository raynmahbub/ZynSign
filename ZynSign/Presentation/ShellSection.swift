import Foundation

/// Sections understood by the application shell.
///
/// Every destination a release exposes is a tab. The shell draws its own bar
/// (`ShellTabBar`) instead of UIKit's, so nothing has to be folded into a
/// *More* list and no destination is reached only by a detour — Store and
/// Downloads are tabs again, which is what a tester reported missing.
/// Certificates, Profiles, Presets, and the installation workspace are not
/// areas: they are workflows opened from Settings, and they stay there.
enum ShellSection: Hashable, CaseIterable, Identifiable {
    case home
    case library
    case certificates
    case profiles
    case settings
    case files
    case appStore
    case downloads
    case features
    case presets
    case install

    var id: Self { self }

    /// Every candidate destination, in bar order.
    static let allTabs: [ShellSection] = [
        .files, .library, .home, .appStore, .downloads, .features, .settings,
    ]

    /// What UIKit's own tab bar can draw before it folds the rest into a
    /// *More* list that it pushes.
    ///
    /// The shell does not use that bar (see `ShellTabBar`), and this number is
    /// kept only so the reason stays pinned by a test rather than by memory: a
    /// bar that can hold five items must never again decide which destinations
    /// a build shows.
    static let nativeTabBarItemLimit = 5

    /// The staged capability associated with a destination, if any.
    var requiredFeature: ReleaseFeature? {
        switch self {
        case .certificates: return .certificateStudio
        case .profiles: return .provisioningProfileManager
        case .appStore: return .appStore
        case .downloads: return .downloads
        case .presets: return .signingPresets
        case .install: return .installationWorkspace
        case .home, .library, .settings, .files, .features: return nil
        }
    }

    /// The visible tabs for a release gate. The predicate keeps the policy
    /// testable without coupling tests to a particular build configuration.
    ///
    /// Nothing is dropped for its position any more: a gated destination is
    /// shown when the stage exposes it and hidden when it does not, and every
    /// destination that survives the gate is drawn.
    static func primaryTabs(where isAvailable: (ReleaseFeature) -> Bool) -> [ShellSection] {
        allTabs.filter { section in
            section.requiredFeature.map(isAvailable) ?? true
        }
    }

    /// The tab to select for a requested destination. A destination that is a
    /// tab is selected; the workflows reached from Settings name Settings, and
    /// a build that somehow renders no Settings tab falls back to its first.
    static func tab(toOpen section: ShellSection) -> ShellSection {
        let tabs = primaryTabs
        if tabs.contains(section) { return section }
        return tabs.contains(.settings) ? .settings : (tabs.first ?? .settings)
    }

    /// The tabs exposed by the running release.
    static var primaryTabs: [ShellSection] {
        primaryTabs(where: ReleaseTrain.isAvailable)
    }

    /// Landing-tab choices must name a tab the shell actually renders.
    static var offerableLandingTabs: [LandingTab] {
        let tabs = primaryTabs
        return LandingTab.tabCases.filter { tabs.contains($0.shellSection) }
    }

    /// Resolves values saved by older builds to a real picker choice. Store
    /// and Downloads are tabs of their own again, so a saved Store or
    /// Downloads preference is honoured rather than migrated; retired
    /// Certificates and Profiles still resolve to the Library, where imported
    /// applications are.
    static func effectiveLandingTab(for stored: LandingTab) -> LandingTab {
        let migrated = stored.selectable
        return offerableLandingTabs.contains(migrated) ? migrated : .library
    }

    var title: String {
        switch self {
        case .home: return "Home"
        case .library: return "Library"
        case .certificates: return "Certificates"
        case .profiles: return "Profiles"
        case .settings: return "Settings"
        case .files: return "Files"
        case .appStore: return "Store"
        case .downloads: return "Downloads"
        case .features: return "Features"
        case .presets: return "Presets"
        case .install: return "Install"
        }
    }

    var symbolName: String {
        switch self {
        case .home: return "house.fill"
        case .library: return "square.grid.2x2.fill"
        case .certificates: return "signature"
        case .profiles: return "person.text.rectangle"
        case .settings: return "gearshape.fill"
        case .files: return "folder.fill"
        case .appStore: return "bag.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .features: return "square.grid.3x3.fill"
        case .presets: return "rectangle.stack.fill"
        case .install: return "arrow.down.app.fill"
        }
    }

    var symbolNameUnselected: String {
        switch self {
        case .home: return "house"
        case .library: return "square.grid.2x2"
        case .certificates: return "signature"
        case .profiles: return "person.text.rectangle"
        case .settings: return "gearshape"
        case .files: return "folder"
        case .appStore: return "bag"
        case .downloads: return "arrow.down.circle"
        case .features: return "square.grid.3x3"
        case .presets: return "rectangle.stack"
        case .install: return "arrow.down.app"
        }
    }

    /// Fallback description used by diagnostics and preview surfaces.
    var statusSummary: String {
        switch self {
        case .home:
            return "Overview of the library, quick actions, and recent activity."
        case .library:
            return "Imported application packages, kept across launches and inspected read-only."
        case .certificates:
            return "Signing identities imported from .p12 or .pfx containers; private keys remain in Keychain."
        case .profiles:
            return "Provisioning profiles with expiration, compatibility checks, and per-app suggestions."
        case .settings:
            return "Signing preferences, appearance, storage, diagnostics, and capability disclosures."
        case .files:
            return "Browse and manage files ZynSign keeps, including packages and exported artifacts."
        case .appStore:
            return "Discover applications from configured repositories."
        case .downloads:
            return "Manage package transfers, validation, and update reviews."
        case .features:
            return "Browse the complete catalogue of available, staged, and unsupported capabilities."
        case .presets:
            return "Reusable signing configurations; presets never store secrets."
        case .install:
            return "Review delivery readiness and history; ZynSign validates and records, it does not install."
        }
    }
}

extension LandingTab {
    /// The shell section a landing preference names. Old Store and Downloads
    /// values remain decodable and migrate through `selectable` to Features.
    var shellSection: ShellSection {
        switch self {
        case .files: return .files
        case .library: return .library
        case .home: return .home
        case .features: return .features
        case .settings: return .settings
        case .appStore: return .appStore
        case .downloads: return .downloads
        case .certificates: return .certificates
        case .profiles: return .profiles
        }
    }
}
