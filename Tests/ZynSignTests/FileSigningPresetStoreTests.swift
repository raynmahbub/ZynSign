import XCTest
@testable import ZynSign

final class FileSigningPresetStoreTests: XCTestCase {

    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ZynSignSigningPresetStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testVersionOneCatalogDecodesWithCurrentDefaults() async throws {
        let location = temporaryDirectory.appendingPathComponent("presets.json")
        let catalog = """
        {"schemaVersion":1,"presets":[{"id":{"rawValue":"11111111-1111-1111-1111-111111111111"},"name":"Personal","provisioningProfileName":"My Profile","createdAt":1000,"updatedAt":1000}]}
        """
        try Data(catalog.utf8).write(to: location)
        let store = FileSigningPresetStore(catalogLocation: location)
        let presets = try await store.allPresets()
        XCTAssertEqual(presets.count, 1)
        XCTAssertEqual(presets[0].name, "Personal")
        XCTAssertEqual(presets[0].kind, .custom)
        XCTAssertEqual(presets[0].entitlementsSlot, .modern)
        XCTAssertEqual(presets[0].verificationPreference, .always)
        XCTAssertEqual(presets[0].usage, .empty)
        XCTAssertEqual(presets[0].distribution.scope, .local)
        XCTAssertNil(presets[0].distribution.schedule)
        XCTAssertNil(presets[0].certificateFingerprint)
    }

    func testEmptyStoreReturnsNoPresets() async throws {
        let store = FileSigningPresetStore(catalogLocation: temporaryDirectory.appendingPathComponent("presets.json"))
        let presets = try await store.allPresets()
        XCTAssertTrue(presets.isEmpty)
        XCTAssertEqual(try await store.count(), 0)
    }

    func testUpsertAndRetrieve() async throws {
        let store = FileSigningPresetStore(catalogLocation: temporaryDirectory.appendingPathComponent("presets.json"))
        let now = Date()
        let fingerprint = CertificateFingerprint(algorithm: .sha256, hexDigest:
            String(repeating: "f", count: 64))!
        let preset = SigningPreset(
            name: "Personal",
            certificateFingerprint: fingerprint,
            provisioningProfileName: "My Profile",
            createdAt: now,
            updatedAt: now
        )
        try await store.upsert(preset)
        XCTAssertEqual(try await store.count(), 1)
        let fetched = try await store.preset(withID: preset.id)
        XCTAssertEqual(fetched, preset)
    }

    func testPersistsAcrossInstances() async throws {
        let location = temporaryDirectory.appendingPathComponent("presets.json")
        let now = Date()
        let first = FileSigningPresetStore(catalogLocation: location)
        let preset = SigningPreset(
            name: "Personal",
            createdAt: now,
            updatedAt: now
        )
        try await first.upsert(preset)

        let second = FileSigningPresetStore(catalogLocation: location)
        let fetched = try await second.preset(withID: preset.id)
        XCTAssertEqual(fetched?.name, "Personal")
    }

    func testRemove() async throws {
        let store = FileSigningPresetStore(catalogLocation: temporaryDirectory.appendingPathComponent("presets.json"))
        let now = Date()
        let preset = SigningPreset(name: "Throwaway", createdAt: now, updatedAt: now)
        try await store.upsert(preset)
        try await store.remove(presetWithID: preset.id)
        XCTAssertEqual(try await store.count(), 0)
    }

    func testCorruptCatalogThrows() async throws {
        let location = temporaryDirectory.appendingPathComponent("presets.json")
        try Data("not json".utf8).write(to: location)
        let store = FileSigningPresetStore(catalogLocation: location)
        do {
            _ = try await store.allPresets()
            XCTFail("Expected typed error for corrupt catalog")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.category, .storageFailure)
        }
    }
}

