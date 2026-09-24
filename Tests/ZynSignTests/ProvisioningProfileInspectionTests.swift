import Foundation
import XCTest
@testable import ZynSign

/// Application-layer tests use a synthetic payload decoder so CMS handling is
/// never implied by the test suite.
final class ProvisioningProfileInspectionTests: XCTestCase {

    private let creationDate = Date(timeIntervalSince1970: 1_700_000_000)
    private let expirationDate = Date(timeIntervalSince1970: 1_900_000_000)

    private func profilePayload() -> ProvisioningProfilePayload {
        let root: [String: Any] = [
            ProvisioningProfileKeys.uuid: "12345678-1234-4ABC-8DEF-1234567890AB",
            ProvisioningProfileKeys.name: "Synthetic Inspection Profile",
            ProvisioningProfileKeys.creationDate: creationDate,
            ProvisioningProfileKeys.expirationDate: expirationDate,
            ProvisioningProfileKeys.applicationIdentifierPrefix: ["TEAM123456"],
            ProvisioningProfileKeys.teamIdentifier: ["TEAM123456"],
            ProvisioningProfileKeys.platform: ["iPhoneOS"],
            ProvisioningProfileKeys.entitlements: [
                ProvisioningProfileEntitlementKeys.applicationIdentifier: "TEAM123456.com.example.synthetic",
                ProvisioningProfileEntitlementKeys.teamIdentifier: "TEAM123456",
                ProvisioningProfileEntitlementKeys.getTaskAllow: true,
            ],
        ]
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: root,
            format: .binary,
            options: []
        ) else {
            XCTFail("Could not create the synthetic inspection payload")
            return ProvisioningProfilePayload(plistData: Data())
        }
        return ProvisioningProfilePayload(plistData: data)
    }

    private func useCase(
        decoder: (any ProvisioningProfilePayloadDecoder)? = nil,
        clock: any EvaluationClock = FixedEvaluationClock(instant: Date(timeIntervalSince1970: 1_800_000_000))
    ) -> ProvisioningProfileInspectionUseCase {
        ProvisioningProfileInspectionUseCase(
            payloadDecoder: decoder ?? SyntheticPayloadDecoder(payload: profilePayload()),
            parser: PropertyListProvisioningProfileParser(),
            clock: clock
        )
    }

    func testApplicationUseCaseSeparatesParsingStructuralValidityAndTrust() throws {
        let result = try useCase().inspect(payload: profilePayload())

        XCTAssertTrue(result.isParsed)
        XCTAssertTrue(result.isStructurallyValid)
        XCTAssertTrue(result.isCurrentlyValid)
        XCTAssertEqual(result.profile.profileName, "Synthetic Inspection Profile")
        XCTAssertEqual(result.validation.validity?.periodStatus, .currentlyValid)
        XCTAssertEqual(result.authenticity, .notEvaluated)
        XCTAssertEqual(result.authorization, .notEvaluated)
    }

    func testApplicationUseCaseUsesInjectedClockForExpiredProfile() throws {
        let result = try useCase(
            clock: FixedEvaluationClock(instant: expirationDate.addingTimeInterval(1))
        ).inspect(payload: profilePayload())
        XCTAssertEqual(result.validation.validity?.periodStatus, .expired)
        XCTAssertFalse(result.isCurrentlyValid)
        XCTAssertTrue(result.isStructurallyValid)
    }

    func testRawInputFlowsThroughDecoder() throws {
        let decoder = RecordingPayloadDecoder(payload: profilePayload())
        let input = ProvisioningProfileInput(bytes: Data([0x01, 0x02, 0x03]))
        let result = try useCase(decoder: decoder).inspect(input)
        XCTAssertEqual(decoder.callCount, 1)
        XCTAssertTrue(result.isStructurallyValid)
    }

    func testEmptyRawInputDoesNotReachDecoder() {
        let decoder = RecordingPayloadDecoder(payload: profilePayload())
        XCTAssertThrowsError(
            try useCase(decoder: decoder).inspect(ProvisioningProfileInput(bytes: Data()))
        ) { error in
            XCTAssertEqual((error as? ZynSignError)?.provisioningProfileFailure, .emptyInput)
        }
        XCTAssertEqual(decoder.callCount, 0)
    }

    func testOversizedRawInputDoesNotReachDecoder() {
        let decoder = RecordingPayloadDecoder(payload: profilePayload())
        let input = ProvisioningProfileInput(
            bytes: Data(repeating: 0x00, count: ProvisioningProfileInput.maximumByteCount + 1)
        )
        XCTAssertThrowsError(try useCase(decoder: decoder).inspect(input)) { error in
            XCTAssertEqual((error as? ZynSignError)?.provisioningProfileFailure, .inputTooLarge)
        }
        XCTAssertEqual(decoder.callCount, 0)
    }

    func testMalformedPayloadRemainsAControlledError() {
        let payload = ProvisioningProfilePayload(plistData: Data("truncated".utf8))
        XCTAssertThrowsError(try useCase().inspect(payload: payload)) { error in
            XCTAssertEqual((error as? ZynSignError)?.provisioningProfileFailure, .malformedPayload)
            XCTAssertFalse(error.localizedDescription.contains("truncated"))
        }
    }

    func testForeignDecoderFailureIsSanitized() {
        let decoder = FailingPayloadDecoder()
        XCTAssertThrowsError(
            try useCase(decoder: decoder).inspect(ProvisioningProfileInput(bytes: Data([0x01])))
        ) { error in
            let profileError = error as? ZynSignError
            XCTAssertEqual(profileError?.provisioningProfileFailure, .platformParsingFailure)
            XCTAssertFalse(error.localizedDescription.contains("private provider path"))
            XCTAssertFalse(profileError?.debugDescription.contains("private provider path") == true)
        }
    }

    func testFutureAuthenticityEvidenceHasAnExplicitSlotButAuthorizationRemainsUnevaluated() throws {
        let payload = ProvisioningProfilePayload(
            plistData: profilePayload().plistData,
            authenticity: .authenticated
        )
        let result = try useCase().inspect(payload: payload)
        XCTAssertEqual(result.authenticity, .authenticated)
        XCTAssertEqual(result.authorization, .notEvaluated)
    }
}

private struct SyntheticPayloadDecoder: ProvisioningProfilePayloadDecoder {
    let payload: ProvisioningProfilePayload

    func decodePayload(from input: ProvisioningProfileInput) throws -> ProvisioningProfilePayload {
        payload
    }
}

private final class RecordingPayloadDecoder: ProvisioningProfilePayloadDecoder {
    let payload: ProvisioningProfilePayload
    private(set) var callCount = 0

    init(payload: ProvisioningProfilePayload) {
        self.payload = payload
    }

    func decodePayload(from input: ProvisioningProfileInput) throws -> ProvisioningProfilePayload {
        callCount += 1
        return payload
    }
}

private struct FailingPayloadDecoder: ProvisioningProfilePayloadDecoder {

    func decodePayload(from input: ProvisioningProfileInput) throws -> ProvisioningProfilePayload {
        throw NSError(
            domain: "private provider path",
            code: 99,
            userInfo: [NSLocalizedDescriptionKey: "private provider path and bytes"]
        )
    }
}
