import Foundation

/// Product areas used to organize the in-app feature catalogue.
enum FeatureCatalogCategory: String, CaseIterable, Hashable, Identifiable, Sendable {
    case importAndLibrary
    case signing
    case discovery
    case inspection
    case workspace
    case delivery
    case diagnostics
    case security
    case customization
    case platformLimits

    var id: Self { self }

    var title: String {
        switch self {
        case .importAndLibrary: return "Import & Library"
        case .signing: return "Identity & Signing"
        case .discovery: return "Discovery & Downloads"
        case .inspection: return "Inspection & Validation"
        case .workspace: return "Workspace"
        case .delivery: return "Delivery & Continuity"
        case .diagnostics: return "Diagnostics & Performance"
        case .security: return "Security & Privacy"
        case .customization: return "Customization"
        case .platformLimits: return "Platform Limits"
        }
    }

    var symbolName: String {
        switch self {
        case .importAndLibrary: return "square.stack.3d.up"
        case .signing: return "signature"
        case .discovery: return "globe.americas"
        case .inspection: return "viewfinder"
        case .workspace: return "rectangle.3.group"
        case .delivery: return "paperplane"
        case .diagnostics: return "waveform.path.ecg"
        case .security: return "lock.shield"
        case .customization: return "slider.horizontal.3"
        case .platformLimits: return "iphone.gen3.radiowaves.left.and.right"
        }
    }
}

/// Why a catalogue entry is available, staged, or intentionally unsupported.
enum FeatureCatalogAvailability: Equatable, Sendable {
    case alwaysAvailable
    case releaseGated(ReleaseFeature)
    case notSupported

    var releaseFeature: ReleaseFeature? {
        guard case .releaseGated(let feature) = self else { return nil }
        return feature
    }
}

enum FeatureCatalogStatus: Equatable, Sendable {
    case available
    case staged(tag: String)
    case notSupported

    var label: String {
        switch self {
        case .available: return "Available"
        case .staged(let tag): return "Planned · \(tag)"
        case .notSupported: return "Not supported"
        }
    }
}

/// One user-facing capability, including its honest release availability.
struct FeatureCatalogEntry: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let summary: String
    let category: FeatureCatalogCategory
    let availability: FeatureCatalogAvailability

    func status(in gate: ReleaseGate) -> FeatureCatalogStatus {
        switch availability {
        case .alwaysAvailable:
            return .available
        case .notSupported:
            return .notSupported
        case .releaseGated(let feature):
            guard !gate.isAvailable(feature) else { return .available }
            let stage = ReleaseStage.allCases.first { $0.introducedFeatures.contains(feature) }
            return .staged(tag: stage?.tag ?? "a future release")
        }
    }
}

/// Always-on product capabilities. `allCases` feeds the catalogue; a new
/// case is included automatically, and exhaustive metadata switches make its
/// title, category, and user-facing description compile-time requirements.
enum CoreFeature: String, CaseIterable, Sendable {
    case importHub = "import-hub"
    case applicationLibrary = "application-library"
    case filesAndStorage = "files"
    case bundleExplorer = "bundle-explorer"
    case binaryInspector = "binary-inspector"
    case resourceStudio = "resource-studio"
    case compatibilityLab = "compatibility-lab"
    case homeDashboard = "home-dashboard"
    case featureIndex = "feature-index"
    case tweakLibrary = "tweak-library"
    case releaseFeeds = "release-feeds"
    case revocationCenter = "revocation-center"
    case appProtection = "app-protection"
    case encryptedBackups = "encrypted-backups"
    case onDevicePrivacy = "privacy"
    case appearanceAndPreferences = "themes-storage"
    case versionHistory = "version-history"

    var catalogEntry: FeatureCatalogEntry {
        FeatureCatalogEntry(
            id: "core.\(rawValue)",
            title: title,
            summary: summary,
            category: category,
            availability: .alwaysAvailable
        )
    }