final class FileSigningHistoryStoreTests: XCTestCase {

    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ZynSignSigningHistoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testEmptyStoreReturnsNoRecords() async throws {
        let store = FileSigningHistoryStore(
            journalLocation: temporaryDirectory.appendingPathComponent("history.json"),
            capacity: 100
        )
        XCTAssertEqual(try await store.count(), 0)
        XCTAssertEqual(try await store.allRecords(), [])
    }

    func testAppendIsMostRecentFirst() async throws {
        let store = FileSigningHistoryStore(
            journalLocation: temporaryDirectory.appendingPathComponent("history.json"),
            capacity: 100
        )
        let now = Date()
        let first = SigningRecord(
            presetID: nil,
            certificateFingerprint: nil,
            sourceBundleIdentifier: nil,
            sourceDisplayName: nil,
            stoppingStage: nil,
            errorCode: nil,
            outputFileName: nil,
            outputByteCount: nil,
            startedAt: now.addingTimeInterval(-100),
            duration: 0.1
        )
        let second = SigningRecord(
            presetID: nil,
            certificateFingerprint: nil,
            sourceBundleIdentifier: nil,
            sourceDisplayName: nil,
            stoppingStage: nil,
            errorCode: nil,
            outputFileName: nil,
            outputByteCount: nil,
            startedAt: now,
            duration: 0.2
        )
        try await store.append(first)
        try await store.append(second)
        let records = try await store.allRecords()
        XCTAssertEqual(records.first?.id, second.id)
    }

    func testCapacityEvictsOldest() async throws {
        let store = FileSigningHistoryStore(
            journalLocation: temporaryDirectory.appendingPathComponent("history.json"),
            capacity: 2
        )
        let now = Date()
        for i in 0..<5 {
            let record = SigningRecord(
                presetID: nil,
                certificateFingerprint: nil,
                sourceBundleIdentifier: nil,
                sourceDisplayName: nil,
                stoppingStage: nil,
                errorCode: nil,
                outputFileName: nil,
                outputByteCount: nil,
                startedAt: now.addingTimeInterval(TimeInterval(i)),
                duration: 0
            )
            try await store.append(record)
        }
        XCTAssertEqual(try await store.count(), 2)
    }

    func testClear() async throws {
        let store = FileSigningHistoryStore(
            journalLocation: temporaryDirectory.appendingPathComponent("history.json"),
            capacity: 100
        )
        try await store.append(SigningRecord(
            presetID: nil,
            certificateFingerprint: nil,
            sourceBundleIdentifier: nil,
            sourceDisplayName: nil,
            stoppingStage: nil,
            errorCode: nil,
            outputFileName: nil,
            outputByteCount: nil,
            startedAt: Date(),
            duration: 0
        ))
        try await store.clear()
        XCTAssertEqual(try await store.count(), 0)
    }

    func testRecordsForPresetFiltersCorrectly() async throws {
        let store = FileSigningHistoryStore(
            journalLocation: temporaryDirectory.appendingPathComponent("history.json"),
            capacity: 100
        )
        let presetA = PresetIdentifier()
        let presetB = PresetIdentifier()
        let now = Date()
        try await store.append(SigningRecord(
            presetID: presetA,
            certificateFingerprint: nil,
            sourceBundleIdentifier: nil,
            sourceDisplayName: nil,
            stoppingStage: nil,
            errorCode: nil,
            outputFileName: nil,
            outputByteCount: nil,
            startedAt: now,
            duration: 0
        ))
        try await store.append(SigningRecord(
            presetID: presetB,
            certificateFingerprint: nil,
            sourceBundleIdentifier: nil,
            sourceDisplayName: nil,
            stoppingStage: nil,
            errorCode: nil,
            outputFileName: nil,
            outputByteCount: nil,
            startedAt: now,
            duration: 0
        ))
        let forA = try await store.records(forPreset: presetA)
        XCTAssertEqual(forA.count, 1)
        XCTAssertEqual(forA.first?.presetID, presetA)
    }
}
