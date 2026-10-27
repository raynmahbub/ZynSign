import XCTest
@testable import ZynSign

/// Tests for the shell's presentation rule: which surface is raised now, which
/// one waits, and in what order the waiting ones are honoured.
///
/// A hand-off that opens nothing is what this rule exists to prevent, so the
/// tests freeze both halves of it — that a busy screen *holds* a request
/// instead of dropping it, and that the queue gives every held request its turn
/// in arrival order.
final class ShellPresentationQueueTests: XCTestCase {

    private let certificate = URL(fileURLWithPath: "/inbox/Identity.p12")
    private let otherCertificate = URL(fileURLWithPath: "/inbox/Identity2.p12")

    // MARK: - The decision

    func testAFreeActiveShellPresentsImmediately() {
        let decision = ShellPresentationRouting.decide(
            sceneIsActive: true,
            surfaceIsAlreadyShowing: false,
            shellIsOccupied: false
        )

        XCTAssertEqual(decision, .present)
    }

    func testAnInactiveSceneHoldsTheRequest() {
        let decision = ShellPresentationRouting.decide(
            sceneIsActive: false,
            surfaceIsAlreadyShowing: false,
            shellIsOccupied: false
        )

        XCTAssertEqual(decision, .hold, "A request made while another app is on screen waits rather than being dropped.")
    }

    func testAnotherShellSurfaceHoldsTheRequest() {
        let decision = ShellPresentationRouting.decide(
            sceneIsActive: true,
            surfaceIsAlreadyShowing: false,
            shellIsOccupied: true
        )

        XCTAssertEqual(decision, .hold)
    }

    func testTheSurfaceAlreadyShowingIsPresentedAgainInPlace() {
        let decision = ShellPresentationRouting.decide(
            sceneIsActive: true,
            surfaceIsAlreadyShowing: true,
            shellIsOccupied: true
        )

        XCTAssertEqual(decision, .present, "A second hand-off updates the screen that is up; it does not stack a sheet.")
    }

    // MARK: - Same surface

    func testSurfacesOfTheSameKindAreRecognisedWhateverDocumentTheyCarry() {
        XCTAssertTrue(ShellPresentation.certificates(certificate).isSameSurface(as: .certificates(otherCertificate)))
        XCTAssertTrue(ShellPresentation.importHub.isSameSurface(as: .importHub))
        XCTAssertFalse(ShellPresentation.certificates(certificate).isSameSurface(as: .profiles(certificate)))
        XCTAssertFalse(ShellPresentation.importHub.isSameSurface(as: .certificates(certificate)))
    }

    // MARK: - The queue

    func testHeldRequestsKeepTheirArrivalOrder() {
        var queue = ShellPresentationQueue()
        queue.enqueue(.importHub)
        queue.enqueue(.certificates(certificate))

        XCTAssertEqual(queue.count, 2)
        XCTAssertEqual(queue.removeFirst(), ShellPresentation.importHub)
        XCTAssertEqual(queue.removeFirst(), ShellPresentation.certificates(certificate))
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.removeFirst(), "An empty queue has nothing to present.")
    }

    func testARetryKeepsItsPlaceAheadOfRequestsThatArrivedWhileItWaited() {
        var queue = ShellPresentationQueue()
        queue.enqueue(.importHub)
        queue.enqueue(.profiles(certificate))

        // The hub's presentation was retried while it waited: it must be
        // offered before the request that arrived after it.
        queue.enqueue(.importHub, atFront: true)

        XCTAssertEqual(queue.count, 3)
        XCTAssertEqual(queue.removeFirst(), ShellPresentation.importHub)
        XCTAssertEqual(queue.removeFirst(), ShellPresentation.importHub)
        XCTAssertEqual(queue.removeFirst(), ShellPresentation.profiles(certificate))
    }

    func testBothFilesOfOneHandOffAreKept() {
        // One drag can carry a certificate and a profile; a single slot used
        // to discard whichever arrived second.
        var queue = ShellPresentationQueue()
        queue.enqueue(.certificates(certificate))
        queue.enqueue(.profiles(otherCertificate))

        XCTAssertEqual(queue.count, 2)
    }
}