    private var title: String {
        switch self {
        case .importHub: return "Smart Import Hub"
        case .applicationLibrary: return "Application Library"
        case .filesAndStorage: return "Files & Storage"
        case .bundleExplorer: return "Bundle Explorer"
        case .binaryInspector: return "Binary & Signature Inspector"
        case .resourceStudio: return "Resource & Asset Studio"
        case .compatibilityLab: return "Compatibility Lab"
        case .homeDashboard: return "Home Dashboard"
        case .featureIndex: return "Feature Index"
        case .tweakLibrary: return "Tweak Library"
        case .releaseFeeds: return "Release Feeds"
        case .revocationCenter: return "Revocation Center"
        case .appProtection: return "App Protection"
        case .encryptedBackups: return "Encrypted Backup & Recovery"
        case .onDevicePrivacy: return "On-device Privacy"
        case .appearanceAndPreferences: return "Appearance & Preferences"
        case .versionHistory: return "Version History"
        }
    }

    private var summary: String {
        switch self {
        case .importHub:
            return "Import .ipa, .tipa, and ZIP packages from Files, Open In, or drag and drop. Review validation, queue progress, retries, history, archive choices, and duplicate conflicts before import."
        case .applicationLibrary:
            return "Keep imported applications locally with persistent records, duplicate detection, basic search, and read-only details."
        case .filesAndStorage:
            return "Browse, share, move, and remove files ZynSign owns, with storage usage and cleanup controls."
        case .bundleExplorer:
            return "Explore an application's bundle structure and metadata without modifying the imported package."
        case .binaryInspector:
            return "Inspect Mach-O headers, load commands, dependencies, and code-signature structure locally."
        case .resourceStudio:
            return "Inspect app icons, images, fonts, media, launch assets, and localization tables read-only."
        case .compatibilityLab:
            return "Review typed compatibility findings, regression coverage, and device-matrix evidence; unrun rows stay marked unrun."
        case .homeDashboard:
            return "See workspace summaries, import shortcuts, recent items, and guided next steps."
        case .featureIndex:
            return "Search the capability catalogue and filter available, staged, and unsupported items by release status."
        case .tweakLibrary:
            return "Import and organize optional payloads for a signing session; nothing is injected without an explicit signing choice."
        case .releaseFeeds:
            return "Follow configured release sources and review update information without silently installing or replacing apps."
        case .revocationCenter:
            return "Check whether certificate revocation channels can be reached; reachability is not a guarantee of future validity."
        case .appProtection:
            return "Optional biometric lock, session timeout, and per-app Lock and Vault controls. This is an interface guard, not encryption."
        case .encryptedBackups:
            return "Create and verify local encrypted backups, export them under your control, and restore selected categories after verification."
        case .onDevicePrivacy:
            return "Signing and inspection run locally. No off-device analytics or tracking service is composed."
        case .appearanceAndPreferences:
            return "Configure appearance, contrast, motion, haptics, landing tab, and local storage behavior."
        case .versionHistory:
            return "Review the app's release history and the changes recorded for each version."
        }
    }

    private var category: FeatureCatalogCategory {
        switch self {
        case .importHub, .applicationLibrary, .filesAndStorage:
            return .importAndLibrary
        case .bundleExplorer, .binaryInspector, .resourceStudio, .compatibilityLab:
            return .inspection
        case .homeDashboard, .featureIndex, .versionHistory:
            return .workspace
        case .tweakLibrary:
            return .signing
        case .releaseFeeds:
            return .discovery
        case .revocationCenter, .appProtection, .encryptedBackups, .onDevicePrivacy:
            return .security
        case .appearanceAndPreferences:
            return .customization
        }
    }
}

/// Platform capabilities that this app intentionally does not claim.
/// These are registered like core features so new disclosures automatically
/// appear in the same searchable catalogue.
enum UnsupportedFeature: String, CaseIterable, Sendable {
    case inAppInstallation = "in-app-installation"
    case pairingJITAndMux = "pairing-jit-mux"
    case cloudSyncAndTelemetry = "cloud-telemetry"

    var catalogEntry: FeatureCatalogEntry {
        FeatureCatalogEntry(
            id: "limit.\(rawValue)",
            title: title,
            summary: summary,
            category: .platformLimits,
            availability: .notSupported
        )
    }

    private var title: String {
        switch self {
        case .inAppInstallation: return "In-app installation"
        case .pairingJITAndMux: return "Pairing, JIT & device mux"
        case .cloudSyncAndTelemetry: return "Cloud sync & telemetry"
        }
    }

    private var summary: String {
        switch self {
        case .inAppInstallation:
            return "Not supported on stock iOS. ZynSign can prepare delivery instructions and artifacts, but it does not install arbitrary IPA files."
        case .pairingJITAndMux:
            return "Not implemented. These capabilities require platform services and entitlements that this app does not claim to have."
        case .cloudSyncAndTelemetry:
            return "No cloud synchronization, remote analytics, or tracking endpoint is provided by this build."
        }
    }
}

