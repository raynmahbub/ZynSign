import Foundation

/// The top-level sections of the ZynSign shell — the app's primary tabs.
///
/// The order here is the tab order the user sees. Every section is a real
/// area in this build; none is a dead placeholder. The shell is a pure
/// presentation concern — it decides order, titles and icons, nothing about
/// workflow logic.
enum ShellSection: Hashable, CaseIterable, Identifiable {
    case files
    case library
    case home
    case appStore
    case downloads
    case settings

    var id: Self { self }

    /// The navigation title of the section.
    var title: String {
        switch self {
        case .files: return "Files"
        case .library: return "Library"
        case .home: return "Home"
        case .appStore: return "App Store"
        case .downloads: return "Downloads"
        case .settings: return "Settings"
        }
    }

    /// The SF Symbol shown for the section's tab and navigation entry.
    var symbolName: String {
        switch self {
        case .files: return "folder.fill"
        case .library: return "square.grid.2x2.fill"
        case .home: return "house.fill"
        case .appStore: return "bag.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .settings: return "gearshape.fill"
        }
    }

    /// The symbol for the unselected state (used where a filled variant is too heavy).
    var symbolNameUnselected: String {
        switch self {
        case .files: return "folder"
        case .library: return "square.grid.2x2"
        case .home: return "house"
        case .appStore: return "bag"
        case .downloads: return "arrow.down.circle"
        case .settings: return "gearshape"
        }
    }

    /// An honest description of what the section is for. Used by
    /// `PlaceholderFeatureView` only if a section has no dedicated view yet —
    /// none of the six do, so this is a fallback for previews and diagnostics.
    var statusSummary: String {
        switch self {
        case .files:
            return "Browse and manage files ZynSign keeps — imported packages, working copies, and exported artifacts. Import, share, move and delete without leaving the app."
        case .library:
            return "Imported packages recorded in ZynSign's library —kept across launches, with the files inside each application bundle listed read-only."
        case .home:
            return "Overview of your library, recent activity, and quick actions."
        case .appStore:
            return "Discover and download applications from your configured sources."
        case .downloads:
            return "Download packages from URLs, track progress, and import them into the library when finished."
        case .settings:
            return "Manage certificates, signing preferences, appearance and storage."
        }
    }
}
