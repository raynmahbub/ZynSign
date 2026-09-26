import Foundation
import Combine

#if canImport(UserNotifications)
import UserNotifications
#endif

/// Local notifications for settled signing jobs — where the platform
/// supports them, the user allowed them, and the user turned them on.
///
/// The notifier is deliberately the most refused component in the queue's
/// composition. A notice becomes a system notification only when every one
/// of these holds: the platform has a notification center, the user's
/// authorization status is granted or provisional, and the queue's own
/// notification preference is on. The preference is off by default; turning
/// it on is the only path that asks the system for authorization, so
/// ZynSign never surprises the user with a permission dialog. A refused
/// notification is not an error and is not retried: the in-app notice —
/// the shell's toast and VoiceOver announcement — stands on its own.
///
/// Content follows the notice's own discipline: the application's display
/// name and the outcome. Never identities, keys, profile content, or file
/// locations.
@MainActor
final class LocalSigningQueueNotifier: ObservableObject, SigningQueueNotifying {

    /// The `UserDefaults` key the queue-notification preference lives under.
    nonisolated static let enabledDefaultsKey = "zynsign.signingQueue.localNotifications"

    /// Whether the user turned queue notifications on. Off by default;
    /// turning it on requests authorization once, and turning it off stops
    /// every post immediately regardless of the system's answer.
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledDefaultsKey)
            if isEnabled {
                Task { await self.requestAuthorizationIfNeeded() }
            }
        }
    }

    /// Whether this platform offers a notification center at all.
    let isSupported: Bool

    /// `nonisolated` because the composition root builds the notifier
    /// while wiring the application environment, which is not a main-actor
    /// context. It only initializes storage; every later mutation happens
    /// on the main actor.
    nonisolated init() {
        self._isEnabled = Published(initialValue: UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey))
        #if canImport(UserNotifications) && os(iOS)
        self.isSupported = true
        #else
        self.isSupported = false
        #endif
    }

    /// Offers one notice to the platform. Posts only when supported,
    /// enabled, and authorized; otherwise returns silently.
    nonisolated func notify(_ notice: SigningQueueNotice) async {
        await notifyOnMain(notice)
    }

    private func notifyOnMain(_ notice: SigningQueueNotice) async {
        guard isEnabled, isSupported else { return }
        #if canImport(UserNotifications) && os(iOS)
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.message
        content.sound = .default
        content.categoryIdentifier = "ZYN_SIGN_QUEUE"
        let request = UNNotificationRequest(
            identifier: "zynsign.queue.\(notice.id.uuidString)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
        #endif
    }

    /// Asks the system for authorization — once, and only because the user
    /// just turned the preference on. A denial is accepted silently: the
    /// preference stays on, the system posts nothing, and the in-app
    /// notices continue.
    func requestAuthorizationIfNeeded() async {
        guard isSupported else { return }
        #if canImport(UserNotifications) && os(iOS)
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        #endif
    }
}
