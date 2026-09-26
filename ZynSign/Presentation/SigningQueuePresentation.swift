import SwiftUI

/// How any screen asks the shell to open the signing queue dashboard.
///
/// The queue is one experience with one owner, exactly like the import
/// area: the shell presents the dashboard, and every screen that offers a
/// queue action — the Library's toolbar, a row's context menu, a bulk
/// selection, the Smart Sign screen, a settled import — asks for it through
/// this value rather than presenting a competing sheet of its own. Adding
/// jobs happens through the configuration sheet, which any screen may
/// present locally because the *queue itself* is the single owner of the
/// work; the dashboard is only the window into it.
///
/// The default implementation does nothing, so a screen shown outside the
/// shell (a preview, a test) never crashes on a missing presentation; it
/// simply has no dashboard to open. `isAvailable` lets a screen hide or
/// disable its queue control where no dashboard exists at all.
struct SigningQueuePresentation {

    /// Opens the signing queue dashboard.
    var present: () -> Void = {}

    /// Whether a signing queue dashboard is available to open.
    var isAvailable: Bool = false
}

private struct SigningQueuePresentationKey: EnvironmentKey {
    static let defaultValue = SigningQueuePresentation()
}

extension EnvironmentValues {

    /// The signing queue presentation the shell installed.
    var signingQueuePresentation: SigningQueuePresentation {
        get { self[SigningQueuePresentationKey.self] }
        set { self[SigningQueuePresentationKey.self] = newValue }
    }
}

/// Whether the Professional Signing Queue is exposed in this build. The
/// single gate every queue entry point checks, so the release train stays
/// the only place the decision is made. The queue signs through the same
/// pipeline Smart Sign does, so it is available exactly where both
/// features are.
enum SigningQueueAvailability {

    static var isAvailable: Bool {
        ReleaseTrain.isAvailable(.signingQueue) && ReleaseTrain.isAvailable(.smartSign)
    }
}
