import XCTest
@testable import ZynSign

final class PresentationSettleTests: XCTestCase {

    func testHierarchyIsIdleOnlyWhenEveryPresentedControllerIsIdle() {
        let idle = PresentationSettle.TransitionStatus(
            hasTransitionCoordinator: false,
            isBeingPresented: false,
            isBeingDismissed: false
        )

        XCTAssertTrue(PresentationSettle.hierarchyIsIdle([idle, idle]))
    }

    func testDismissingPresentedChildKeepsHierarchyBusyEvenWhenPresenterIsIdle() {
        let idlePresenter = PresentationSettle.TransitionStatus(
            hasTransitionCoordinator: false,
            isBeingPresented: false,
            isBeingDismissed: false
        )
        let dismissingPicker = PresentationSettle.TransitionStatus(
            hasTransitionCoordinator: false,
            isBeingPresented: false,
            isBeingDismissed: true
        )

        XCTAssertFalse(PresentationSettle.hierarchyIsIdle([idlePresenter, dismissingPicker]))
    }

    func testTransitionCoordinatorAndPresentationTransitionsKeepHierarchyBusy() {
        let presenting = PresentationSettle.TransitionStatus(
            hasTransitionCoordinator: false,
            isBeingPresented: true,
            isBeingDismissed: false
        )
        let coordinated = PresentationSettle.TransitionStatus(
            hasTransitionCoordinator: true,
            isBeingPresented: false,
            isBeingDismissed: false
        )

        XCTAssertFalse(PresentationSettle.hierarchyIsIdle([presenting]))
        XCTAssertFalse(PresentationSettle.hierarchyIsIdle([coordinated]))
    }
}
