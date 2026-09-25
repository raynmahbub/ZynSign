import Foundation

/// Analytics / Tracking — off-device measurement: explicitly none.
///
/// ZynSign ships with no `AnalyticsKit`, no telemetry sender, no crash
/// reporter SDK, and no outbound measurement endpoint. This file is the
/// single policy declaration that the presentation and platform layers
/// read, so the honest state is not inferred from "the code doesn't call
/// it" but from an explicit `isEnabled == false` with typed guarantees.
///
/// What this guarantees:
/// - No event, screen, or error is sent off-device — ever.
/// - No identifier (IDFV, IDFA, or custom) is collected for measurement.
/// - The only events kept at all are the **local activity journal**
///   (`LocalAnalyticsJournal`): on-device, user-visible in Settings,
///   one-tap clearable, and never transmitted. Recording respects the
///   `journalDefaultsKey` preference.
/// - Any future off-device measurement requires an ADR, an `Application`
///   port, a `Platform` implementation, user consent storage, and an
///   opt-in toggle in Settings. Until then, `AnalyticsPolicy` reports
///   `isEnabled == false` for measurement on every path.
///
/// This policy is deliberately tiny and `Equatable` so tests can assert it
/// without reaching into `UserDefaults` or `Info.plist`.
enum AnalyticsPolicy {

    /// Whether **off-device analytics** is enabled. Always `false` in
    /// every release through 1.0.0. The local activity journal is governed
    /// separately by `isJournalEnabled`.
    static let isEnabled = false

    /// Number of events transmitted. Always `0` when disabled — which is
    /// every path.
    static let eventCount = 0

    /// Whether any outbound measurement endpoint is configured. Always
    /// `nil` when disabled.
    static let endpoint: URL? = nil

    /// The user preference key that turns local journal recording on or
    /// off. Read by the environment's recording helper; surfaced by the
    /// Settings → Analytics screen.
    static let journalDefaultsKey = "zynsign.analytics.journalEnabled"

    /// The most events any journal holds. Pruning is the journal's own
    /// policy: old events fall off the front, nothing is archived.
    static let journalCapacity = 500

    /// Whether local journal recording is currently enabled.
    ///
    /// The default is enabled — the journal is on-device, redacted, and
    /// one tap to clear — and a stored `false` wins. Nothing is recorded
    /// while this is `false`; nothing is deleted either, so a cleared
    /// journal stays cleared.
    static var isJournalEnabled: Bool {
        let stored = UserDefaults.standard.object(forKey: journalDefaultsKey) as? Bool
        return stored ?? true
    }

    /// One presentation-safe sentence for Settings.
    static let summary = "Off-device analytics is disabled. A local, on-device activity journal may record events — they are never transmitted."

    /// Typed guarantees for Settings and `WHAT_DOES_NOT_EXIST.md`.
    enum Guarantee: String, CaseIterable, Hashable {
        case noAnalyticsKit
        case noTelemetryTransmission
        case noCrashReporterSDK
        case noOutboundEndpoint
        case noIdentifierCollection
        case localJournalOnly

        var message: String {
            switch self {
            case .noAnalyticsKit: return "No AnalyticsKit is linked into the app binary."
            case .noTelemetryTransmission: return "No telemetry event ever leaves the device."
            case .noCrashReporterSDK: return "No crash-reporter SDK is integrated."
            case .noOutboundEndpoint: return "No measurement endpoint is configured."
            case .noIdentifierCollection: return "No identifier is collected for measurement."
            case .localJournalOnly: return "The only events kept are a local, on-device journal — user-visible, one-tap clearable, never transmitted."
            }
        }
    }

    static var guarantees: [Guarantee] { Guarantee.allCases }

    struct Assessment: Equatable {
        let isEnabled: Bool
        let eventCount: Int
        let journalEnabled: Bool
        let guarantees: [Guarantee]
        let summary: String
    }

    static func assess() -> Assessment {
        Assessment(
            isEnabled: isEnabled,
            eventCount: eventCount,
            journalEnabled: isJournalEnabled,
            guarantees: guarantees,
            summary: summary
        )
    }
}
