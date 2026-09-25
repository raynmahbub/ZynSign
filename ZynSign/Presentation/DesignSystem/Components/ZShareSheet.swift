import SwiftUI
import UIKit

/// The system share sheet, for handing one signed artifact to iOS.
///
/// Sharing is the only delivery ZynSign offers, and it is deliberately the
/// system's: the sheet provides Share, Save to Files, and "open in" for every
/// application that accepts the package, so ZynSign never invents an
/// installation or delivery option that does not exist. What the sheet does
/// with the file is the system's business; ZynSign hands it the artifact's
/// location and learns only whether the sheet completed.
///
/// The sheet is presented on the key window's root view controller, which is
/// what makes it work from a `List` row, a detail screen, or a sheet of its
/// own without each caller arranging a presenter.
struct ZShareSheet: UIViewControllerRepresentable {

    /// The artifacts to hand to the system.
    let items: [Any]

    /// Called when the sheet finishes. `completed` is true only when the
    /// user actually completed an activity — dismissing the sheet is not a
    /// delivery, and ZynSign does not record one.
    var onFinish: ((_ completed: Bool) -> Void)?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            onFinish?(completed)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}

    /// Presents the sheet over the key window's root view controller.
    @MainActor
    static func present(items: [Any], onFinish: ((Bool) -> Void)? = nil) {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in onFinish?(completed) }
        guard let root = keyWindow?.rootViewController else { return }
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        controller.popoverPresentationController?.sourceView = presenter.view
        controller.popoverPresentationController?.sourceRect = CGRect(
            x: presenter.view.bounds.midX,
            y: presenter.view.bounds.midY,
            width: 0,
            height: 0
        )
        controller.popoverPresentationController?.permittedArrowDirections = []
        presenter.present(controller, animated: true)
    }

    @MainActor
    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}
