import XCTest
@testable import ZynSign

final class CertificateErrorTests: XCTestCase {

    func testInvalidCertificateDataError() {
        let error = ZynSignError.invalidCertificateData(diagnosticDetail: "test detail")
        XCTAssertEqual(error.category, .invalidInput)
        XCTAssertFalse(error.userMessage.isEmpty)
        XCTAssertEqual(error.diagnosticDetail, "test detail")
    }

    func testUnsupportedCertificateError() {
        let error = ZynSignError.unsupportedCertificate()
        XCTAssertEqual(error.category, .unsupportedInput)
        XCTAssertFalse(error.userMessage.isEmpty)
    }

    func testMalformedCertificateError() {
        let error = ZynSignError.malformedCertificate()
        XCTAssertEqual(error.category, .invalidInput)
    }

    func testSigningKeyUnavailableError() {
        let error = ZynSignError.signingKeyUnavailable()
        XCTAssertEqual(error.category, .capabilityUnavailable)
    }

    func testSigningFailedError() {
        let error = ZynSignError.signingFailed()
        XCTAssertEqual(error.category, .internalFailure)
    }

    func testIdentityStoreFailureError() {
        let error = ZynSignError.identityStoreFailure()
        XCTAssertEqual(error.category, .storageFailure)
    }

    func testSigningIdentityNotFoundError() {
        let error = ZynSignError.signingIdentityNotFound()
        XCTAssertEqual(error.category, .invalidInput)
    }

    func testErrorUserMessageDoesNotContainSensitiveData() {
        // Ensure error messages do not contain private key material, passwords, etc.
        let errors = [
            ZynSignError.invalidCertificateData(),
            ZynSignError.unsupportedCertificate(),
            ZynSignError.malformedCertificate(),
            ZynSignError.signingKeyUnavailable(),
            ZynSignError.signingFailed(),
            ZynSignError.identityStoreFailure(),
            ZynSignError.signingIdentityNotFound()
        ]
        for error in errors {
            let message = error.userMessage.lowercased()
            XCTAssertFalse(message.contains("private key"))
            XCTAssertFalse(message.contains("password"))
            XCTAssertFalse(message.contains("token"))
        }
    }

    func testMalformedInputProducesStructuredError() {
        // Simulate parser throwing for malformed input
        let parserError = ZynSignError.invalidCertificateData(diagnosticDetail: "malformed DER")
        XCTAssertEqual(parserError.category, .invalidInput)
        XCTAssertNotNil(parserError.diagnosticDetail)
    }
}
