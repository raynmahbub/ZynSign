#if os(iOS)
import Security
import XCTest
@testable import ZynSign

/// Security framework status mapping around `SecPKCS12Import`.
///
/// The importer cannot be fully exercised without a real identity in an iOS
/// Keychain, but its refusal mapping is pure and must distinguish PKCS#12
/// passphrase statuses from nearby, unrelated Keychain statuses.
final class ApplePKCS12ImporterTests: XCTestCase {

    func testPKCS12MACVerificationFailureMeansInvalidPassphrase() {
        let error = ApplePKCS12Importer.importFailure(for: -25264)

        XCTAssertEqual(error.identityFailure, .invalidPassphrase)
    }

    func testMissingRequiredPassphraseMeansInvalidPassphrase() {
        let error = ApplePKCS12Importer.importFailure(for: -25260)

        XCTAssertEqual(error.identityFailure, .invalidPassphrase)
    }

    func testSecurityAuthenticationFailureMeansInvalidPassphrase() {
        let error = ApplePKCS12Importer.importFailure(for: errSecAuthFailed)

        XCTAssertEqual(error.identityFailure, .invalidPassphrase)
    }

    func testNearbyKeychainErrorsAreNotMisreportedAsPassphraseFailures() {
        let statuses: [OSStatus] = [-25294, -25295]
        for status in statuses {
            let error = ApplePKCS12Importer.importFailure(for: status)

            XCTAssertEqual(error.identityFailure, .containerImportFailed)
        }
    }
}
#endif
