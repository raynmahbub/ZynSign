import XCTest
@testable import ZynSign

/// Tests for the entitlement merge policy.
final class EntitlementMergePolicyTests: XCTestCase {

    private func claims(_ pairs: [String: Bool]) -> ProvisioningProfileEntitlements {
        ProvisioningProfileEntitlements(values: pairs.mapValues { .boolean($0) })
    }

    func testProfileOnlyDropsAppClaims() {
        let app = claims(["app-claim": true])
        let profile = claims(["profile-claim": true])
        let result = EntitlementMergePolicy.merge(appClaims: app, profileClaims: profile, mode: .profileOnly)
        XCTAssertEqual(result.merged.values.count, 1)
        XCTAssertNotNil(result.merged["profile-claim"])
        XCTAssertNil(result.merged["app-claim"])
        XCTAssertEqual(result.appOnlyKeys, ["app-claim"])
        XCTAssertTrue(result.conflictKeys.isEmpty)
    }

    func testAppFirstLetsProfileWinConflicts() {
        let app = claims(["shared": true, "app-only": true])
        let profile = claims(["shared": false, "profile-only": true])
        let result = EntitlementMergePolicy.merge(appClaims: app, profileClaims: profile, mode: .appFirstProfileWins)
        XCTAssertEqual(result.merged["shared"], .boolean(false))
        XCTAssertEqual(result.merged["app-only"], .boolean(true))
        XCTAssertEqual(result.merged["profile-only"], .boolean(true))
        XCTAssertEqual(result.conflictKeys, ["shared"])
        XCTAssertEqual(result.appOnlyKeys, ["app-only"])
        XCTAssertEqual(result.profileOnlyKeys, ["profile-only"])
    }

    func testProfileFirstLetsAppWinConflicts() {
        let app = claims(["shared": true])
        let profile = claims(["shared": false, "profile-only": true])
        let result = EntitlementMergePolicy.merge(appClaims: app, profileClaims: profile, mode: .profileFirstAppWins)
        XCTAssertEqual(result.merged["shared"], .boolean(true))
        XCTAssertEqual(result.merged["profile-only"], .boolean(true))
        XCTAssertEqual(result.conflictKeys, ["shared"])
    }

    func testAbsentAppClaimsBehavesLikeProfileOnlyInEveryMode() {
        let profile = claims(["profile-claim": true])
        for mode in EntitlementMergeMode.allCases {
            let result = EntitlementMergePolicy.merge(appClaims: nil, profileClaims: profile, mode: mode)
            XCTAssertEqual(result.merged.values.count, 1, "mode \(mode)")
            XCTAssertTrue(result.appOnlyKeys.isEmpty, "mode \(mode)")
            XCTAssertTrue(result.conflictKeys.isEmpty, "mode \(mode)")
        }
    }

    func testAgreedValuesAreNotConflicts() {
        let app = claims(["shared": true])
        let profile = claims(["shared": true])
        let result = EntitlementMergePolicy.merge(appClaims: app, profileClaims: profile, mode: .appFirstProfileWins)
        XCTAssertTrue(result.conflictKeys.isEmpty)
        XCTAssertTrue(result.appOnlyKeys.isEmpty)
        XCTAssertTrue(result.profileOnlyKeys.isEmpty)
    }

    func testReviewNeededListsOnlySurvivingAppKeys() {
        let app = claims(["app-claim": true, "shared": true])
        let profile = claims(["shared": true])
        let result = EntitlementMergePolicy.merge(appClaims: app, profileClaims: profile, mode: .appFirstProfileWins)
        XCTAssertEqual(EntitlementMergePolicy.reviewNeeded(for: result, mode: .appFirstProfileWins), ["app-claim"])
        XCTAssertEqual(EntitlementMergePolicy.reviewNeeded(for: result, mode: .profileOnly), [])
    }
}
