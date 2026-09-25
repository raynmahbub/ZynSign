import SwiftUI

/// How any screen asks the shell to open the import area.
///
/// Importing is one experience with one owner: the shell presents the import
/// queue, and every screen that offers an import action — Home's quick
/// action, the Library's toolbar, a Files selection that turns out to be a
/// package — asks for it through this value rather than presenting a picker
/// of its own. That is what keeps a share-sheet hand-off, a drag, and a
/// deliberate choice from the Files app from being three subtly different
/// import flows.
///
/// The default implementation does nothing, so a screen shown outside the
/// shell (a preview, a test) never crashes on a missing presentation; it
/// simply has no import area to open. `isAvailable` lets a screen hide or
/// disable its import control where no import area exists at all.
struct ImportPresentation {

    /// Opens the import area.
    var present: () -> Void = {}

    /// Whether an import area is available to open.
    var isAvailable: Bool = false
}

private struct ImportPresentationKey: EnvironmentKey {
    static let defaultValue = ImportPresentation()
}

extension EnvironmentValues {

    /// The import presentation the shell installed.
    var importPresentation: ImportPresentation {
        get { self[ImportPresentationKey.self] }
        set { self[ImportPresentationKey.self] = newValue }
    }
}
