import Foundation

/// A user-visible feature that ships on the release train.
///
/// The code for every feature is already complete and compiled into every
/// build. What changes from release to release is only which features the
/// interface *exposes*. Each case names one entry point (a tab, a Settings
/// row, a menu action) that the Presentation layer checks through
/// `ReleaseTrain.isAvailable(_:)`.
///
/// Core behaviour — import, inspection, the library, the bundle explorer,
/// Files, Home, and the honest Settings screens — is not a `ReleaseFeature`:
/// it ships in every release, so there is nothing to gate.
enum ReleaseFeature: String, CaseIterable, Hashable, Sendable {
    /// Settings → Certificates: `.p12`/`.pfx` import, detail, public JSON export.
    case certificateStudio
    /// The nine-stage signing pipeline: `Sign Application…`, Signing Options,
    /// the Library “Signed” segment, Settings → Installation.
    case smartSign
    /// Alpha 3: read-only app entitlements and profile compatibility workspace.
    case entitlementsStudio
    /// The App Store tab: AltSource feeds and repository health.
    case appStore
    /// The Downloads tab: Download Center queue, validation, and updates.
    case downloads
    /// Home → Mission Control (Refresh Everything).
    case missionControl
    /// Signing result → Deliver… (OTA manifest, install link, QR, guides).
    case deliveryHandoff
    /// Settings → Analytics → Local Activity Journal, and journal recording.
    case activityJournal

    /// Alpha 2: Library power features — favorites, recently imported,
    /// collections, advanced search, filters, bulk selection, quick actions.
    case libraryPowerFeatures

    /// Alpha 3: Identity management — provisioning profile manager,
    /// expiration warnings, compatibility diagnostics.
    case provisioningProfileManager

    /// Alpha 3: the Developer Identity Center — the unified dashboard,
    /// team workspace, certificate and profile inspectors, relationship
    /// graph, health center, conflict detection, expiration forecast,
    /// identity timeline, and the signing screen's recommended identity.
    case identityCenter

    /// Alpha 2: Professional Signing Queue — the job-based signing system:
    /// queue dashboard, priorities, per-job controls, live stage progress,
    /// failure recovery, persistence, and bulk queue operations.
    case signingQueue

    /// Alpha 2: Intelligent signing presets — library, builder, matching,
    /// one-tap confirmation, and bulk planning into the signing queue.
    case signingPresets

    /// Beta 3: Productivity — batch signing and signing history.
    case batchSigning

    /// Beta 2: The Installation Workspace — readiness checklists, the
    /// Installed Apps Library, delivery attempts and confirmations,
    /// installation history, the artifact relationship view, bulk
    /// preparation, and storage awareness.
    case installationWorkspace

    /// v1.0.0 distinguishing feature: pre-sign compatibility assessment
    /// that predicts whether a (identity, profile, bundle) combination
    /// will succeed before the pipeline runs.
    case signingHealthScore

    /// Beta 2 distinguishing feature: the hidden Performance page under
    /// Settings → Advanced, backed by the Performance Engine — library and
    /// index counts, cache statistics by category, the search-index
    /// status, benchmarks with regression detection, and manual
    /// optimization.
    case performanceDashboard

    /// v3.0 Nova: the Smart Workspace 3.0 — Home becomes the command
    /// center: greeting, usage-ordered widgets, Continue Last Session.
    case smartWorkspace

    /// v3.0 Nova: the Nova Assistant — on-device, rule-based suggestions
    /// (expiring identities, matching profiles, duplicates, backups). It
    /// only recommends; every action stays with the user.
    case novaAssistant

