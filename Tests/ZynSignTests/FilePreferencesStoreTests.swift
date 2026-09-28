import XCTest
@testable import ZynSign

/// The file-backed preferences store: what a stored document may contain, how
/// a damaged one is handled, and how an earlier version's values are adopted.
@MainActor
final class FilePreferencesStoreTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = try SettingsFixtures.makeTemporaryDirectory()
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        try await super.tearDown()
    }

    // MARK: - Reading

    func testAnAbsentDocumentGivesShippedDefaultsAndNothingToMigrate() {
        let store = FilePreferencesStore(
            location: SettingsFixtures.preferencesLocation(root: root),
            legacyDefaults: nil
        )

        XCTAssertEqual(store.snapshot, ZynSignPreferences.shippedDefault)
        XCTAssertFalse(store.didMigrateLegacyValues)
        XCTAssertNil(store.lastReadError)
    }

    func testADocumentIsReadOnceAtConstruction() throws {
        var stored = ZynSignPreferences.shippedDefault
        stored.general.landingTab = .profiles
        stored.appearance.appearanceMode = .light
        try writeDocument(stored)

        let store = makeStore()

        XCTAssertEqual(store.snapshot, stored)
        XCTAssertEqual(store.snapshot.general.landingTab, .profiles)
        XCTAssertEqual(store.snapshot.appearance.appearanceMode, .light)
    }

    func testADocumentThatCannotBeReadBecomesDefaultsAndSaysSo() throws {
        try Data("not a preferences document".utf8).write(
            to: SettingsFixtures.preferencesLocation(root: root)
        )

        let store = makeStore()

        XCTAssertEqual(store.snapshot, ZynSignPreferences.shippedDefault)
        XCTAssertNotNil(store.lastReadError)
    }

    func testAGroupThisBuildCannotReadLeavesTheRestUsable() throws {
        let document = """
        {"schemaVersion": 1, "preferences": {"general": {"landingTab": "library"}, "advanced": 4}}
        """
        try Data(document.utf8).write(to: SettingsFixtures.preferencesLocation(root: root))

        let store = makeStore()

        XCTAssertEqual(store.snapshot.general.landingTab, .library)
        XCTAssertEqual(store.snapshot.advanced, AdvancedPreferences())
        XCTAssertNil(store.lastReadError)
    }

    // MARK: - Writing

    func testSavingReplacesWhatWasStored() throws {
        let store = makeStore()
        var updated = ZynSignPreferences.shippedDefault
        updated.security.sessionTimeout = .immediately
        updated.diagnostics.detailedTechnicalLogs = true

        try store.save(updated)

        XCTAssertEqual(store.snapshot, updated)
        XCTAssertEqual(makeStore().snapshot, updated)
    }

    func testSavingWritesTheSchemaVersionWithThePreferences() throws {
        let store = makeStore()
        try store.save(ZynSignPreferences.shippedDefault)

        let document = try JSONDecoder().decode(
            FilePreferencesStoreDocument.self,
            from: try Data(contentsOf: SettingsFixtures.preferencesLocation(root: root))
        )

        XCTAssertEqual(document.schemaVersion, ZynSignPreferences.schemaVersion)
        XCTAssertEqual(document.preferences, ZynSignPreferences.shippedDefault)
    }

    func testSavingToALocationWhoseDirectoryCannotBeMadeFails() throws {
        // A file where the directory belongs is the one way writing fails,
        // and it must fail rather than silently lose the preference.
        let blocker = root.appendingPathComponent("Preferences.json")
        try Data("x".utf8).write(to: blocker)
        let store = FilePreferencesStore(
            location: blocker.appendingPathComponent("Preferences.json"),
            legacyDefaults: nil
        )

        XCTAssertThrowsError(try store.save(ZynSignPreferences.shippedDefault))
    }

    func testResetRestoresShippedDefaultsOnDisk() throws {
        let store = makeStore()
        var stored = ZynSignPreferences.shippedDefault
        stored.appearance.appearanceMode = .dark
        try store.save(stored)

        try store.reset()

        XCTAssertEqual(store.snapshot, ZynSignPreferences.shippedDefault)
        XCTAssertEqual(makeStore().snapshot, ZynSignPreferences.shippedDefault)
    }

    // MARK: - Legacy migration

    func testLegacyValuesAreAdoptedOnceAndThenRemoved() throws {
        let defaults = UserDefaults(suiteName: "ZynSignPreferencesTests.store-migration")!
        defaults.removePersistentDomain(forName: "ZynSignPreferencesTests.store-migration")
        defaults.set(2, forKey: LegacyPreferenceValues.appearanceKey)
        defaults.set(true, forKey: LegacyPreferenceValues.onboardingKey)

        let store = FilePreferencesStore(
            location: SettingsFixtures.preferencesLocation(root: root),
            legacyDefaults: defaults
        )

        XCTAssertTrue(store.didMigrateLegacyValues)
        XCTAssertEqual(store.snapshot.appearance.appearanceMode, .dark)
        XCTAssertTrue(store.snapshot.general.onboardingCompleted)
        // The migrated document is written immediately, so the migration
        // cannot happen twice.
        XCTAssertEqual(makeStore(legacyDefaults: defaults).snapshot.appearance.appearanceMode, .dark)
        // And the legacy keys are gone, so there is one source of truth.
        XCTAssertNil(defaults.object(forKey: LegacyPreferenceValues.appearanceKey))
        XCTAssertNil(defaults.object(forKey: LegacyPreferenceValues.onboardingKey))
    }

    func testAnExistingDocumentIsNeverOverwrittenByLegacyValues() {
        let defaults = UserDefaults(suiteName: "ZynSignPreferencesTests.store-existing")!
        defaults.removePersistentDomain(forName: "ZynSignPreferencesTests.store-existing")
        defaults.set(2, forKey: LegacyPreferenceValues.appearanceKey)

        let store = makeStore(legacyDefaults: defaults)
        var stored = ZynSignPreferences.shippedDefault
        stored.appearance.appearanceMode = .light
        try! store.save(stored)

        let reopened = makeStore(legacyDefaults: defaults)

        XCTAssertFalse(reopened.didMigrateLegacyValues)
        XCTAssertEqual(reopened.snapshot.appearance.appearanceMode, .light)
    }

    func testADamagedDocumentDoesNotTriggerMigration() throws {
        let defaults = UserDefaults(suiteName: "ZynSignPreferencesTests.store-damaged")!
        defaults.removePersistentDomain(forName: "ZynSignPreferencesTests.store-damaged")
        defaults.set(2, forKey: LegacyPreferenceValues.appearanceKey)
        try Data("{".utf8).write(to: SettingsFixtures.preferencesLocation(root: root))

        let store = makeStore(legacyDefaults: defaults)

        // A document that could not be read is not evidence that the user has
        // no preferences, so the legacy values are left where they are.
        XCTAssertFalse(store.didMigrateLegacyValues)
        XCTAssertEqual(store.snapshot, ZynSignPreferences.shippedDefault)
        XCTAssertNotNil(defaults.object(forKey: LegacyPreferenceValues.appearanceKey))
    }

    func testNoLegacyValuesMeansNoMigration() {
        let defaults = UserDefaults(suiteName: "ZynSignPreferencesTests.store-none")!
        defaults.removePersistentDomain(forName: "ZynSignPreferencesTests.store-none")

        let store = makeStore(legacyDefaults: defaults)

        XCTAssertFalse(store.didMigrateLegacyValues)
        XCTAssertEqual(store.snapshot, ZynSignPreferences.shippedDefault)
    }

    // MARK: - Helpers

    private func makeStore(legacyDefaults: UserDefaults? = nil) -> FilePreferencesStore {
        FilePreferencesStore(
            location: SettingsFixtures.preferencesLocation(root: root),
            legacyDefaults: legacyDefaults
        )
    }

    private func writeDocument(_ preferences: ZynSignPreferences) throws {
        try SettingsFixtures.write(
            try JSONEncoder().encode(FilePreferencesStoreDocument(
                schemaVersion: ZynSignPreferences.schemaVersion,
                preferences: preferences
            )),
            to: SettingsFixtures.preferencesLocation(root: root)
        )
    }
}

/// The document envelope, for tests that write one by hand.
private struct FilePreferencesStoreDocument: Codable {
    var schemaVersion: Int
    var preferences: ZynSignPreferences
}
