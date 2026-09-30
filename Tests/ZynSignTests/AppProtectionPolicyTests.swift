import XCTest
@testable import ZynSign

/// Tests for the per-application protection policy and visibility rules.
final class AppProtectionPolicyTests: XCTestCase {

    func testConcealmentImpliesUnlock() {
        let policy = AppProtectionPolicy(requiresUnlock: false, concealed: true)
        XCTAssertTrue(policy.requiresUnlock)
        XCTAssertTrue(policy.concealed)
        XCTAssertTrue(policy.isActive)
    }

    func testNoneIsInactive() {
        XCTAssertFalse(AppProtectionPolicy.none.isActive)
    }

    func testUnguardedRecordsAlwaysShow() {
        for vault in [ProtectionVaultState.closed, .open, .unavailable] {
            let visibility = AppProtectionVisibility.visibility(for: nil, vault: vault)
            XCTAssertTrue(visibility.visible, "vault \(vault)")
            XCTAssertFalse(visibility.demandsUnlock, "vault \(vault)")
        }
    }

    func testLockedRecordsShowButDemandUnlockWhileClosed() {
        let policy = AppProtectionPolicy(requiresUnlock: true, concealed: false)
        let closed = AppProtectionVisibility.visibility(for: policy, vault: .closed)
        XCTAssertTrue(closed.visible)
        XCTAssertTrue(closed.demandsUnlock)
        let open = AppProtectionVisibility.visibility(for: policy, vault: .open)
        XCTAssertTrue(open.visible)
        XCTAssertFalse(open.demandsUnlock)
    }

    func testConcealedRecordsDisappearWhileClosed() {
        let policy = AppProtectionPolicy(requiresUnlock: true, concealed: true)
        let closed = AppProtectionVisibility.visibility(for: policy, vault: .closed)
        XCTAssertFalse(closed.visible)
        XCTAssertTrue(closed.demandsUnlock)
        let open = AppProtectionVisibility.visibility(for: policy, vault: .open)
        XCTAssertTrue(open.visible)
    }

    func testUnavailableVaultGuardsNothing() {
        let policy = AppProtectionPolicy(requiresUnlock: true, concealed: true)
        let visibility = AppProtectionVisibility.visibility(for: policy, vault: .unavailable)
        XCTAssertTrue(visibility.visible)
        XCTAssertFalse(visibility.demandsUnlock)
    }
}
