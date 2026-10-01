#if os(iOS)
import Security
import XCTest
@testable import ZynSign

/// The rule that decides whether a stored private key may sign.
///
/// The rule is the part of identity resolution that does not need a Keychain,
/// so it is exercised here — including the two shapes an imported `.p12`
/// identity actually arrives in, which is what made `.p12` import impossible
/// when the rule demanded one exact class.
final class SigningKeyProtectionRuleTests: XCTestCase {

    private let privateKey = kSecAttrKeyClassPrivate as String
    private let publicKey = kSecAttrKeyClassPublic as String

    /// The rule over the attributes an ordinary imported key carries, with each
    /// parameter *defaulted* rather than substituted: passing `nil` means what it
    /// says — the Keychain reported no such attribute — which is exactly what the
    /// negative cases are about. (An earlier version wrote `keyClass ?? privateKey`
    /// inside the helper, so `permits(keyClass: nil)` silently tested a private
    /// key and the case that checks an unreported class passed for the wrong
    /// reason. CI caught it; this shape cannot make that mistake.)
    private func permits(
        keyClass: String? = kSecAttrKeyClassPrivate as String,
        accessibility: String? = kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
        synchronizable: Bool? = nil,
        isExtractable: Bool? = nil
    ) -> Bool {
        SigningKeyProtectionRule.permits(
            keyClass: keyClass,
            accessibility: accessibility,
            synchronizable: synchronizable,
            isExtractable: isExtractable
        )
    }

    // MARK: - The classes a signing key may carry

    func testTheDeviceOnlyClassZynSignAsksForIsPermitted() {
        XCTAssertTrue(permits(accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String))
    }

    /// The regression this rule exists for: an identity imported through
    /// `SecPKCS12Import` is stored under the Keychain's default class, because
    /// the call takes no attribute dictionary and iOS offers no supported way
    /// to re-protect a private key afterwards. Refusing it refused every
    /// import the platform could legally produce.
    func testTheKeychainDefaultClassAnImportArrivesUnderIsPermitted() {
        XCTAssertTrue(permits(accessibility: kSecAttrAccessibleWhenUnlocked as String))
    }

    func testThePasscodeSetDeviceOnlyClassIsPermitted() {
        XCTAssertTrue(permits(accessibility: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String))
    }

    func testAClassReadableWhileTheDeviceIsLockedIsRefused() {
        XCTAssertFalse(permits(accessibility: kSecAttrAccessibleAfterFirstUnlock as String))
        XCTAssertFalse(permits(accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String))
        XCTAssertFalse(permits(accessibility: kSecAttrAccessibleAlways as String))
        XCTAssertFalse(permits(accessibility: kSecAttrAccessibleAlwaysThisDeviceOnly as String))
    }

    /// An absent attribute fails closed: the rule reads what the Keychain
    /// reports rather than assuming a protection the item never stated.
    func testAnUnreportedClassIsRefused() {
        XCTAssertFalse(
            SigningKeyProtectionRule.permits(
                keyClass: privateKey,
                accessibility: nil,
                synchronizable: nil,
                isExtractable: nil
            )
        )
    }

    func testAnUnknownClassIsRefused() {
        XCTAssertFalse(permits(accessibility: "com.example.not.a.keychain.class"))
    }

    // MARK: - The rest of the shape

    func testOnlyAPrivateKeyIsPermitted() {
        XCTAssertFalse(permits(keyClass: publicKey))
        XCTAssertFalse(permits(keyClass: kSecAttrKeyClassSymmetric as String))
        // A class the Keychain did not report is not a private class either.
        XCTAssertFalse(permits(keyClass: nil))
    }

    func testASynchronizableKeyIsRefused() {
        XCTAssertFalse(permits(synchronizable: true))
        XCTAssertTrue(permits(synchronizable: false))
    }

    func testAKeyThePlatformReportsAsExportableIsRefused() {
        XCTAssertFalse(permits(isExtractable: true))
    }

    /// DTS is explicit that an imported private key's bytes cannot be read
    /// back, and the attribute is not always surfaced, so its absence is
    /// treated as the platform's own import rather than as evidence the key
    /// can be exported.
    func testAnUnreportedExtractabilityAttributeDoesNotRefuseTheKey() {
        XCTAssertTrue(permits(isExtractable: false))
        XCTAssertTrue(permits(isExtractable: nil))
    }

    // MARK: - What a refusal records

    func testTheRefusalEvidenceNamesTheFourPolicyFacts() {
        let detail = SigningKeyProtectionRule.describe(
            keyClass: privateKey,
            accessibility: kSecAttrAccessibleWhenUnlocked as String,
            synchronizable: false,
            isExtractable: true
        )
        XCTAssertEqual(
            detail,
            "key=private, accessibility=when-unlocked, synchronizable=false, extractable=true"
        )
    }

    func testUnreportedAttributesAreNamedRatherThanOmitted() {
        let detail = SigningKeyProtectionRule.describe(
            keyClass: nil,
            accessibility: nil,
            synchronizable: nil,
            isExtractable: nil
        )
        XCTAssertEqual(
            detail,
            "key=unreported, accessibility=unreported, synchronizable=unreported, extractable=unreported"
        )
    }

    func testAKeyThatIsNotPrivateIsNamedAsSuch() {
        let detail = SigningKeyProtectionRule.describe(
            keyClass: publicKey,
            accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
            synchronizable: nil,
            isExtractable: nil
        )
        XCTAssertTrue(detail.hasPrefix("key=not-private"))
    }

    /// The Keychain reports protection classes as short codes. Those are not
    /// policy vocabulary, and a code in a log line reads like key material, so
    /// the rule names the classes it knows and labels the rest.
    func testAnUnrecognisedClassIsNamedAsSuchRatherThanEchoed() {
        XCTAssertEqual(SigningKeyProtectionRule.name(ofAccessibility: nil), "unreported")
        XCTAssertEqual(
            SigningKeyProtectionRule.name(ofAccessibility: kSecAttrAccessibleAlways as String),
            "unrecognised-class"
        )
        XCTAssertEqual(
            SigningKeyProtectionRule.name(ofAccessibility: "com.example.private"),
            "unrecognised-class"
        )
    }

    // MARK: - The permitted set

    func testThePermittedClassesAreExactlyTheUnlockedOnlyFamily() {
        XCTAssertEqual(
            SigningKeyProtectionRule.permittedAccessibilityClasses,
            [
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
                kSecAttrAccessibleWhenUnlocked as String,
                kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String
            ]
        )
    }
}
#endif
