import Foundation
import XCTest
@testable import ZynSign

/// The typed entitlement-comparison rules.
///
/// Nothing here rewrites an entitlement, and nothing here treats an
/// incomparable value as either a pass or a conflict.
final class ProvisioningPolicyEntitlementComparisonTests: XCTestCase {

    private let claim = "com.example.synthetic.claim"

    // MARK: - Strings

    func testMatchingStringValueMatches() {
        XCTAssertEqual(
            compare(.string("value"), .string("value")),
            .claimMatchesAuthorization
        )
    }

    func testDifferentStringValueConflicts() {
        XCTAssertEqual(
            compare(.string("value"), .string("other")),
            .claimValueConflicts
        )
    }

    func testStringValueIsNotCaseFolded() {
        XCTAssertEqual(
            compare(.string("Production"), .string("production")),
            .claimValueConflicts
        )
    }

    // MARK: - Booleans

    func testMatchingBooleansMatch() {
        XCTAssertEqual(compare(.boolean(true), .boolean(true)), .claimMatchesAuthorization)
        XCTAssertEqual(compare(.boolean(false), .boolean(false)), .claimMatchesAuthorization)
    }

    func testDifferentBooleansConflict() {
        XCTAssertEqual(compare(.boolean(true), .boolean(false)), .claimValueConflicts)
    }

    func testBooleanIsNotComparedWithAnInteger() {
        XCTAssertEqual(compare(.boolean(true), .integer(1)), .claimValueConflicts)
    }

    // MARK: - Numbers

    func testMatchingIntegersMatch() {
        XCTAssertEqual(compare(.integer(7), .integer(7)), .claimMatchesAuthorization)
    }

    func testDifferentIntegersConflict() {
        XCTAssertEqual(compare(.integer(7), .integer(8)), .claimValueConflicts)
    }

    func testIntegerAndRealAreNotCoerced() {
        XCTAssertEqual(
            compare(.integer(7), .real(7.0)),
            .cannotBeEvaluated,
            "Exact representations are preserved, so no equality is invented."
        )
    }

    func testMatchingRealsMatch() {
        XCTAssertEqual(compare(.real(1.5), .real(1.5)), .claimMatchesAuthorization)
    }

    // MARK: - Arrays

    func testIdenticalArraysMatch() {
        XCTAssertEqual(
            compare(.array([.string("one"), .string("two")]), .array([.string("one"), .string("two")])),
            .claimMatchesAuthorization
        )
    }

    func testRequestedArrayOutsideTheAuthorizedArrayConflicts() {
        XCTAssertEqual(
            compare(.array([.string("one"), .string("three")]), .array([.string("one"), .string("two")])),
            .claimValueConflicts
        )
    }

    func testRequestedArrayContainedInTheAuthorizedArrayIsNotDecided() {
        XCTAssertEqual(
            compare(.array([.string("one")]), .array([.string("one"), .string("two")])),
            .cannotBeEvaluated,
            "Whether the array is a set, a list, or an ordered sequence is not established."
        )
    }

    func testReorderedArrayIsNotDecided() {
        XCTAssertEqual(
            compare(.array([.string("two"), .string("one")]), .array([.string("one"), .string("two")])),
            .cannotBeEvaluated
        )
    }

    // MARK: - Dictionaries

    func testMatchingDictionariesMatch() {
        XCTAssertEqual(
            compare(
                .dictionary(["mode": .string("production")]),
                .dictionary(["mode": .string("production"), "extra": .boolean(true)])
            ),
            .claimMatchesAuthorization,
            "The allowlist may carry claims the request does not make."
        )
    }

    func testNestedDictionaryConflictIsAConflict() {
        XCTAssertEqual(
            compare(
                .dictionary(["mode": .string("development")]),
                .dictionary(["mode": .string("production")])
            ),
            .claimValueConflicts
        )
    }

    func testNestedDictionaryKeyTheProfileDoesNotCarryConflicts() {
        XCTAssertEqual(
            compare(
                .dictionary(["mode": .string("production"), "unexpected": .string("value")]),
                .dictionary(["mode": .string("production")])
            ),
            .claimValueConflicts
        )
    }

