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

    /// The sections in the bottom navigation, in order:
    /// Files · Library · Home · App Store · Downloads · Settings.
    ///
    /// Certificates and Profiles are complete, reachable areas reached from
    /// Settings rather than tabs. The Store and Downloads stay in the shell at
    /// every release stop: they are primary navigation, and hiding them made
    /// the product appear to have lost working features in development builds.
    /// Release gates still control staged workflows inside each area.
    ///
    /// This is the full set of tab-capable sections, not the bar — the bar is
    /// `primaryTabs`, which honours `tabBarItemLimit`.
    static let allTabs: [ShellSection] = [.files, .library, .home, .appStore, .downloads, .settings]

    /// The platform ceiling on a tab bar: five items.
    ///
    /// A sixth is not drawn as a sixth. UIKit folds it into a generic "More"
    /// list and *pushes* that tab's view from a navigation controller of its
    /// own. Every ZynSign tab owns a `NavigationStack` (`RootView.tabContent`),
    /// and a stack inside a pushed destination is the crash
    /// `Scripts/audit_navigation_stack.py` was written to stop — the audit just
    /// cannot see this instance, because the push is UIKit's and appears nowhere
    /// in this codebase. So a six-section bar really means: five visible, one
    /// buried, and a crash the first time anyone opens the buried one. That is
    /// the whole of the "Settings tab crashes, App Store tab is missing" report.
    ///
    /// The bar is therefore capped, and the overflowed area stays reachable
    /// from Settings, where its own entry point already exists.
    static let tabBarItemLimit = 5

    /// Which sections give up a bar slot when the bar is over budget, least
    /// wanted first. Files, Library, Home and Settings can never be dropped:
    /// they are the core the development stops exist to prove, and Settings is
    /// where a section without a slot is opened from.
    ///
    /// Downloads yields first: it is a queue view, and two surfaces already
    /// open it — Settings → Updates and Store → Download Jobs. Its completion
    /// toast is posted at the root, so it survives the loss of the tab; the
    /// per-tab progress badge does not, and that is the cost accepted here.
    ///
    /// On iPad the bar can lay out more items without folding, but the shell
    /// stays at five so the two idioms do not disagree about where a feature
    /// lives on the smallest device the app ships to.
    static let tabOverflowOrder: [ShellSection] = [.downloads, .appStore, .files]

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
    ///
    /// The result is capped at `tabBarItemLimit`: past that, UIKit stops
    /// drawing tabs and starts pushing them.
    static func primaryTabs(where isAvailable: (ReleaseFeature) -> Bool) -> [ShellSection] {
        let wanted = allTabs.filter { section in
            if section == .appStore || section == .downloads { return true }
            return section.requiredFeature.map(isAvailable) ?? true
        }
        guard wanted.count > tabBarItemLimit else { return wanted }
        // Drop the least wanted sections that are actually present, and keep
        // the surviving order exactly as `allTabs` declares it — removing a
        // tab must never reshuffle the ones that stay.
        let present = tabOverflowOrder.filter { wanted.contains($0) }
        let dropped = Set(present.prefix(wanted.count - tabBarItemLimit))
        return wanted.filter { !dropped.contains($0) }
    }

    /// The tab to select when something asks to open `section`.
    ///
    /// Assigning a section with no slot to `TabView`'s selection is not a
    /// no-op: the bar ends up with nothing selected and the content area
    /// empty, which is what "I tapped it and nothing happened" looks like from
    /// the outside. Home's checklist does exactly this — steps two and three
    /// ask for Certificates and Profiles, and both live in Settings, not in
    /// the bar — so every "open this area" request resolves through here
    /// instead of reaching `selected` raw.
    ///
    /// A section that lost its slot to the five-item ceiling resolves the same
    /// way: to the surface that hosts it. Downloads is opened from
    /// Settings → Updates and from Store → Download Jobs, so folding it loses
    /// a shortcut, never a destination.
    static func tab(toOpen section: ShellSection) -> ShellSection {
        let tabs = primaryTabs
        if tabs.contains(section) { return section }
        return tabs.contains(.settings) ? .settings : (tabs.first ?? .settings)
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
