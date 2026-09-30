import Foundation

/// The sections of the ZynSign shell.
///
/// The six primary tabs are the navigation foundation the whole app is built
/// on: Files, Library, Home, App Store, Downloads, Settings. Certificates and
/// Profiles are real, complete areas that are reached from Settings rather
/// than the tab bar; their place in the shell is a presentation decision, not
/// a statement about the features themselves.
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
    case install

    var id: Self { self }

    /// The six sections in the bottom navigation, in order:
    /// Files · Library · Home · App Store · Downloads · Settings.
    ///
    /// Certificates and Profiles are complete, reachable areas in Settings →
    /// Browse rather than tabs. The Store and Downloads stay in the shell at
    /// every release stop: they are primary navigation, and hiding them made
    /// the product appear to have lost working features in development builds.
    /// Release gates still control staged workflows inside each area.
    static let allTabs: [ShellSection] = [.files, .library, .home, .appStore, .downloads, .settings]

    /// The staged capability associated with this section, when there is one.
    ///
    /// Store and Downloads retain their shell entry points at every stop, but
    /// their staged actions may still be gated. Certificates, Profiles,
    /// Presets and the Installation Workspace are reached through Settings.
    var requiredFeature: ReleaseFeature? {
        switch self {
        case .certificates: return .certificateStudio
        case .profiles: return .provisioningProfileManager
        case .appStore: return .appStore
        case .downloads: return .downloads
        case .presets: return .signingPresets
        case .install: return .installationWorkspace
        case .home, .library, .settings, .files: return nil
        }
    }

    /// The tabs a release shows, given an availability test.
    ///
    /// Store and Downloads are stable navigation destinations across release
    /// stops. Staged capabilities inside them remain gated at their own entry
    /// points. Taking the test as a parameter keeps the rest of the navigation
    /// policy testable without pretending the test host is on another stage.
    static func primaryTabs(where isAvailable: (ReleaseFeature) -> Bool) -> [ShellSection] {
        allTabs.filter { section in
            if section == .appStore || section == .downloads { return true }
            return section.requiredFeature.map(isAvailable) ?? true
        }
    }

    /// The sections that appear as tabs in the bottom navigation at the
    /// release this build is cut for. Store and Downloads stay discoverable;
    /// other staged tab destinations still follow the release gate.
    static var primaryTabs: [ShellSection] {
        primaryTabs(where: ReleaseTrain.isAvailable)
    }

    /// The navigation title of the section.
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
        case .presets: return "Presets"
        case .install: return "Install"
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
        case .install: return "arrow.down.app.fill"
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
        case .install: return "arrow.down.app"
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
            return "Imported provisioning profiles — searchable, sortable, and filterable, with expiration countdowns, pre-sign compatibility checks, actionable diagnostics, and per-app suggestions."
        case .settings:
            return "Signing preferences, appearance, storage, diagnostics, and the honest capability screens."
        case .files:
            return "Browse and manage files ZynSign keeps — imported packages, working copies, and exported artifacts. Import, share, move and delete without leaving the app."
        case .appStore:
            return "Discover and download applications from your configured sources."
        case .downloads:
            return "Download packages, validate them before import, and review updates from configured sources."
        case .presets:
            return "Reusable signing presets — certificate and profile references, options, and live compatibility. Presets do not store secrets."
        case .install:
            return "The Installation Workspace — readiness checklists, the Installed Apps Library, delivery attempts you confirm yourself, history, and storage. ZynSign validates and records; delivery is yours."
        }
    }
}

extension LandingTab {

    /// The shell section a landing-tab preference names.
    ///
    /// The mapping lives here rather than in the preference so a change to the
    /// shell's tabs does not change what a stored preference means.
    var shellSection: ShellSection {
        switch self {
        case .files: return .files
        case .library: return .library
        case .home: return .home
        case .appStore: return .appStore
        case .downloads: return .downloads
        case .settings: return .settings
        case .certificates: return .certificates
        case .profiles: return .profiles
        }
    }
}
