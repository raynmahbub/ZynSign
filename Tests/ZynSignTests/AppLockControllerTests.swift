import XCTest
@testable import ZynSign

/// ZynSign's lock: when it asks, when it does not, and what it shows while
/// it holds.
@MainActor
final class AppLockControllerTests: XCTestCase {

    private var preferences = ZynSignPreferences.shippedDefault
    private var authenticator: FakeBiometricAuthenticator!
    private var controller: AppLockController!

    override func setUp() async throws {
        try await super.setUp()
        authenticator = FakeBiometricAuthenticator()
        controller = AppLockController(
            authenticator: authenticator,
            preferences: { self.preferences }
        )
    }

    override func tearDown() async throws {
        controller = nil
        authenticator = nil
        preferences = ZynSignPreferences.shippedDefault
        try await super.tearDown()
    }

    // MARK: - Gating

    func testAnUnprotectedApplicationNeverAsks() async {
        preferences.security.biometricLockEnabled = false
        preferences.security.requireAuthenticationForSensitiveActions = true

        let outcome = await controller.authorize(.sign)

        XCTAssertEqual(outcome, .authenticated)
        XCTAssertEqual(authenticator.attemptCount, 0)
    }

    func testASensitiveActionAsksWhenTheUserAskedItTo() async {
        enableProtection()

        let outcome = await controller.authorize(.sign)

        XCTAssertEqual(outcome, .authenticated)
        XCTAssertEqual(authenticator.attemptCount, 1)
        XCTAssertEqual(authenticator.recordedReasons.last, SensitiveAction.sign.authenticationReason)
    }

    func testASensitiveActionDoesNotAskWhenThePreferenceIsOff() async {
        enableProtection()
        preferences.security.requireAuthenticationForSensitiveActions = false

        let outcome = await controller.authorize(.clearStorage)

        XCTAssertEqual(outcome, .authenticated)
        XCTAssertEqual(authenticator.attemptCount, 0)
    }

    func testAFailedAttemptStopsTheAction() async {
        enableProtection()
        authenticator.outcome = .failed

        let outcome = await controller.authorize(.resetLibrary)

        XCTAssertEqual(outcome, .failed)
        XCTAssertFalse(outcome.isAuthenticated)
        XCTAssertFalse(controller.isLocked, "A failed sensitive action does not lock the application.")
    }

    func testEachActionCarriesItsOwnReason() {
        let reasons = Set(SensitiveAction.allCases.map(\.authenticationReason))

        XCTAssertEqual(reasons.count, SensitiveAction.allCases.count)
        for action in SensitiveAction.allCases {
            XCTAssertFalse(action.authenticationReason.isEmpty, action.title)
            XCTAssertFalse(action.title.isEmpty)
        }
    }

    func testRecoveryActionsNameTheActionTheyAreGuarding() {
        XCTAssertEqual(SensitiveAction.forRecovery(.workspace), .clearStorage)
        XCTAssertEqual(SensitiveAction.forRecovery(.cache), .clearStorage)
        XCTAssertEqual(SensitiveAction.forRecovery(.libraryIndex), .clearStorage)
        XCTAssertEqual(SensitiveAction.forRecovery(.library), .resetLibrary)
    }

    func testResettingPreferencesIsNotASensitiveAction() {
        // Preferences are configuration, and resetting them is reversible in
        // the only way that matters: nothing the user built is lost. Asking
        // for a fingerprint to restore defaults would be theatre.
        XCTAssertNil(SensitiveAction.forRecovery(.preferences))
    }

    func testExactlyOneRecoveryActionIsDestructive() {
        let destructive = RecoveryActionKind.allCases.filter(\.isDestructive)

        XCTAssertEqual(destructive, [.library])
    }

    func testEveryRecoveryActionExplainsItselfBeforeItAsks() {
        for kind in RecoveryActionKind.allCases {
            XCTAssertFalse(kind.confirmationMessage.isEmpty, kind.rawValue)
        }

        XCTAssertTrue(RecoveryActionKind.library.confirmationMessage.contains("cannot be undone"))
        XCTAssertTrue(RecoveryActionKind.libraryIndex.confirmationMessage.contains("No imported application is removed"))
    }

    // MARK: - Locking

    func testALockedApplicationIsUnlockedByTheAttemptThatNeedsIt() async {
        enableProtection()
        controller.lock()

        let outcome = await controller.authorize(.sign)

        XCTAssertEqual(outcome, .authenticated)
        XCTAssertEqual(authenticator.recordedReasons.last, "Unlock ZynSign.")
        XCTAssertFalse(controller.isLocked)
        XCTAssertNotNil(controller.lastAuthentication)
    }

