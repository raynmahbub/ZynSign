import SwiftUI

/// How any screen asks the shell to open the Import Hub.
///
/// Importing is one experience with one owner: the shell presents the
/// Import Hub, and every screen that offers an import action — Home's quick
/// action, the Library's toolbar, a Files selection that turns out to be a
/// package, a drop onto any import target — asks for it through this value
/// rather than presenting a picker of its own. That is what keeps a
/// share-sheet hand-off, an Open In request, a drag, and a deliberate choice
/// from the Files app from being subtly different import flows.
///
/// The default implementation does nothing, so a screen shown outside the
/// shell (a preview, a test) never crashes on a missing presentation; it
/// simply has no hub to open. `isAvailable` lets a screen hide or disable
/// its import control where no hub exists at all.
struct ImportPresentation {

    /// Opens the Import Hub.
    var present: () -> Void = {}

    /// Opens the Import Hub with the file picker already showing.
    var chooseFiles: () -> Void = {}

    /// Whether an Import Hub is available to open.
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