    /// Features that must already be available for this one to make sense.
    ///
    /// A release that exposes a feature without its prerequisites would show
    /// a dead end (for example “Sign” with no way to add a certificate), so
    /// `ReleaseStage` validation refuses that.
    var prerequisites: Set<ReleaseFeature> {
        switch self {
        case .certificateStudio: return []
        case .smartSign: return [.certificateStudio]
        case .entitlementsStudio: return [.smartSign]
        case .appStore: return [.downloads]      // “Get” hands off to Downloads
        case .downloads: return []
        case .missionControl: return [.appStore] // refreshes sources
        case .deliveryHandoff: return [.smartSign]
        case .activityJournal: return []
        case .libraryPowerFeatures: return []
        case .provisioningProfileManager: return [.smartSign]
        case .identityCenter: return [.certificateStudio, .smartSign, .provisioningProfileManager]
        case .signingQueue: return [.smartSign]
        case .signingPresets: return [.smartSign, .certificateStudio]
        case .batchSigning: return [.signingPresets]
        case .installationWorkspace: return [.deliveryHandoff]
        case .signingHealthScore: return [.smartSign, .signingPresets]
        case .performanceDashboard: return [.libraryPowerFeatures]
        case .smartWorkspace: return [.missionControl, .identityCenter]
        case .novaAssistant: return [.smartWorkspace]
        }
    }

    /// The features that belong to the v3.0 Nova release.
    static let nova: Set<ReleaseFeature> = [.novaAssistant]

    /// Short human name, used by release notes tooling and diagnostics.
    var displayName: String {
        switch self {
        case .certificateStudio: return "Certificate Studio"
        case .smartSign: return "Smart Sign"
        case .entitlementsStudio: return "Entitlements Studio"
        case .appStore: return "App Store & Repository Health"
        case .downloads: return "Download Center"
        case .missionControl: return "Mission Control"
        case .deliveryHandoff: return "Installation Delivery Hand-off"
        case .activityJournal: return "Local Activity Journal"
        case .libraryPowerFeatures: return "Library Power Features"
        case .provisioningProfileManager: return "Provisioning Profile Manager"
        case .identityCenter: return "Developer Identity Center"
        case .signingQueue: return "Professional Signing Queue"
        case .signingPresets: return "Intelligent Signing Presets"
        case .batchSigning: return "Batch Signing"
        case .installationWorkspace: return "Installation Workspace"
        case .signingHealthScore: return "Signing Health Score"
        case .performanceDashboard: return "Performance Engine"
        case .smartWorkspace: return "Smart Workspace"
        case .novaAssistant: return "Nova Assistant"
        }
    }
}

/// One stop on the release train described in
/// `docs/releases/version-strategy.md` and `docs/releases/release-train.md`.
///
/// Stages are declared in shipping order. Each stage adds features on top of
/// the previous one; nothing is ever taken away from users in a later stage.
enum ReleaseStage: String, CaseIterable, Comparable, Sendable {
    case horizon      // 0.1.0
    case alpha1       // 0.1.0-alpha.1
    case alpha2       // 0.1.0-alpha.2
    case alpha3       // 0.1.0-alpha.3
    case beta1        // 0.9.0-beta.1
    case beta2
    case beta3
    case beta4
    case rc1          // 1.0.0-rc.1
    case rc2
    case rc3
    case stable       // 1.0.0
    case professional // 2.0.0 — Professional Platform (fixes and depth; no new gate)
    case nova1        // 3.0.0-nova.1 — Nova preview: Nova Assistant
    case nova         // 3.0.0 — Nova: the remaining areas of the roadmap

    /// The Git tag / GitHub release version, without the leading `v`.
    var version: String {
        switch self {
        case .horizon: return "0.1.0"
        case .alpha1: return "0.1.0-alpha.1"
        case .alpha2: return "0.1.0-alpha.2"
        case .alpha3: return "0.1.0-alpha.3"
        case .beta1: return "0.9.0-beta.1"
        case .beta2: return "0.9.0-beta.2"
        case .beta3: return "0.9.0-beta.3"
        case .beta4: return "0.9.0-beta.4"
        case .rc1: return "1.0.0-rc.1"
        case .rc2: return "1.0.0-rc.2"
        case .rc3: return "1.0.0-rc.3"
        case .stable: return "1.0.0"
        case .professional: return "2.0.0"
        case .nova1: return "3.0.0-nova.1"
        case .nova: return "3.0.0"
        }
    }

    /// The Git tag for this stage.
    var tag: String { "v\(version)" }

    /// `CFBundleShortVersionString` for this stage.
    ///
    /// Apple requires a purely numeric marketing version, so the
    /// pre-release suffix lives only in the tag; every build still gets a
    /// fresh `CFBundleVersion`.
    var marketingVersion: String {
        String(version.prefix { $0 != "-" })
    }