/// Complete, data-driven product capability inventory.
///
/// `CoreFeature.allCases`, `ReleaseFeature.allCases`, and
/// `UnsupportedFeature.allCases` supply every item. New cases are therefore
/// included automatically; exhaustive metadata switches force each addition
/// to explain itself rather than silently disappearing from the tab.
enum FeatureCatalog {
    static var coreEntries: [FeatureCatalogEntry] {
        CoreFeature.allCases.map(\.catalogEntry)
    }

    static var releaseEntries: [FeatureCatalogEntry] {
        ReleaseFeature.allCases.map { feature in
            FeatureCatalogEntry(
                id: "release.\(feature.rawValue)",
                title: feature.displayName,
                summary: feature.catalogSummary,
                category: feature.catalogCategory,
                availability: .releaseGated(feature)
            )
        }
    }

    static var unsupportedEntries: [FeatureCatalogEntry] {
        UnsupportedFeature.allCases.map(\.catalogEntry)
    }

    static var allEntries: [FeatureCatalogEntry] {
        coreEntries + releaseEntries + unsupportedEntries
    }
}

private extension ReleaseFeature {
    var catalogCategory: FeatureCatalogCategory {
        switch self {
        case .certificateStudio, .provisioningProfileManager, .identityCenter:
            return .signing
        case .smartSign, .signingQueue, .signingPresets, .batchSigning, .signingHealthScore:
            return .signing
        case .entitlementsStudio:
            return .inspection
        case .appStore, .downloads:
            return .discovery
        case .missionControl, .smartWorkspace, .novaAssistant:
            return .workspace
        case .deliveryHandoff, .installationWorkspace:
            return .delivery
        case .activityJournal, .performanceDashboard:
            return .diagnostics
        case .libraryPowerFeatures:
            return .importAndLibrary
        }
    }

    var catalogSummary: String {
        switch self {
        case .certificateStudio:
            return "Import .p12/.pfx signing identities, inspect public certificate details, and keep private keys in the Keychain."
        case .smartSign:
            return "Run the validated, nine-stage on-device signing pipeline with nested-code handling and independent output verification."
        case .entitlementsStudio:
            return "Inspect entitlements and profile compatibility read-only; signing derives entitlement data from the selected profile."
        case .appStore:
            return "Browse configured AltStore-compatible repositories and inspect source health before choosing an app."
        case .downloads:
            return "Queue package downloads, validate archives before import, review updates, and see honest transfer-resume state."
        case .missionControl:
            return "Refresh repositories and workspace data from Home with a user-visible completion summary."
        case .deliveryHandoff:
            return "Prepare an OTA manifest, encoded link, QR code, and operator instructions for a hosted signed IPA; this is not an installer."
        case .activityJournal:
            return "Review, export, or clear bounded local activity history. Events remain on-device and contain no package identifiers."
        case .libraryPowerFeatures:
            return "Use collections, saved views, richer search and filters, bulk selection, and library quick actions."
        case .provisioningProfileManager:
            return "Import and inspect provisioning profiles, track expiration, run compatibility checks, and select a profile per app."
        case .identityCenter:
            return "Review teams, certificates, profiles, relationships, conflicts, identity health, expiry forecasts, and history together."
        case .signingQueue:
            return "Queue signing jobs, monitor stages, control priorities, cancel, and retry recoverable failures."
        case .signingPresets:
            return "Save reusable signing choices and compatibility checks without storing passwords or private-key material."
        case .batchSigning:
            return "Plan and run multiple signing jobs with reviewable results and signing history."
        case .installationWorkspace:
            return "Review delivery readiness, user-confirmed installed-app records, attempts, history, and storage; ZynSign does not install."
        case .signingHealthScore:
            return "Assess identity, profile, and bundle compatibility before signing, with evidence-backed findings."
        case .performanceDashboard:
            return "Inspect local indexes and caches, run benchmarks, and review measured performance without presenting simulator data as device data."
        case .smartWorkspace:
            return "Personalize the Home command center with activity-aware widgets and session continuity."
        case .novaAssistant:
            return "Receive local, rule-based suggestions; Nova recommends, while every action stays with the user."
        }
    }
}