    func testNestedStructuralDifferenceIsReportedFromTheNestedRule() {
        XCTAssertEqual(
            compare(
                .dictionary(["values": .array([.string("one")])]),
                .dictionary(["values": .array([.string("one"), .string("two")])])
            ),
            .cannotBeEvaluated
        )
    }

    // MARK: - Unsupported and incomparable forms

    func testDataValueIsUnsupported() {
        XCTAssertEqual(
            compare(.data(Data([0x01])), .data(Data([0x01]))),
            .unsupportedByPolicy
        )
    }

    func testDateValueIsUnsupported() {
        XCTAssertEqual(
            compare(.date(Date(timeIntervalSince1970: 0)), .date(Date(timeIntervalSince1970: 0))),
            .unsupportedByPolicy
        )
    }

    func testDifferentValueFormsConflict() {
        XCTAssertEqual(compare(.string("value"), .array([.string("value")])), .claimValueConflicts)
    }

    func testDeeplyNestedValueStopsAtTheComparisonBound() {
        var requested = ProvisioningProfileValue.string("leaf")
        var authorized = ProvisioningProfileValue.string("leaf")
        for _ in 0..<(ProvisioningEntitlementComparator.maximumDepth + 2) {
            requested = .dictionary(["next": requested])
            authorized = .dictionary(["next": authorized])
        }

        XCTAssertEqual(
            ProvisioningEntitlementComparator.compare(requested: requested, authorized: authorized),
            .unsupportedByPolicy
        )
    }

    // MARK: - Claims against an allowlist

    func testMissingClaimIsNotAuthorized() {
        XCTAssertEqual(
            ProvisioningEntitlementComparator.compare(
                requestedKey: claim,
                requestedValue: .string("value"),
                authorized: ProvisioningProfileEntitlements(values: [:])
            ),
            .claimNotAuthorized
        )
    }

    func testMissingAllowlistCannotBeCompared() {
        XCTAssertEqual(
            ProvisioningEntitlementComparator.compare(
                requestedKey: claim,
                requestedValue: .string("value"),
                authorized: nil
            ),
            .cannotBeEvaluated
        )
    }

    func testMissingRequestedValueCannotBeCompared() {
        XCTAssertEqual(
            ProvisioningEntitlementComparator.compare(
                requestedKey: claim,
                requestedValue: nil,
                authorized: ProvisioningProfileEntitlements(values: [claim: .string("value")])
            ),
            .cannotBeEvaluated
        )
    }

    func testSpeciallyHandledClaimsAreNotDecidedByTheGenericRules() {
        for key in [
            ProvisioningProfileEntitlementKeys.applicationIdentifier,
            ProvisioningProfileEntitlementKeys.teamIdentifier,
            ProvisioningProfileEntitlementKeys.getTaskAllow,
        ] {
            XCTAssertTrue(ProvisioningEntitlementComparator.isSpeciallyHandled(key))
            XCTAssertEqual(
                ProvisioningEntitlementComparator.compare(
                    requestedKey: key,
                    requestedValue: .string("anything"),
                    authorized: ProvisioningProfileEntitlements(values: [key: .string("anything")])
                ),
                .requiresSpecialHandling
            )
        }
    }

    func testEveryRequestedClaimIsEvaluatedInKeyOrder() {
        let requested = ProvisioningProfileEntitlements(values: [
            "b.claim": .string("value"),
            "a.claim": .string("value"),
            ProvisioningProfileEntitlementKeys.getTaskAllow: .boolean(true),
        ])

        let evaluations = ProvisioningEntitlementComparator.evaluate(
            requested: requested,
            against: ProvisioningProfileEntitlements(values: ["a.claim": .string("value")])
        )

        XCTAssertEqual(evaluations.map(\.key), ["a.claim", "b.claim", ProvisioningProfileEntitlementKeys.getTaskAllow])
        XCTAssertEqual(evaluations.map(\.outcome), [
            .claimMatchesAuthorization,
            .claimNotAuthorized,
            .requiresSpecialHandling,
        ])
    }

    // MARK: - Support

    private func compare(
        _ requested: ProvisioningProfileValue,
        _ authorized: ProvisioningProfileValue
    ) -> ProvisioningEntitlementComparisonOutcome {
        ProvisioningEntitlementComparator.compare(requested: requested, authorized: authorized)
    }
}
