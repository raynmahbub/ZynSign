#if os(iOS)
import XCTest
import Security
@testable import ZynSign

/// The rule that decides whether a stored signing key may sign.
///
/// These tests exist because the rule is what `.p12` import hit: an identity
/// imported through `SecPKCS12Import` carries the Keychain's default
/// protection class, because that function takes no attribute dictionary and
/// iOS offers no supported way to re-protect a private key after creation.
/// A rule that demanded one exact class therefore refused every identity the
/// platform could actually produce, and the user saw "The required identity
/// protection is not available" no matter what they did. The cases below pin
/// both halves: the platform's own import must pass, and every protection
/// weaker than *unreadable while locked* must still fail.
final class SigningKeyProtectionRuleTests: XCTestCase {

    private let accessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
    private let privateKeyClass = kSecAttrKeyClassPrivate as String

    func testPermitsTheDeviceOnlyClassZynSignAsksFor() {
        XCTAssertTrue(SigningKeyProtectionRule.permits(
            keyClass: privateKeyClass,
            accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
            synchronizable: false,
            isExtractable: false
        ))
    }

    /// The case that made import possible: `SecPKCS12Import` stores its items
    /// under the Keychain's default class and cannot be asked for another.
    func testPermitsTheKeychainsDefaultClassThatAnImportedKeyCarries() {
        XCTAssertTrue(SigningKeyProtectionRule.permits(
            keyClass: privateKeyClass,
            accessibility: kSecAttrAccessibleWhenUnlocked as String,
            synchronizable: false,
            isExtractable: false
        ))
    }

    /// Some versions do not surface `kSecAttrIsExtractable`. DTS is explicit
    /// that an imported private key's bytes cannot be read back, so absence is
    /// the platform's own import rather than evidence of exportability.
    func testPermitsAnImportedKeyWithUnreportedExtractability() {
        XCTAssertTrue(SigningKeyProtectionRule.permits(
            keyClass: privateKeyClass,
            accessibility: accessibility,
            synchronizable: false,
            isExtractable: nil
        ))
    }

    /// A key whose protection lets it be read while the device is locked is
    /// refused, whatever else it reports.
    func testPermitsOnlyUnlockedOnlyProtectionClasses() {
        for refused in [
            kSecAttrAccessibleAfterFirstUnlock as String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
            kSecAttrAccessibleAlways as String,
            kSecAttrAccessibleAlwaysThisDeviceOnly as String
        ] {
            XCTAssertFalse(SigningKeyProtectionRule.permits(
                keyClass: privateKeyClass,
                accessibility: refused,
                synchronizable: false,
                isExtractable: false
            ), "\(refused) must not be accepted")
        }
        XCTAssertTrue(SigningKeyProtectionRule.permittedAccessibilityClasses.contains(accessibility))
    }

    /// An unreported class is not a licence to sign: the rule fails closed.
    func testRefusesAnUnreportedOrUnknownProtectionClass() {
        XCTAssertFalse(SigningKeyProtectionRule.permits(
            keyClass: privateKeyClass, accessibility: nil, synchronizable: false, isExtractable: false
        ))
        XCTAssertFalse(SigningKeyProtectionRule.permits(
            keyClass: privateKeyClass, accessibility: "unknown-class", synchronizable: false, isExtractable: false
        ))
    }

    func testRefusesAKeyThatCanSyncOrIsNotAPrivateKey() {
        XCTAssertFalse(SigningKeyProtectionRule.permits(
            keyClass: privateKeyClass, accessibility: accessibility, synchronizable: true, isExtractable: false
        ))
        XCTAssertFalse(SigningKeyProtectionRule.permits(
            keyClass: kSecAttrKeyClassPublic as String, accessibility: accessibility,
            synchronizable: false, isExtractable: false
        ))
        XCTAssertFalse(SigningKeyProtectionRule.permits(
            keyClass: nil, accessibility: accessibility, synchronizable: false, isExtractable: false
        ))
    }

    /// A key the platform says can be exported is refused even though its
    /// protection class is the one ZynSign prefers.
    func testRefusesAKeyThePlatformReportsAsExportable() {
        XCTAssertFalse(SigningKeyProtectionRule.permits(
            keyClass: privateKeyClass, accessibility: accessibility,
            synchronizable: false, isExtractable: true
        ))
    }
}
#endif
