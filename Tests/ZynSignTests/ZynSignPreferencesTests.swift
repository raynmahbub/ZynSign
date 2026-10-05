import XCTest
@testable import ZynSign

/// The preference model: what a fresh install holds, what a stored document
/// may look like, and what an earlier version's values become.
final class ZynSignPreferencesTests: XCTestCase {

    // MARK: - Defaults

    func testShippedDefaultsAreWhatAFreshInstallUses() {
        let preferences = ZynSignPreferences.shippedDefault

        XCTAssertEqual(preferences.general.landingTab, .home)
        XCTAssertTrue(preferences.general.hapticFeedbackEnabled)
        XCTAssertEqual(preferences.general.animationPreference, .standard)
        XCTAssertFalse(preferences.general.onboardingCompleted)

        XCTAssertNil(preferences.signing.preferredIdentityFingerprint)
        XCTAssertNil(preferences.signing.preferredProfileName)
        XCTAssertTrue(preferences.signing.rememberSelections)
        XCTAssertTrue(preferences.signing.automaticCompatibilityAnalysis)

        XCTAssertFalse(preferences.security.biometricLockEnabled)
        XCTAssertTrue(preferences.security.requireAuthenticationForSensitiveActions)
        XCTAssertTrue(preferences.security.hideSensitiveInformationWhenLocked)
        XCTAssertEqual(preferences.security.sensitiveDataVisibility, .masked)
        XCTAssertEqual(preferences.security.sessionTimeout, .oneMinute)

        XCTAssertTrue(preferences.storage.automaticTemporaryCleanup)

        XCTAssertTrue(preferences.diagnostics.keepDiagnosticHistory)
        XCTAssertFalse(preferences.diagnostics.detailedTechnicalLogs)
        XCTAssertFalse(preferences.diagnostics.developerDiagnostics)

        XCTAssertEqual(preferences.appearance.appearanceMode, .system)
        XCTAssertFalse(preferences.appearance.increaseContrast)
        XCTAssertTrue(preferences.appearance.respectsSystemTextSize)

        XCTAssertEqual(preferences.advanced.workingDirectoryBehavior, .temporary)
        XCTAssertEqual(preferences.advanced.temporaryCleanupPolicy, .onExit)
        XCTAssertEqual(preferences.advanced.verificationStrictness, .standard)
    }

    func testAShippedBuildHasNoGroupAwayFromItsDefault() {
        XCTAssertEqual(ZynSignPreferences.shippedDefault.changedGroupCount, 0)
    }

    func testAChangedGroupIsCountedOnce() {
        var preferences = ZynSignPreferences.shippedDefault
        preferences.security.sessionTimeout = .fiveMinutes
        XCTAssertEqual(preferences.changedGroupCount, 1)

        preferences.general.landingTab = .settings
        XCTAssertEqual(preferences.changedGroupCount, 2)
    }

    func testNoExperimentalFeatureIsOfferedBeforeItExists() {
        // The Advanced section reads this list to decide what to show. An
        // empty list is the only honest answer for features that are not
        // implemented, and adding one is additive.
        XCTAssertTrue(ExperimentalFeature.allCases.isEmpty)
    }

    // MARK: - Encoding

    func testEveryGroupSurvivesARoundTrip() {
        var preferences = ZynSignPreferences.shippedDefault
        preferences.general.landingTab = .certificates
        preferences.general.hapticFeedbackEnabled = false
        preferences.general.animationPreference = .off
        preferences.general.onboardingCompleted = true
        preferences.signing.preferredIdentityFingerprint = "AABBCCDD"
        preferences.signing.preferredProfileName = "ZynSign Development"
        preferences.signing.rememberSelections = false
        preferences.signing.automaticCompatibilityAnalysis = false
        preferences.security.biometricLockEnabled = true
        preferences.security.requireAuthenticationForSensitiveActions = false
        preferences.security.hideSensitiveInformationWhenLocked = false
        preferences.security.sessionTimeout = .immediately
        preferences.security.sensitiveDataVisibility = .visible
        preferences.storage.automaticTemporaryCleanup = false
        preferences.diagnostics.keepDiagnosticHistory = false
        preferences.diagnostics.detailedTechnicalLogs = true
        preferences.diagnostics.developerDiagnostics = true
        preferences.appearance.appearanceMode = .dark
        preferences.appearance.increaseContrast = true
        preferences.advanced.workingDirectoryBehavior = .applicationSupport
        preferences.advanced.temporaryCleanupPolicy = .manual
        preferences.advanced.verificationStrictness = .strict

        let data = try! JSONEncoder().encode(preferences)
        let decoded = try! JSONDecoder().decode(ZynSignPreferences.self, from: data)

        XCTAssertEqual(decoded, preferences)
    }

