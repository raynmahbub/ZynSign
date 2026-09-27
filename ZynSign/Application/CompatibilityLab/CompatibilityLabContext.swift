import Foundation

/// Whether the Compatibility Lab is composed into this build.
///
/// The Lab is validation apparatus, not a feature: it exists so a release
/// can be judged, and a user has no reason to find it. It is therefore
/// compiled out of Release builds entirely — not hidden behind a flag that
/// still ships the code — and present in Debug builds and in internal
/// builds made with the `ZYNSIGN_INTERNAL` compilation condition.
///
/// A Debug build can still switch the Lab off with the launch argument
/// `-ZynSignCompatibilityLab 0` when a screenshot run needs the Settings
/// screen to look exactly as a user's does.
enum CompatibilityLabAvailability {

    /// `UserDefaults` key and launch-argument name for the override.
    static let overrideKey = "ZynSignCompatibilityLab"

    /// Whether this build offers the Lab.
    static var isAvailable: Bool {
        #if DEBUG || ZYNSIGN_INTERNAL
        return !isExplicitlyDisabled
        #else
        return false
        #endif
    }

    /// Whether this build compiled the Lab in at all. The Settings catalog
    /// asks this, so its section list is the same in every build.
    static var isCompiledIn: Bool {
        #if DEBUG || ZYNSIGN_INTERNAL
        return true
        #else
        return false
        #endif
    }

    /// One line for the release-readiness footer: a Release build that
    /// cannot show the Lab says so rather than looking like a gap.
    static var availabilityNote: String {
        isCompiledIn
            ? "The Compatibility Lab is compiled into Debug and internal builds only."
            : "This is a Release build: the Compatibility Lab is not compiled in. Run it from a Debug or internal build."
    }

    #if DEBUG || ZYNSIGN_INTERNAL
    /// Whether the launch argument or the defaults key turned the Lab off.
    private static var isExplicitlyDisabled: Bool {
        if CommandLine.arguments.contains("-" + overrideKey + " 0") { return true }
        if let raw = UserDefaults.standard.string(forKey: overrideKey) {
            return raw == "0" || raw.lowercased() == "false"
        }
        return false
    }
    #endif
}

/// Results a maintainer brings to the Lab from a run it cannot make itself.
///
/// Some checks cannot execute inside the app: the unit-test target's result
/// belongs to the test runner, and a device class this device is not belongs
/// to another device. Rather than invent a pass, the Lab reports `not run`
/// and offers to read the answer from an overlay — a small JSON file a
/// maintainer drops into `Documents/Diagnostics`, or CI publishes as an
/// artifact — whose entries name their source and are shown as such.
///
/// An overlay can only fill a check that did not run. It can never overturn
/// a result the Lab measured itself.
struct CompatibilityLabOverlay: Codable, Equatable, Sendable {

    /// Where the entries came from, shown next to every status they supply.
    let source: String

    /// The status per check identifier.
    let statuses: [String: CompatibilityStatus]

    /// An overlay with no entries.
    static let empty = CompatibilityLabOverlay(source: "none", statuses: [:])

    init(source: String, statuses: [String: CompatibilityStatus]) {
        self.source = source
        self.statuses = statuses
    }

    /// The recorded status for `checkID`, when the overlay carries one.
    func status(for checkID: String) -> CompatibilityStatus? {
        statuses[checkID]
    }

    /// Reads an overlay from `location`. A missing or unreadable file is an
    /// empty overlay, not an error: the Lab simply reports what it measured.
    static func load(from location: URL, fileManager: FileManager = .default) -> CompatibilityLabOverlay {
        guard let data = fileManager.contents(atPath: location.path) else { return .empty }
        guard let decoded = try? decode(from: data) else { return .empty }
        return decoded
    }

    static func decode(from data: Data) throws -> CompatibilityLabOverlay {
        try JSONDecoder().decode(CompatibilityLabOverlay.self, from: data)
    }
}

/// Everything a suite is given to work with.
///
/// Suites receive the dependencies they need rather than reaching for them,
/// so a suite can run against a scratch directory in a test exactly as it
/// runs on a device. The environment is optional because the Lab is also
/// composed in unit tests, where the full application environment is not
/// what is under test.
struct CompatibilityLabContext: @unchecked Sendable {

    /// The clock every duration is measured with.
    let now: @Sendable () -> Date

    /// The file manager suites read and write through.
    let fileManager: FileManager

    /// The directory suites may create their working files under. The Lab
    /// creates it on demand and removes what it made when it is done.
    let scratchRoot: URL

    /// The saved preferences, for the settings a check depends on.
    let preferences: ZynSignPreferences

    /// The application environment, when one was composed.
    let environment: ApplicationEnvironment?

    /// Results imported from a run the Lab cannot make itself.
    let overlay: CompatibilityLabOverlay

    init(
        now: @escaping @Sendable () -> Date = { Date() },
        fileManager: FileManager = .default,
        scratchRoot: URL,
        preferences: ZynSignPreferences = .shippedDefault,
        environment: ApplicationEnvironment? = nil,
        overlay: CompatibilityLabOverlay = .empty
    ) {
        self.now = now
        self.fileManager = fileManager
        self.scratchRoot = scratchRoot
        self.preferences = preferences
        self.environment = environment
        self.overlay = overlay
    }

    /// Measures one piece of work, returning its result and how long it took.
    func measure<Result>(_ work: () throws -> Result) rethrows -> (result: Result, milliseconds: Int) {
        let started = now()
        let result = try work()
        let elapsed = now().timeIntervalSince(started) * 1_000
        return (result, Int(elapsed.rounded()))
    }

    /// Measures one asynchronous piece of work the same way.
    func measure<Result>(_ work: () async throws -> Result) async rethrows -> (result: Result, milliseconds: Int) {
        let started = now()
        let result = try await work()
        let elapsed = now().timeIntervalSince(started) * 1_000
        return (result, Int(elapsed.rounded()))
    }

    /// Applies the overlay to a check that did not run, keeping the Lab's own
    /// measurements authoritative.
    ///
    /// A check that ran keeps its result. A check that did not run adopts the
    /// overlay's answer and says where it came from, so a reader never
    /// mistakes an imported result for a measured one.
    func applyingOverlay(to check: CompatibilityCheck) -> CompatibilityCheck {
        guard !check.status.isSettled, let status = overlay.status(for: check.id) else {
            return check
        }
        return CompatibilityCheck(
            id: check.id,
            category: check.category,
            title: check.title,
            status: status,
            summary: check.summary,
            verified: check.verified,
            nextStep: check.nextStep,
            evidence: check.evidence + ["Result imported from overlay: \(overlay.source)."],
            measurements: check.measurements,
            durationMilliseconds: check.durationMilliseconds,
            blocker: check.blocker
        )
    }
}
