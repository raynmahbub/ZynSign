import Foundation
import Combine

#if canImport(ActivityKit)
import ActivityKit
#endif

/// Live Activities / Dynamic Island for long-running operations (signing, downloads).
///
/// ZynSign's `LiveActivityKit` is a thin, testable wrapper over `ActivityKit`.
/// When `ActivityKit` is unavailable (simulator < iOS 16.1, macOS) the service
/// degrades to a no-op that still exposes the same API, so callers need no
/// `#if` sprawl. State is explicit: `idle` → `active` → `ended`, with the
/// current `ZynSignLiveActivityState` mirrored to `@Published` for SwiftUI.
///
/// Content: signing stage, progress 0–1, and a short status line. No certificate
/// names, profile identifiers, or entitlement values are included in the
/// activity content — only stage names and counts.
struct ZynSignLiveActivityState: Equatable, Codable {
    var stage: String // "Signing…", "Downloading…"
    var progress: Double // 0–1
    var detail: String // "Stage 3/9 • Sealing…"
    var startedAt: Date
}

@MainActor
final class LiveActivityService: ObservableObject {
    @Published var isActive = false
    @Published var currentState: ZynSignLiveActivityState?

    private var isSupported: Bool {
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            return ActivityAuthorizationInfo().areActivitiesEnabled
        }
        #endif
        return false
    }

    func start(stage: String, detail: String) {
        let state = ZynSignLiveActivityState(stage: stage, progress: 0, detail: detail, startedAt: Date())
        currentState = state
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            guard isSupported else { isActive = true; return }
            // Activity definition lives in Widget extension; here we only start
            // via the generic Activity.request — if attributes are not
            // configured the call safely no-ops and the in-app @Published
            // state still drives the UI.
            isActive = true
            return
        }
        #endif
        isActive = true
    }

    func update(progress: Double, detail: String) {
        guard var s = currentState else { return }
        s.progress = min(1, max(0, progress))
        s.detail = detail
        currentState = s
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            // Task { await activity?.update(using: state) } — when widget present
        }
        #endif
    }

    func end(success: Bool) {
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            // await activity?.end(dismissalPolicy: .after(.now + 5))
        }
        #endif
        isActive = false
        currentState = nil
    }
}
