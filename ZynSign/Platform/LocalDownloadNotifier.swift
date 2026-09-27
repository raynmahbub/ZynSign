import Foundation

#if canImport(UserNotifications)
import UserNotifications
#endif

/// Local notifications for download outcomes — where the platform supports
/// them, the user allowed them, and the user turned them on.
///
/// The preference is off by default. Turning it on is the only path that asks
/// for authorization. A refused notification is not an error: the in-app
/// notice stands on its own. Content is the notice's title and message, which
/// name an app and an outcome, never a file location or a credential.
@MainActor
final class LocalDownloadNotifier: ObservableObject, DownloadNotifying {

    nonisolated static let enabledDefaultsKey = "zynsign.downloadCenter.localNotifications"

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledDefaultsKey)
            if isEnabled {
                Task { await self.requestAuthorizationIfNeeded() }
            }
        }
    }

    let isSupported: Bool

    nonisolated init() {
        self._isEnabled = Published(initialValue: UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey))
        #if canImport(UserNotifications) && os(iOS)
        self.isSupported = true
        #else
        self.isSupported = false
        #endif
    }

    nonisolated func notify(_ notice: DownloadNotice) async {
        await notifyOnMain(notice)
    }

    private func notifyOnMain(_ notice: DownloadNotice) async {
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
        content.categoryIdentifier = "ZYN_SIGN_DOWNLOADS"
        let request = UNNotificationRequest(
            identifier: "zynsign.download.\(notice.id.uuidString)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
        #endif
    }

    private func requestAuthorizationIfNeeded() async {
        #if canImport(UserNotifications) && os(iOS)
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        #endif
    }
}
