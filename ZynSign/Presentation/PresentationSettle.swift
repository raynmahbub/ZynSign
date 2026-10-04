import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Waiting out a presentation, by asking the platform rather than by guessing.
///
/// UIKit drops a presentation requested while another controller is still
/// transitioning — no error, no presentation, and the state that asked for it
/// stays set, so the screen looks like it ignored the tap. That is what a
/// chosen package and a chosen `.p12` both ran into: the Import Hub's picker
/// was requested while the hub's own sheet was still animating in, and the
/// certificate import's password sheet was requested in the frame the document
/// picker was dismissing.
///
/// The earlier answer was a fixed settle beat: sleep 400 ms, then present, and
/// hope the animation was shorter. On a device that is slower than the guess —
/// a Release build, a cold first render, a long list on screen — the beat
/// elapses first and the request is dropped again. Guessing is the bug, so
/// nothing here measures time any more:
///
/// - `waitForIdle()` waits until the platform reports no in-flight transition
///   (`transitionCoordinator`, `isBeingPresented`, `isBeingDismissed`);
/// - `waitUntil(_:)` waits for a report the app itself receives, such as a
///   sheet's own appearance (`SheetPresentationReporter`);
/// - `presentAndConfirm(_:)` presents and then *checks* that something
///   appeared, so the caller can ask once more instead of leaving the user
///   with a tap that did nothing.
///
/// Every wait has a cap only so that a report that never arrives cannot hang a
/// screen; the cap is never the thing being waited for.
enum PresentationSettle {

    /// How often a wait re-checks whatever it is waiting for.
    static let pollInterval: Duration = .milliseconds(25)

    /// The longest any wait will keep checking before giving up.
    static let cap: Duration = .seconds(3)

    /// Waits until nothing in ZynSign's presented hierarchy is transitioning.
    ///
    /// Called before a presentation that follows a dismissal — the picker
    /// closing, a sheet going away — so the request lands on a settled
    /// hierarchy instead of inside the animation.
    @MainActor
    static func waitForIdle() async {
        let deadline = Date().addingTimeInterval(seconds(from: cap))
        while Date() < deadline {
            #if canImport(UIKit)
            guard let top = topMostViewController() else { return }
            if top.transitionCoordinator == nil, !top.isBeingPresented, !top.isBeingDismissed {
                return
            }
            #else
            return
            #endif
            try? await Task.sleep(for: pollInterval)
        }
    }

    /// Waits until `condition` is true, checking every poll interval.
    ///
    /// Use this for a signal the app receives rather than a duration: the
    /// Import Hub waits for its sheet to report that it has appeared, not for
    /// a number of milliseconds that is usually long enough.
    @MainActor
    static func waitUntil(
        _ condition: @MainActor () -> Bool,
        cap: Duration = PresentationSettle.cap
    ) async {
        let deadline = Date().addingTimeInterval(seconds(from: cap))
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: pollInterval)
        }
    }

    /// Presents, and reports whether the presented hierarchy changed.
    ///
    /// The wait for idle comes first, so the request is not made inside
    /// another controller's transition. `present` is then called once, and the
    /// hierarchy is polled: a presentation the platform accepted puts a new
    /// controller at the top of the chain, and one it dropped leaves the chain
    /// exactly as it was. The result is what lets a caller re-arm and ask
    /// again instead of the user being left with a tap that did nothing.
    ///
    /// - Returns: `true` when something appeared, `false` when nothing did.
    @MainActor
    @discardableResult
    static func presentAndConfirm(
        cap: Duration = .milliseconds(1500),
        _ present: @MainActor () -> Void
    ) async -> Bool {
        await waitForIdle()
        #if canImport(UIKit)
        let before = topMostViewController()
        present()
        let deadline = Date().addingTimeInterval(seconds(from: cap))
        while Date() < deadline {
            try? await Task.sleep(for: pollInterval)
            if topMostViewController() !== before { return true }
        }
        return false
        #else
        present()
        return true
        #endif
    }

    private static func seconds(from duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }

    #if canImport(UIKit)
    /// The controller at the top of the active window's presented chain — the
    /// one the next presentation would come from.
    ///
    /// Only presentation is asked about, never a screen's contents: the
    /// returned controller is compared by identity before and after a
    /// presentation, and never retained by the caller.
    @MainActor
    private static func topMostViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        guard var controller = window?.rootViewController else { return nil }
        while let presented = controller.presentedViewController {
            controller = presented
        }
        return controller
    }
    #endif
}

#if canImport(UIKit)
/// Reports when the controller hosting it has finished appearing.
///
/// A sheet's `.task` starts while the sheet is still animating in, and a
/// presentation requested inside that window is dropped with no error, so the
/// Import Hub needs the platform's own answer to "the sheet is up". UIKit
/// forwards appearance transitions to child controllers, so this controller's
/// `viewDidAppear` is that answer: it fires when the presentation transition
/// ends, or immediately when it is added to a controller already on screen.
///
/// It draws nothing and takes no touches. It exists only to produce the
/// callback, which replaces the settle beat the hub used to sleep through.
struct SheetPresentationReporter: UIViewControllerRepresentable {

    /// Called once, on the main actor, when the hosting controller appeared.
    let onAppear: @MainActor () -> Void

    func makeUIViewController(context: Context) -> ReporterViewController {
        ReporterViewController(onAppear: onAppear)
    }

    func updateUIViewController(_ controller: ReporterViewController, context: Context) {
        controller.onAppear = onAppear
    }

    final class ReporterViewController: UIViewController {

        /// Replaced on every update; called at most once.
        var onAppear: @MainActor () -> Void = {}

        private var hasReported = false

        init(onAppear: @escaping @MainActor () -> Void) {
            self.onAppear = onAppear
            super.init(nibName: nil, bundle: nil)
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            // The reporter is invisible and inert; only its appearance
            // callback is used.
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }

        /// Nothing in ZynSign unarchives a view controller; this exists
        /// because `UIViewController` requires it.
        required init?(coder: NSCoder) {
            return nil
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !hasReported else { return }
            hasReported = true
            onAppear()
        }
    }
}
#endif
