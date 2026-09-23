import Foundation
import XCTest
@testable import ZynSign

/// The one identifier rule: exact scope, wildcard scope, mismatch, and the
/// cases where nothing can be compared without inventing structure.
///
/// Every identifier here is a placeholder invented for the suite.
final class ProvisioningPolicyIdentifierCompatibilityTests: XCTestCase {

    private let team = ProvisioningPolicyFixtures.teamIdentifier
    private let bundle = ProvisioningPolicyFixtures.bundleIdentifier

    // MARK: - Exact scope

    func testExactIdentifierMatchesTheSameBundleIdentifier() {
        let rule = compatibility(component: bundle)

        XCTAssertEqual(rule.outcome(forBundleIdentifier: ProvisioningPolicyFixtures.bundle(bundle)), .exactMatch)
    }

    func testExactIdentifierDoesNotCoverAnotherBundleIdentifier() {
        let rule = compatibility(component: bundle)

        XCTAssertEqual(
            rule.outcome(forBundleIdentifier: ProvisioningPolicyFixtures.bundle(ProvisioningPolicyFixtures.otherBundleIdentifier)),
            .mismatch
        )
    }

    func testExactIdentifierDoesNotCoverAPrefixOfIt() {
        let rule = compatibility(component: "com.example.synthetic")

        XCTAssertEqual(rule.outcome(forBundleIdentifier: ProvisioningPolicyFixtures.bundle("com.example")), .mismatch)
    }

    // MARK: - Wildcard scope

    func testWildcardCoversABundleIdentifierUnderItsComponentPrefix() {
        let rule = compatibility(component: "com.example.*")

        XCTAssertEqual(rule.outcome(forBundleIdentifier: ProvisioningPolicyFixtures.bundle("com.example.anything")), .wildcardMatch)
        XCTAssertEqual(rule.outcome(forBundleIdentifier: ProvisioningPolicyFixtures.bundle("com.example.deeper.still")), .wildcardMatch)
    }

    func testWildcardDoesNotCoverAcrossAComponentBoundaryThatIsNotInItsScope() {
        let rule = compatibility(component: "com.example.*")

        XCTAssertEqual(rule.outcome(forBundleIdentifier: ProvisioningPolicyFixtures.bundle("com.exampleOther.app")), .mismatch)
        XCTAssertEqual(rule.outcome(forBundleIdentifier: ProvisioningPolicyFixtures.bundle("com.other.app")), .mismatch)
    }

    func testBareWildcardCoversEveryBundleIdentifierUnderThePrefix() {
        let rule = compatibility(component: "*")

        XCTAssertEqual(rule.outcome(forBundleIdentifier: ProvisioningPolicyFixtures.bundle("anything.at.all")), .wildcardMatch)
    }

    func testWildcardScopeIncludesTheApplicationIdentifierPrefix() {
        let rule = compatibility(component: "com.example.*")

        XCTAssertEqual(rule.wildcardScopePrefix, team + ".com.example.")
    }

    func testExactIdentifierHasNoWildcardScope() {
        let rule = compatibility(component: bundle)

        XCTAssertNil(rule.wildcardScopePrefix)
    }

    // MARK: - Missing or unsplittable scope

    func testMissingApplicationIdentifierIsIndeterminateRatherThanAMismatch() {
        let rule = ProvisioningIdentifierCompatibility(applicationIdentifier: nil)

        XCTAssertEqual(rule.outcome(forBundleIdentifier: ProvisioningPolicyFixtures.bundle()), .indeterminate)
    }

    func testFullValueWithoutADeclaredPrefixMatchesOnlyExactText() throws {
        let rule = ProvisioningIdentifierCompatibility(
            applicationIdentifier: try ProvisioningApplicationIdentifier(
                fullValue: bundle,
                applicationIdentifierPrefix: nil
            )
        )

        XCTAssertEqual(rule.outcome(forBundleIdentifier: ProvisioningPolicyFixtures.bundle(bundle)), .exactMatch)
        XCTAssertEqual(
            rule.outcome(forBundleIdentifier: ProvisioningPolicyFixtures.bundle(ProvisioningPolicyFixtures.otherBundleIdentifier)),
            .indeterminate,
            "Without a declared prefix, ZynSign does not split the identifier to guess a scope."
        )
    }

    func testClaimCarryingAnotherPrefixIsAMismatch() {
        let rule = compatibility(component: bundle)

        XCTAssertEqual(
            rule.outcome(forApplicationIdentifierValue: "\(ProvisioningPolicyFixtures.otherTeamIdentifier).\(bundle)"),
            .mismatch
        )
    }

    // MARK: - Application-identifier claims

    func testClaimEqualToTheDeclaredIdentifierMatches() {
        let rule = compatibility(component: bundle)

        XCTAssertEqual(rule.outcome(forApplicationIdentifierValue: "\(team).\(bundle)"), .exactMatch)
    }

    func testClaimInsideAWildcardScopeMatches() {
        let rule = compatibility(component: "com.example.*")

        XCTAssertEqual(rule.outcome(forApplicationIdentifierValue: "\(team).com.example.anything"), .wildcardMatch)
    }

    func testClaimOutsideTheScopeIsAMismatch() {
        let rule = compatibility(component: "com.example.*")

        XCTAssertEqual(rule.outcome(forApplicationIdentifierValue: "\(team).com.other.app"), .mismatch)
        XCTAssertEqual(rule.outcome(forApplicationIdentifierValue: "com.example.anything"), .mismatch)
    }

    func testClaimAgainstAnExactScopeIsAMismatchWhenItDiffers() {
        let rule = compatibility(component: bundle)

        XCTAssertEqual(rule.outcome(forApplicationIdentifierValue: "\(team).\(ProvisioningPolicyFixtures.otherBundleIdentifier)"), .mismatch)
    }

    func testEmptyClaimIsIndeterminate() {
        let rule = compatibility(component: bundle)

        XCTAssertEqual(rule.outcome(forApplicationIdentifierValue: ""), .indeterminate)
    }

    func testClaimIsNeverReParsedToWidenTheScope() throws {
        let rule = ProvisioningIdentifierCompatibility(
            applicationIdentifier: try ProvisioningApplicationIdentifier(
                fullValue: "\(team).\(bundle)",
                applicationIdentifierPrefix: nil
            )
        )

        XCTAssertEqual(
            rule.outcome(forApplicationIdentifierValue: "\(team).\(bundle).extra"),
            .indeterminate,
            "A claim may not add structure the profile's identifier does not state."
        )
    }

    // MARK: - Expected identifier

    func testExpectedIdentifierCombinesTheDeclaredPrefixAndTheBundleIdentifier() {
        let rule = compatibility(component: "com.example.*")

        XCTAssertEqual(
            rule.expectedApplicationIdentifier(for: ProvisioningPolicyFixtures.bundle("com.example.app")),
            "\(team).com.example.app"
        )
    }

    func testExpectedIdentifierIsUnavailableWithoutADeclaredPrefix() throws {
        let rule = ProvisioningIdentifierCompatibility(
            applicationIdentifier: try ProvisioningApplicationIdentifier(
                fullValue: bundle,
                applicationIdentifierPrefix: nil
            )
        )

        XCTAssertNil(rule.expectedApplicationIdentifier(for: ProvisioningPolicyFixtures.bundle()))
    }

    // MARK: - Support

    private func compatibility(component: String) -> ProvisioningIdentifierCompatibility {
        ProvisioningIdentifierCompatibility(
            applicationIdentifier: ProvisioningPolicyFixtures.applicationIdentifier(component: component)
        )
    }
}
