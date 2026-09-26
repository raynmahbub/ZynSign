import UIKit

/// The platform implementation of `ImportBackgroundExecution`, over
/// UIKit's background-task API.
///
/// `beginBackgroundTask` asks iOS for a short, finite extension of running
/// time after ZynSign leaves the foreground. iOS decides how long — it may
/// be a few seconds, or none — and calls the expiration handler before it
/// suspends ZynSign; the hub then pauses and ends the task immediately.
/// This is not background *processing*: nothing runs once ZynSign is
/// suspended, and the Import Hub resumes paused work only when ZynSign is
/// active again.
@MainActor
final class UIKitImportBackgroundExecution: ImportBackgroundExecution {

    nonisolated init() {}

    func beginBackgroundWork(expiration: @escaping @MainActor () -> Void) -> ImportBackgroundActivity? {
        let identifier = UIApplication.shared.beginBackgroundTask(withName: "ZynSign Import") {
            // UIKit calls the expiration handler on the main thread.
            MainActor.assumeIsolated {
                expiration()
            }
        }
        guard identifier != .invalid else { return nil }
        return ImportBackgroundActivity(rawValue: identifier.rawValue)
    }

    func endBackgroundWork(_ activity: ImportBackgroundActivity) {
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: activity.rawValue))
    }
}