    /// Features this stage introduces (in addition to all earlier stages).
    var introducedFeatures: Set<ReleaseFeature> {
        switch self {
        case .horizon: return []
        case .alpha1: return [.certificateStudio, .libraryPowerFeatures]
        case .alpha2: return [.smartSign, .provisioningProfileManager, .signingQueue, .signingPresets]
        case .alpha3: return [.appStore, .downloads, .entitlementsStudio, .identityCenter]
        case .beta1: return [.missionControl, .deliveryHandoff, .activityJournal]
        case .beta2: return [.installationWorkspace, .performanceDashboard]
        case .beta3: return [.batchSigning]
        case .beta4: return []
        case .rc1, .rc3: return []
        case .rc2: return [.smartWorkspace]   // Mission Control home — the RC 2 UX pass
        case .stable: return [.signingHealthScore]
        case .professional: return []
        case .nova1: return [.novaAssistant]
        case .nova: return []
        }
    }

    /// Every feature available in this stage: its own plus all earlier ones.
    var features: Set<ReleaseFeature> {
        ReleaseStage.allCases
            .filter { $0 <= self }
            .reduce(into: Set<ReleaseFeature>()) { $0.formUnion($1.introducedFeatures) }
    }

    /// The stage that ships after this one, if any.
    var next: ReleaseStage? {
        let all = ReleaseStage.allCases
        guard let index = all.firstIndex(of: self), index + 1 < all.count else { return nil }
        return all[index + 1]
    }

    static func < (lhs: ReleaseStage, rhs: ReleaseStage) -> Bool {
        let all = ReleaseStage.allCases
        // Both stages are declared in `allCases`, so both indices exist.
        // The guard keeps that a fact the compiler checks rather than an
        // assumption a trap would enforce: ordering two stages that are not
        // on the train as equal leaves the comparator total.
        guard let left = all.firstIndex(of: lhs), let right = all.firstIndex(of: rhs) else {
            return false
        }
        return left < right
    }

    /// Looks a stage up by its raw name (`alpha1`) or its version (`0.1.0-alpha.1` / `v0.1.0-alpha.1`).
    init?(identifier: String) {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if let stage = ReleaseStage(rawValue: trimmed) { self = stage; return }
        let version = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        guard let stage = ReleaseStage.allCases.first(where: { $0.version == version }) else { return nil }
        self = stage
    }
}

/// Decides which features the running build exposes.
///
/// **To ship the next release, change `current` (or run
/// `python3 Scripts/release_train.py promote`) — nothing else.**
///
/// Debug builds expose every feature so development and UI work are never
/// blocked. To preview exactly what a given release will look like in a
/// Debug build, pass the launch argument `-ZynSignReleaseStage alpha1`
/// (or any stage name / version) in the Xcode scheme.
enum ReleaseTrain {

    /// The release this build is cut for. Edited by `Scripts/release_train.py`.
    static let current: ReleaseStage = .rc2

    /// `UserDefaults` / launch-argument key for the Debug-only preview override.
    static let previewDefaultsKey = "ZynSignReleaseStage"

    /// The gate the running build uses.
    static var gate: ReleaseGate {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: previewDefaultsKey),
           let preview = ReleaseStage(identifier: raw) {
            return ReleaseGate(stage: preview, exposesEverything: false)
        }
        return ReleaseGate(stage: current, exposesEverything: true)
        #else
        return ReleaseGate(stage: current, exposesEverything: false)
        #endif
    }

    /// Whether `feature` is available to the user in this build.
    static func isAvailable(_ feature: ReleaseFeature) -> Bool {
        gate.isAvailable(feature)
    }
}

/// A pure, testable answer to “is this feature on?”.
struct ReleaseGate: Equatable, Sendable {
    let stage: ReleaseStage
    /// `true` in Debug builds without a preview override.
    let exposesEverything: Bool

    func isAvailable(_ feature: ReleaseFeature) -> Bool {
        exposesEverything || stage.features.contains(feature)
    }

    /// Short description for Settings → Diagnostics.
    var summary: String {
        if exposesEverything { return "\(stage.tag) · Debug (all features)" }
        return "\(stage.tag) · \(stage.features.count) of \(ReleaseFeature.allCases.count) staged features"
    }
}
