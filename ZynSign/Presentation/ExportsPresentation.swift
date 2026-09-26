import SwiftUI

/// How any screen asks the shell to open the Export Center.
///
/// Exports are one experience with one owner, like the import area: the shell
/// presents the Export Center, and every screen that offers to open it — the
/// Library's toolbar, a signing result, the storage screen — asks for it
/// through this value rather than presenting an area of its own. That is what
/// keeps "where did my signed package go?" from having four different answers.
///
/// The default implementation does nothing, so a screen shown outside the
/// shell (a preview, a test) never crashes on a missing presentation; it
/// simply has no export area to open. `isAvailable` lets a screen hide or
/// disable its entry point where no export area exists at all.
struct ExportsPresentation {

    /// Opens the Export Center.
    var present: () -> Void = {}

    /// Opens the Export Center and asks it to reveal one export, when the
    /// caller already knows which one the user means.
    var presentExport: (ExportIdentifier) -> Void = { _ in }

    /// Asks the shell to show one library application, so "Reveal in
    /// Library" lands on the application a signed artifact came from. The
    /// shell closes the export area first.
    var revealInLibrary: (ApplicationRecordIdentifier) -> Void = { _ in }

    /// Whether an export area is available to open.
    var isAvailable: Bool = false
}

private struct ExportsPresentationKey: EnvironmentKey {
    static let defaultValue = ExportsPresentation()
}

extension EnvironmentValues {

    /// The export-area presentation the shell installed.
    var exportsPresentation: ExportsPresentation {
        get { self[ExportsPresentationKey.self] }
        set { self[ExportsPresentationKey.self] = newValue }
    }
}
