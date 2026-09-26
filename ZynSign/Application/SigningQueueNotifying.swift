import Foundation

/// The boundary through which the signing queue reaches the platform's
/// local notifications.
///
/// The port exists so the queue posts notices without knowing anything
/// about `UserNotifications`, permission states, or the user's preference:
/// the implementation decides whether a notice may become a system
/// notification, and the honest answer is often "no" — the platform does
/// not support it, the user never allowed it, or the user turned queue
/// notifications off. A refused notification is not an error; the in-app
/// notice stands on its own.
///
/// Notification content follows the notice's own discipline: an application
/// name and an outcome, never identities, keys, profile content, or file
/// locations.
protocol SigningQueueNotifying: Sendable {

    /// Offers one settled-job or queue-finished notice to the platform.
    /// Returns without posting when notifications are unsupported,
    /// unauthorized, or disabled.
    func notify(_ notice: SigningQueueNotice) async
}

/// A notifier that posts nothing, anywhere. The composition root's choice
/// for targets without `UserNotifications`; also the fallback a test uses
/// when it wants to observe the queue without a notification center.
struct UnavailableSigningQueueNotifier: SigningQueueNotifying {

    func notify(_ notice: SigningQueueNotice) async {
        // Nothing is posted, deliberately: this target or build has no
        // notification mechanism the queue may use.
    }
}
