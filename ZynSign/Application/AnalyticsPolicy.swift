import Foundation

/// Analytics / Tracking — explicitly none.
///
/// ZynSign ships with no `AnalyticsKit`, no telemetry, no crash reporter SDK,
/// and no outbound measurement endpoint. This file is the single policy
/// declaration that the presentation and platform layers read, so the honest
/// state is not inferred from “the code doesn’t call it” but from an
/// explicit `isEnabled == false` with typed guarantees.
///
/// What this guarantees:
/// - No event, screen, or error is sent off-device.
/// - No identifier (IDFV, IDFA, or custom) is collected for measurement.
/// - `DiagnosticsView` shows only on-device, redacted diagnostics.
/// - Any future measurement requires an ADR, an `Application` port, a
///   `Platform` implementation, user consent storage, and an opt-in toggle
///   in Settings. Until then, `AnalyticsPolicy` reports `isEnabled == false`
///   and `eventCount == 0` on every path.
///
/// This policy is deliberately tiny and `Equatable` so tests can assert it
/// without reaching into `UserDefaults` or `Info.plist`.
enum AnalyticsPolicy {
    /// Whether analytics is enabled. Always `false` in 0.1.0-dev → 0.2.0 Horizon.
    static let isEnabled = false

    /// Number of events collected. Always `0` when disabled.
    static let eventCount = 0

    /// Whether any outbound endpoint is configured. Always `nil` when disabled.
    static let endpoint: URL? = nil

    /// One presentation-safe sentence for Settings.
    static let summary = "Analytics is not enabled. No events are collected or sent."

    /// Typed guarantees for Settings and `WHAT_DOES_NOT_EXIST.md`.
    enum Guarantee: String, CaseIterable, Hashable {
        case noAnalyticsKit
        case noTelemetry
        case noCrashReporterSDK
        case noOutboundEndpoint
        case noIdentifierCollection

        var message: String {
            switch self {
            case .noAnalyticsKit: return "No AnalyticsKit is linked into the app binary."
            case .noTelemetry: return "No telemetry events are recorded."
            case .noCrashReporterSDK: return "No crash-reporter SDK is integrated."
            case .noOutboundEndpoint: return "No measurement endpoint is configured."
            case .noIdentifierCollection: return "No identifier is collected for measurement."
            }
        }
    }

    static var guarantees: [Guarantee] { Guarantee.allCases }

    struct Assessment: Equatable {
        let isEnabled: Bool
        let eventCount: Int
        let guarantees: [Guarantee]
        let summary: String
    }

    static func assess() -> Assessment {
        Assessment(isEnabled: isEnabled, eventCount: eventCount, guarantees: guarantees, summary: summary)
    }
}
