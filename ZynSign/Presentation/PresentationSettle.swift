import Foundation

/// One settle beat for a presentation that follows a dismissing controller.
///
/// UIKit drops a presentation requested in the frame another controller is
/// still dismissing — no error, no presentation, and the state that asked for
/// it stays set, so the screen looks like it ignored the tap. Every ZynSign
/// surface that raises a sheet, or the system document picker, immediately
/// after one of its own has closed waits out this beat first:
///
/// - the certificate import's password sheet, raised from the `.fileImporter`
///   completion that vended the chosen `.p12`;
/// - the Import Hub's own picker, raised as its sheet finishes presenting (or
///   later, from a `chooseFiles` request);
/// - the Import Hub itself, when Files hands it a picked package instead of
///   copying it into the folder being browsed.
///
/// One constant, in one place, so the app settles its presentations in the
/// same measured beat rather than in several invented ones — and so a device
/// that needs longer is adjusted here rather than in four screens.
enum PresentationSettle {

    /// How long a dismissing controller is given before the next
    /// presentation. A sheet's dismissal runs on its own animation clock; this
    /// is comfortably past it without being perceptible as a wait.
    static let beat: Duration = .milliseconds(400)

    /// Runs `body` on the main actor once the beat has elapsed.
    ///
    /// The wait is deliberately unconditional: the caller's own guard inside
    /// `body` — pending bytes present, the request still unfulfilled, the sheet
    /// still up — is what keeps a stale request from presenting over a screen
    /// the user has already left.
    static func afterDismissal(_ body: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: beat)
            body()
        }
    }
}
