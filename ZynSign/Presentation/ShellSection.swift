import Foundation

/// The sections of the ZynSign shell.
///
/// The five primary tabs are the navigation foundation the whole app is
/// built on: Home, Library, Certificates, Profiles, Settings. Three further
/// sections — Files, App Store, Downloads — are real, complete areas that
/// are reached from Settings → Browse rather than the tab bar; their place
/// in the shell is a presentation decision, not a statement about the
/// features themselves.
///
/// The shell is a pure presentation concern — it decides order, titles and
/// icons, nothing about workflow logic.
enum ShellSection: Hashable, CaseIterable, Identifiable {
    case home
    case library
    case certificates
    case profiles
    case settings
    case files
    case appStore
    case downloads
    case presets

    var id: Self { self }

    /// The sections that appear as tabs in the bottom navigation, in the
    /// order the user sees them. Home is first so a fresh install lands on
    /// the dashboard.
    static let primaryTabs: [ShellSection] = [.home, .library, .certificates, .profiles, .settings]

    /// The navigation title of the section.
    var title: String {
        switch self {
        case .home: return "Home"
        case .library: return "Library"
        case .certificates: return "Certificates"
        case .profiles: return "Profiles"
        case .settings: return "Settings"
        case .files: return "Files"
        case .appStore: return "App Store"
        case .downloads: return "Downloads"
        case .presets: return "Presets"
        }
    }

    /// The SF Symbol shown for the section's tab and navigation entry.
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
        case .presets: return "rectangle.stack.fill"
        }
    }

    /// The symbol for the unselected state (used where a filled variant is too heavy).
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
        case .presets: return "rectangle.stack"
        }
    }

    /// An honest description of what the section is for. Used by
    /// `PlaceholderFeatureView` only if a section has no dedicated view yet —
    /// none of the eight do, so this is a fallback for previews and
    /// diagnostics.
    var statusSummary: String {
        switch self {
        case .home:
            return "Overview of the library, quick actions, and what was imported most recently."
        case .library:
            return "Imported packages recorded in ZynSign's library — searchable, sortable, kept across launches, with the files inside each application bundle listed read-only."
        case .certificates:
            return "Signing identities in the Keychain — imported from .p12 containers, inspected, and never exportable with their private keys."
        case .profiles:
            return "Imported provisioning profiles — name, team, allowed bundle identifiers, and expiry, read from each profile's own declarations."
        case .settings:
            return "Signing preferences, appearance, storage, diagnostics, and the honest capability screens."
        case .files:
            return "Browse and manage files ZynSign keeps — imported packages, working copies, and exported artifacts. Import, share, move and delete without leaving the app."
        case .appStore:
            return "Discover and download applications from your configured sources."
        case .downloads:
            return "Download packages from URLs, track progress, and import them into the library when finished."
        case .presets:
            return "Reusable signing presets — certificate and profile references, options, and live compatibility. Presets do not store secrets."
        }
    }
}