    // MARK: - Tolerance

    func testADocumentThatDescribesNothingLoadsShippedDefaults() throws {
        let decoded = try decode(#"{"schemaVersion": 1}"#)
        XCTAssertEqual(decoded.general, GeneralPreferences())
        XCTAssertEqual(decoded.advanced, AdvancedPreferences())
    }

    func testAnEmptyDocumentLoadsShippedDefaults() throws {
        let decoded = try decode("{}")
        XCTAssertEqual(decoded.general, GeneralPreferences())
        XCTAssertEqual(decoded, ZynSignPreferences.shippedDefault)
    }

    func testAnAbsentGroupKeepsTheGroupsThatArePresent() throws {
        let decoded = try decode("""
        {"appearance": {"appearanceMode": "dark"}, "advanced": {"verificationStrictness": "strict"}}
        """)

        XCTAssertEqual(decoded.appearance.appearanceMode, .dark)
        XCTAssertEqual(decoded.advanced.verificationStrictness, .strict)
        XCTAssertEqual(decoded.general, GeneralPreferences())
        XCTAssertEqual(decoded.security, SecurityPreferences())
    }

    func testAGroupThisBuildCannotReadFallsBackOnItsOwn() throws {
        // A later version may change one group's shape. That must cost the
        // user the settings in that group and nothing else.
        let decoded = try decode("""
        {"appearance": {"appearanceMode": "dark"}, "advanced": {"verificationStrictness": 12}}
        """)

        XCTAssertEqual(decoded.appearance.appearanceMode, .dark)
        XCTAssertEqual(decoded.advanced, AdvancedPreferences())
    }

    func testAnUnrecognisedValueInsideAGroupFallsBackOnThatGroup() throws {
        let decoded = try decode("""
        {"general": {"landingTab": "photos"}}
        """)

        XCTAssertEqual(decoded.general, GeneralPreferences())
    }

    func testKeysThisBuildDoesNotKnowAreIgnored() throws {
        let decoded = try decode("""
        {"general": {"landingTab": "library", "somethingLater": true}, "future": {"a": 1}}
        """)

        XCTAssertEqual(decoded.general.landingTab, .library)
    }

    func testTheSchemaVersionIsInformational() throws {
        XCTAssertEqual(try decode(#"{"schemaVersion": 1}"#).schemaVersion, 1)
        // A newer document is read rather than refused.
        XCTAssertEqual(try decode(#"{"schemaVersion": 99}"#).schemaVersion, 99)
        // An absent one is assumed to be this build's.
        XCTAssertEqual(try decode("{}").schemaVersion, ZynSignPreferences.schemaVersion)
    }

    // MARK: - Derived behaviour

    func testAnimationNeverExceedsWhatTheSystemAllows() {
        var preferences = ZynSignPreferences.shippedDefault

        preferences.general.animationPreference = .standard
        XCTAssertTrue(preferences.general.animationPreference.permitsAnimation(systemReduceMotion: false))
        XCTAssertFalse(preferences.general.animationPreference.permitsAnimation(systemReduceMotion: true))

        preferences.general.animationPreference = .reduced
        XCTAssertFalse(preferences.general.animationPreference.permitsAnimation(systemReduceMotion: false))

        preferences.general.animationPreference = .off
        XCTAssertFalse(preferences.general.animationPreference.permitsAnimation(systemReduceMotion: false))
    }

    func testSessionTimeoutsStateHowLongTheyLast() {
        XCTAssertEqual(SessionTimeout.immediately.seconds, 0)
        XCTAssertEqual(SessionTimeout.oneMinute.seconds, 60)
        XCTAssertEqual(SessionTimeout.fiveMinutes.seconds, 300)
        XCTAssertEqual(SessionTimeout.fifteenMinutes.seconds, 900)
    }

    func testHiddenValuesAreTheOnlyOnesThatShowNothing() {
        XCTAssertFalse(SensitiveDataVisibility.hidden.showsValues)
        XCTAssertTrue(SensitiveDataVisibility.masked.showsValues)
        XCTAssertTrue(SensitiveDataVisibility.visible.showsValues)
    }

    func testShippedThemesAreStored() {
        // Storefront joins the set and ships as the default from v0.1.0-alpha.2.
        XCTAssertEqual(ZynSignTheme.allCases.count, 6)
        XCTAssertEqual(ZynSignTheme.defaultIdentifier, "zynsign.storefront")
    }

    // MARK: - Reset

    func testResetRestoresEveryGroup() {
        var preferences = ZynSignPreferences.shippedDefault
        preferences.general.landingTab = .settings
        preferences.security.biometricLockEnabled = true
        preferences.appearance.appearanceMode = .dark

        preferences.resetToShippedDefaults(preservingOnboardingCompletion: false)

        XCTAssertEqual(preferences, ZynSignPreferences.shippedDefault)
    }

    func testResetDoesNotWalkAUserBackThroughOnboarding() {
        var preferences = ZynSignPreferences.shippedDefault
        preferences.general.onboardingCompleted = true
        preferences.general.landingTab = .settings

        preferences.resetToShippedDefaults(preservingOnboardingCompletion: true)

        XCTAssertTrue(preferences.general.onboardingCompleted)
        XCTAssertEqual(preferences.general.landingTab, .home)
    }

    // MARK: - Legacy migration

    func testLegacyAppearanceAndOnboardingAreCarriedOver() {
        let defaults = UserDefaults(suiteName: "ZynSignPreferencesTests.legacy-carry")!
        defaults.removePersistentDomain(forName: "ZynSignPreferencesTests.legacy-carry")
        defaults.set(2, forKey: LegacyPreferenceValues.appearanceKey)
        defaults.set(true, forKey: LegacyPreferenceValues.onboardingKey)

        let migrated = ZynSignPreferences.migrated(from: LegacyPreferenceValues(defaults: defaults))

        XCTAssertEqual(migrated.appearance.appearanceMode, .dark)
        XCTAssertTrue(migrated.general.onboardingCompleted)
        XCTAssertEqual(migrated.security, SecurityPreferences())
        XCTAssertEqual(migrated.changedGroupCount, 2)
    }

    func testLegacyAppearanceValuesAreReadAsTheInterfaceReadThem() {
        let defaults = UserDefaults(suiteName: "ZynSignPreferencesTests.legacy-appearance")!
        defaults.removePersistentDomain(forName: "ZynSignPreferencesTests.legacy-appearance")
        let legacy = LegacyPreferenceValues(defaults: defaults)
        XCTAssertNil(legacy.appearanceMode)
        XCTAssertTrue(legacy.isEmpty)

        defaults.set(0, forKey: LegacyPreferenceValues.appearanceKey)
        XCTAssertEqual(LegacyPreferenceValues(defaults: defaults).appearanceMode, .system)
        defaults.set(1, forKey: LegacyPreferenceValues.appearanceKey)
        XCTAssertEqual(LegacyPreferenceValues(defaults: defaults).appearanceMode, .light)
        defaults.set(2, forKey: LegacyPreferenceValues.appearanceKey)
        XCTAssertEqual(LegacyPreferenceValues(defaults: defaults).appearanceMode, .dark)
        defaults.set(7, forKey: LegacyPreferenceValues.appearanceKey)
        XCTAssertNil(LegacyPreferenceValues(defaults: defaults).appearanceMode)
    }

    func testAnUnrecognisedLegacyValueIsIgnoredRatherThanGuessedAt() {
        let defaults = UserDefaults(suiteName: "ZynSignPreferencesTests.legacy-unknown")!
        defaults.removePersistentDomain(forName: "ZynSignPreferencesTests.legacy-unknown")
        defaults.set(9, forKey: LegacyPreferenceValues.appearanceKey)

        let migrated = ZynSignPreferences.migrated(from: LegacyPreferenceValues(defaults: defaults))

        XCTAssertEqual(migrated.appearance.appearanceMode, .system)
    }

    func testNothingToMigrateLeavesShippedDefaultsAlone() {
        let defaults = UserDefaults(suiteName: "ZynSignPreferencesTests.legacy-empty")!
        defaults.removePersistentDomain(forName: "ZynSignPreferencesTests.legacy-empty")

        let migrated = ZynSignPreferences.migrated(from: LegacyPreferenceValues(defaults: defaults))

        XCTAssertEqual(migrated, ZynSignPreferences.shippedDefault)
    }

    // MARK: - Helpers

    private func decode(_ json: String) throws -> ZynSignPreferences {
        try JSONDecoder().decode(ZynSignPreferences.self, from: Data(json.utf8))
    }
}
