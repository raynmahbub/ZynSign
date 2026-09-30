#if os(iOS)
import XCTest
import Security
@testable import ZynSign

/// The rule that decides whether a stored signing key may sign.
///
/// These tests exist because of a specific, shipped failure: registration
/// required an imported private key to carry
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, but `SecPKCS12Import` takes
/// no attribute dictionary, so the items it stores carry the Keychain's
/// default class — and every identity the platform could produce for a `.p12`
/// import was refused as unprotected. The first two cases pin both halves:
/// the class ZynSign asks for is accepted, and so is the class the platform
/// actually supplies; everything weaker is still refused.
final class SigningKeyProtectionRuleTests: XCTestCase {

    private let deviceOnly = kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
    private let unlocked = kSecAttrAccessibleWhenUnlocked as String
    private let privateKey = kSecAttrKeyClassPrivate as String

    func testAcceptsTheDeviceOnlyClassZynSignAsksFor() {
        XCTAssertTrue(SigningKeyProtectionRule.permits(
            keyClass: privateKey,
            accessibility: deviceOnly,
            synchronizable: false,
            isExtractable: false
        ))
    }

    /// The regression: this is the class a key imported through
    /// `SecPKCS12Import` carries, and the one the old rule refused.
    func testAcceptsTheKeychainsDefaultClassAnImportedKeyCarries() {
        XCTAssertTrue(SigningKeyProtectionRule.permits(
            keyClass: privateKey,
            accessibility: unlocked,
            synchronizable: false,
            isExtractable: false
        ))
    }

    func testAcceptsThePasscodeSetClassAndAnUnreportedExtractabilityAttribute() {
        XCTAssertTrue(SigningKeyProtectionRule.permits(
            keyClass: privateKey,
            accessibility: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String,
            synchronizable: false,
            isExtractable: nil
        ))
    }

    func testRefusesEveryClassThatStaysReadableWhileTheDeviceIsLocked() {
        let refused = [
            kSecAttrAccessibleAfterFirstUnlock as String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
            kSecAttrAccessibleAlways as String,
            kSecAttrAccessibleAlwaysThisDeviceOnly as String,
            "com.example.not-a-real-class"
        ]
        for accessibility in refused {
            XCTAssertFalse(SigningKeyProtectionRule.permits(
                keyClass: privateKey,
                accessibility: accessibility,
                synchronizable: false,
                isExtractable: false
            ), "\(accessibility) must not be accepted")
        }
    }

    func testRefusesAKeyWithNoReportedProtectionClass() {
        XCTAssertFalse(SigningKeyProtectionRule.permits(
            keyClass: privateKey,
            accessibility: nil,
            synchronizable: false,
            isExtractable: false
        ))
    }

    func testRefusesASynchronizableKeyOrOneThatIsNotPrivate() {
        XCTAssertFalse(SigningKeyProtectionRule.permits(
            keyClass: privateKey,
            accessibility: unlocked,
            synchronizable: true,
            isExtractable: false
        ))
        XCTAssertFalse(SigningKeyProtectionRule.permits(
            keyClass: kSecAttrKeyClassPublic as String,
            accessibility: unlocked,
            synchronizable: false,
            isExtractable: false
        ))
        XCTAssertFalse(SigningKeyProtectionRule.permits(
            keyClass: nil,
            accessibility: unlocked,
            synchronizable: false,
            isExtractable: false
        ))
    }

    /// A key the platform reports as exportable is refused even when
    /// everything else about it is in order.
    func testRefusesAKeyThePlatformReportsAsExportable() {
        XCTAssertFalse(SigningKeyProtectionRule.permits(
            keyClass: privateKey,
            accessibility: deviceOnly,
            synchronizable: false,
            isExtractable: true
        ))
    }

    func testPermittedClassesAreExactlyTheUnlockedOnlySet() {
        XCTAssertEqual(SigningKeyProtectionRule.permittedAccessibilityClasses, [deviceOnly, unlocked,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String])
    }
}
#endif
