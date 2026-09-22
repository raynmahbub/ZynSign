#if os(iOS)
import XCTest
import Security
@testable import ZynSign

/// Pure mapping tests: do not query Keychain and need no opt-in environment.
final class IdentityKeychainErrorTests: XCTestCase {
    func testAuthorizationStorageAndMissingKeyHaveDistinctReasons() {
        for status in [errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled] {
            XCTAssertEqual(IdentityKeychainAccess.reason(for: status), .authorizationFailure)
        }
        XCTAssertEqual(IdentityKeychainAccess.reason(for: errSecItemNotFound, missing: .privateKeyUnavailable), .privateKeyUnavailable)
        XCTAssertEqual(IdentityKeychainAccess.reason(for: errSecDuplicateItem), .duplicateIdentity)
        XCTAssertEqual(IdentityKeychainAccess.reason(for: errSecMissingEntitlement), .platformRestriction)
        XCTAssertEqual(IdentityKeychainAccess.reason(for: errSecDecode), .malformedStoredIdentity)
        XCTAssertEqual(IdentityKeychainAccess.reason(for: errSecNotAvailable), .keychainAccessFailure)
    }

    func testUnknownFrameworkErrorDiscardsItsPayload() {
        let marker = "synthetic-sensitive-diagnostic"
        let foreign = CFErrorCreate(nil, marker as CFString, 17,
                                    [kCFErrorDescriptionKey as String: marker] as CFDictionary)
        let error = IdentityKeychainAccess.signingError(foreign)
        XCTAssertEqual(error.identityFailure, .signingFailure)
        XCTAssertNil(error.underlyingError)
        XCTAssertFalse(String(reflecting: error).contains(marker))
        XCTAssertFalse(error.description.contains(marker))
    }

    func testSigningAuthorizationErrorPreservesOnlyReason() {
        let foreign = CFErrorCreate(nil, kCFErrorDomainOSStatus, Int(errSecAuthFailed), nil)
        let error = IdentityKeychainAccess.signingError(foreign)
        XCTAssertEqual(error.identityFailure, .authorizationFailure)
        XCTAssertNil(error.underlyingError)
    }
}
#endif
