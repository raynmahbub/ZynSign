import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Waiting out a presentation, by asking the platform rather than by guessing.
///
/// UIKit drops a presentation requested while another controller is still
/// transitioning — no error, no presentation, and the state that asked for it
/// stays set, so the screen looks like it ignored the tap. This is especially
/// easy to hit when a document picker calls back while its own dismissal is
/// still in flight.
///
/// Every wait checks the complete presented-controller chain, including a
/// child that is *being dismissed*. Checking only the controller that remains
/// visible after skipping a dismissing child reports the hierarchy idle too
/// early — the exact frame in which the next sheet or picker is dropped.
///
/// - `waitForIdle()` waits for the platform to report that the presented
///   hierarchy has stopped transitioning;
/// - `waitUntil(_:)` waits for a signal the app receives, such as a sheet's own
///   appearance (`SheetPresentationReporter`);
/// - `presentAndConfirm(_:)` presents, checks that the hierarchy changed, and
///   reports failure so the caller can reset its binding and retry.
///
/// The cap bounds waits whose platform report never arrives. It is a failure
/// result, never permission to present into a hierarchy still in transition.
enum PresentationSettle {

    /// How often a wait re-checks whatever it is waiting for.
    static let pollInterval: Duration = .milliseconds(25)

    /// The longest any wait will keep checking before giving up.
    static let cap: Duration = .seconds(3)

    /// A snapshot of one controller's transition state, separated from UIKit
    /// so the hierarchy rule can be regression-tested without a live window.
    struct TransitionStatus: Equatable {
        let hasTransitionCoordinator: Bool
        let isBeingPresented: Bool
        let isBeingDismissed: Bool

        var isIdle: Bool {
            !hasTransitionCoordinator && !isBeingPresented && !isBeingDismissed
        }
    }

    /// Every controller in the presented chain must be idle. In particular,
    /// a dismissing child keeps the chain busy even when its presenter is not
    /// itself transitioning.
    static func hierarchyIsIdle(_ statuses: [TransitionStatus]) -> Bool {
        statuses.allSatisfy(\.isIdle)
    }

    /// Waits until nothing in ZynSign's presented hierarchy is transitioning.
    ///
    /// - Returns: `true` when the hierarchy is idle (or no UIKit window is
    ///   available to inspect), `false` on cancellation or timeout.
    @MainActor
    @discardableResult
    static func waitForIdle(cap: Duration = PresentationSettle.cap) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds(from: cap))
        while Date() < deadline {
            if Task.isCancelled { return false }
            #if canImport(UIKit)
            guard let controllers = presentedControllers() else { return true }
            let statuses = controllers.map { transitionStatus(of: $0) }
            if hierarchyIsIdle(statuses) { return true }
            #else
            return true
            #endif
            try? await Task.sleep(for: pollInterval)
        }
        #if canImport(UIKit)
        guard let controllers = presentedControllers() else { return true }
        return hierarchyIsIdle(controllers.map { transitionStatus(of: $0) })
        #else
        return true
        #endif
    }

    /// Waits until `condition` is true, checking every poll interval.
    ///
    /// Use this for a signal the app receives rather than a duration: the
    /// Import Hub waits for its sheet to report that it has appeared, not for
    /// a number of milliseconds that is usually long enough.
    @MainActor
    @discardableResult
    static func waitUntil(
        _ condition: @MainActor () -> Bool,
        cap: Duration = PresentationSettle.cap
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds(from: cap))
        while Date() < deadline {
            if Task.isCancelled { return false }
            if condition() { return true }
            try? await Task.sleep(for: pollInterval)
        }
        return condition()
    }

    /// Presents, and reports whether the presented hierarchy changed.
    ///
    /// The wait for idle comes first, so the request is not made inside
    /// another controller's transition. `present` is then called once, and the
    /// hierarchy is polled: a presentation the platform accepted puts a new
    /// controller at the top of the chain, and one it dropped leaves the chain
    /// exactly as it was. The result lets the caller re-arm and ask again
    /// instead of leaving the user with a tap that did nothing.
    ///
    /// - Returns: `true` when something appeared, `false` when nothing did.
    @MainActor
    @discardableResult
    static func presentAndConfirm(
        cap: Duration = .milliseconds(1500),
        _ present: @MainActor () -> Void
    ) async -> Bool {
        guard await waitForIdle() else { return false }
        #if canImport(UIKit)
        let before = topMostViewController()
        guard before != nil else { return false }
        present()
        let deadline = Date().addingTimeInterval(seconds(from: cap))
        while Date() < deadline {
            if Task.isCancelled { return false }
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
    /// Every presented controller from the key window's root through its
    /// presented chain. Dismissing controllers are intentionally retained in
    /// the result until UIKit removes them after the transition.
    @MainActor
    private static func presentedControllers() -> [UIViewController]? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeScene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = activeScene?.windows.first { $0.isKeyWindow } ?? activeScene?.windows.first
        guard var controller = window?.rootViewController else { return nil }
        var controllers = [controller]
        while let presented = controller.presentedViewController {
            controllers.append(presented)
            controller = presented
        }
        return controllers
    }

    /// The controller at the end of the active presented chain.
    @MainActor
    private static func topMostViewController() -> UIViewController? {
        presentedControllers()?.last
    }

    @MainActor
    private static func transitionStatus(of controller: UIViewController) -> TransitionStatus {
        TransitionStatus(
            hasTransitionCoordinator: controller.transitionCoordinator != nil,
            isBeingPresented: controller.isBeingPresented,
            isBeingDismissed: controller.isBeingDismissed
        )
    }
    #endif
}

#if canImport(UIKit)
/// Reports when the controller hosting it has finished appearing.
///
/// A sheet's `.task` starts while the sheet is still animating in, and a
/// presentation requested inside that window is dropped without an error. The
/// Import Hub therefore waits for UIKit's own appearance callback instead of
/// guessing how long its sheet takes to come up.
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
