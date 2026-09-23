import XCTest
@testable import ZynSign

/// Tests for the nested-code discovery failure vocabulary and its mapping onto
/// the application's error surface.
///
/// The reason is the stable part of a rejection: it is what a caller switches
/// on, and it must survive the mapping into `ZynSignError` unchanged, with a
/// category that is honest about whose fault the failure is and a user message
/// that carries nothing from the technical detail.
final class NestedCodeFailureTests: XCTestCase {

    func testEveryReasonIsStructuredWithACategoryAndASafeMessage() {
        var messages = Set<String>()
        for reason in NestedCodeFailure.allCases {
            XCTAssertFalse(reason.rawValue.isEmpty)
            XCTAssertEqual(reason.displayName, reason.rawValue)
            XCTAssertFalse(reason.userMessage.isEmpty)
            // One safe message per reason; no two reasons share one.
            XCTAssertTrue(messages.insert(reason.userMessage).inserted)
        }
        XCTAssertEqual(messages.count, NestedCodeFailure.allCases.count)
    }

    func testTheReasonSetCoversTheRequiredDistinctions() {
        let required: Set<NestedCodeFailure> = [
            .invalidApplicationBundle, .invalidPath, .pathSafetyViolation,
            .notMachO, .malformedMachO, .unsupportedMachO,
            .ambiguousExecutable, .duplicateItem, .duplicateExecutablePath,
            .selfDependency, .dependencyCycle, .missingDependency,
            .unsupportedNestedCode, .conflictingBundleIdentifier, .resourceLimitExceeded,
        ]
        XCTAssertEqual(Set(NestedCodeFailure.allCases), required)
    }

    func testCategoriesAreHonest() {
        XCTAssertEqual(NestedCodeFailure.unsupportedMachO.category, .unsupportedInput)
        XCTAssertEqual(NestedCodeFailure.unsupportedNestedCode.category, .unsupportedInput)
        XCTAssertEqual(NestedCodeFailure.resourceLimitExceeded.category, .unsupportedInput)
        XCTAssertEqual(NestedCodeFailure.ambiguousExecutable.category, .ambiguousInput)
        for reason in NestedCodeFailure.allCases {
            // Every reason describes the application bundle: none of them is
            // an internal defect or a missing platform capability.
            XCTAssertNotEqual(reason.category, .internalFailure)
            XCTAssertNotEqual(reason.category, .capabilityUnavailable)
        }
    }

    func testTheFailureRenderingIsLogSafe() throws {
        let path = try XCTUnwrap(BundlePath(rawValue: "Frameworks/Frame.framework/Frame"))
        let error = NestedCodeDiscoveryError(
            .pathSafetyViolation,
            at: path,
            detail: "The entry recorded at 'Frameworks/Frame.framework/Frame' is a symbolic link."
        )

        XCTAssertTrue(error.description.contains("pathSafetyViolation"))
        XCTAssertTrue(error.description.contains("Frameworks/Frame.framework/Frame"))
        XCTAssertFalse(error.description.contains("symbolic link"))
    }

    func testTheFailureBelongingToTheBundleCarriesNoLocation() {
        let error = NestedCodeDiscoveryError(
            .dependencyCycle,
            detail: "The dependency graph contains a cycle through: A, B."
        )
        XCTAssertNil(error.path)
        XCTAssertEqual(error.description, "zynsign.nestedCode(dependencyCycle)")
    }

    func testTheBridgePreservesTheReasonAndTheCategory() throws {
        let path = try XCTUnwrap(BundlePath(rawValue: "Frameworks/Frame.framework"))
        for reason in NestedCodeFailure.allCases {
            let failure = NestedCodeDiscoveryError(reason, at: path, detail: "detail-for-\(reason.rawValue)")
            let error = ZynSignError.nestedCodeDiscovery(failure)

            XCTAssertEqual(error.nestedCodeFailure, reason)
            XCTAssertEqual(error.category, reason.category)
            XCTAssertEqual(error.userMessage, reason.userMessage)
            XCTAssertEqual(error.errorDescription, reason.userMessage)
            XCTAssertEqual(error.diagnosticDetail, failure.detail)
            XCTAssertNil(error.underlyingError)
            // The detail never reaches the user-facing rendering.
            XCTAssertFalse(error.userMessage.contains("detail-for-"))
            XCTAssertFalse(error.description.contains("detail-for-"))
            XCTAssertTrue(error.debugDescription.contains(reason.rawValue))
            XCTAssertTrue(error.debugDescription.contains("detail-for-\(reason.rawValue)"))
        }
    }

    func testTheBridgeNeverRendersABundleLocationToTheUser() throws {
        let path = try XCTUnwrap(BundlePath(rawValue: "Frameworks/Frame.framework/Frame"))
        let failure = NestedCodeDiscoveryError(
            .malformedMachO,
            at: path,
            detail: "The established executable at 'Frameworks/Frame.framework/Frame' is malformed."
        )

        let error = ZynSignError.nestedCodeDiscovery(failure)

        XCTAssertFalse(error.userMessage.contains("Frameworks"))
        XCTAssertTrue(error.debugDescription.contains("Frameworks/Frame.framework/Frame"))
    }

    /// A reason is the only thing discovery may promote into user-facing text,
    /// and the message for a reason describes the application rather than
    /// naming a diagnosis.
    func testUserMessagesDoNotNameInternalVocabulary() {
        for reason in NestedCodeFailure.allCases {
            let message = reason.userMessage
            XCTAssertFalse(message.contains("Mach-O"), "\(reason.rawValue) names a format in user-facing text.")
            XCTAssertFalse(message.contains("Info.plist"))
            XCTAssertFalse(message.contains("LC_CODE_SIGNATURE"))
            XCTAssertFalse(message.contains("ZynSignError"))
            XCTAssertFalse(message.contains("nil"))
        }
    }
}