    func testUnlockingDirectlyUsesItsOwnReason() async {
        enableProtection()
        controller.lock()

        let outcome = await controller.unlock()

        XCTAssertEqual(outcome, .authenticated)
        XCTAssertEqual(authenticator.recordedReasons, ["Unlock ZynSign."])
        XCTAssertFalse(controller.isLocked)
    }

    func testAFailedUnlockLeavesTheApplicationLocked() async {
        enableProtection()
        controller.lock()
        authenticator.outcome = .cancelled

        let outcome = await controller.unlock()

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(controller.isLocked)
        XCTAssertNil(controller.lastAuthentication)
    }

    func testLockingHappensOnlyWhenProtectionIsOn() {
        controller.lockIfProtectionEnabled()
        XCTAssertFalse(controller.isLocked)

        enableProtection()
        controller.lockIfProtectionEnabled()
        XCTAssertTrue(controller.isLocked)
    }

    func testProtectionTheDeviceCannotOfferIsNotEnforced() {
        authenticator.availability = BiometricAvailability(
            kind: .faceID,
            isAvailable: false,
            unavailableReason: "Face ID is not set up."
        )
        preferences.security.biometricLockEnabled = true

        controller.refreshAvailability()

        XCTAssertFalse(controller.isProtectionEnabled)
        controller.lockIfProtectionEnabled()
        XCTAssertFalse(controller.isLocked)
    }

    // MARK: - Session

    func testASessionThatHasNeverAuthenticatedHasLapsed() {
        XCTAssertTrue(controller.hasSessionLapsed())
    }

    func testASessionInsideItsTimeoutHasNotLapsed() async {
        enableProtection()
        _ = await controller.authorize(.sign)

        XCTAssertFalse(controller.hasSessionLapsed())
    }

    func testTheSessionLapsesAtTheTimeout() async {
        enableProtection()
        preferences.security.sessionTimeout = .immediately
        _ = await controller.authorize(.sign)

        XCTAssertTrue(controller.hasSessionLapsed())
    }

    func testASessionThatNeverLapsesIsNeverLapsed() async {
        enableProtection()
        _ = await controller.authorize(.sign)
        let longAfter = Date().addingTimeInterval(86_400)

        XCTAssertFalse(controller.hasSessionLapsed(now: longAfter))
    }

    func testInactivityLocksOnlyOnceTheSessionHasLapsed() async {
        enableProtection()
        preferences.security.sessionTimeout = .immediately
        _ = await controller.authorize(.sign)

        controller.evaluateInactivity()

        XCTAssertTrue(controller.isLocked)
    }

    func testInactivityNeverLocksAnApplicationThatIsAlreadyLocked() {
        enableProtection()
        controller.lock()

        controller.evaluateInactivity()

        XCTAssertTrue(controller.isLocked)
    }

    func testInactivityNeverLocksWhenProtectionIsOff() async {
        preferences.security.biometricLockEnabled = false
        preferences.security.sessionTimeout = .immediately
        _ = await controller.authorize(.sign)

        controller.evaluateInactivity()

        XCTAssertFalse(controller.isLocked)
    }

    // MARK: - Visibility

    func testHiddenValuesAreAlwaysHidden() {
        preferences.security.sensitiveDataVisibility = .hidden
        XCTAssertTrue(controller.shouldHideSensitiveValues())

        controller.lock()
        XCTAssertTrue(controller.shouldHideSensitiveValues())
    }

    func testVisibleValuesAreNeverHidden() {
        preferences.security.sensitiveDataVisibility = .visible
        XCTAssertFalse(controller.shouldHideSensitiveValues())

        controller.lock()
        XCTAssertFalse(controller.shouldHideSensitiveValues())
    }

    func testMaskedValuesAreHiddenOnlyWhileLocked() {
        preferences.security.sensitiveDataVisibility = .masked
        preferences.security.hideSensitiveInformationWhenLocked = true
        XCTAssertFalse(controller.shouldHideSensitiveValues())

        controller.lock()
        XCTAssertTrue(controller.shouldHideSensitiveValues())
    }

    func testMaskedValuesMayStayVisibleWhileLockedWhenTheUserAsked() {
        preferences.security.sensitiveDataVisibility = .masked
        preferences.security.hideSensitiveInformationWhenLocked = false
        controller.lock()

        XCTAssertFalse(controller.shouldHideSensitiveValues())
    }

    // MARK: - Helpers

    private func enableProtection() {
        preferences.security.biometricLockEnabled = true
        preferences.security.requireAuthenticationForSensitiveActions = true
    }
}
