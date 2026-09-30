import XCTest
@testable import ZynSign

/// Tests for the tweak library coordinator over in-memory doubles.
final class TweakLibraryServiceTests: XCTestCase {

    private final class InMemoryTweakStore: TweakLibraryStore, TweakPayloadStorage, @unchecked Sendable {
        var records: [TweakDescriptor] = []
        var payloads: [UUID: Data] = [:]

        func all() throws -> [TweakDescriptor] { records }
        func upsert(_ descriptor: TweakDescriptor) throws {
            records.removeAll { $0.id == descriptor.id }
            records.append(descriptor)
        }
        func remove(id: UUID) throws {
            records.removeAll { $0.id == id }
        }
        func findByFingerprint(sha256Hex: String) throws -> [TweakDescriptor] {
            records.filter { $0.sha256Hex == sha256Hex }
        }
        func store(_ data: Data, id: UUID) throws { payloads[id] = data }
        func payload(for id: UUID) throws -> Data? { payloads[id] }
        func removePayload(id: UUID) throws { payloads[id] = nil }
    }

    private var store: InMemoryTweakStore!
    private var digest: RecordingMessageDigest!
    private var service: TweakLibraryService!
    private var fingerprintCounter = 0

    override func setUp() {
        super.setUp()
        store = InMemoryTweakStore()
        digest = RecordingMessageDigest()
        service = TweakLibraryService(store: store, payloads: store, digest: digest)
    }

    private func preparedDigest() -> Digest {
        fingerprintCounter += 1
        let seed = UInt8(fingerprintCounter % 255)
        return Digest(algorithm: .sha256, bytes: Data(repeating: seed, count: 32))!
    }

    func testImportRecordsKindNameSizeAndPayload() throws {
        digest.preparedDigest = preparedDigest()
        let result = try service.importPayload(Data([1, 2, 3]), fileName: "Loader.dylib")
        guard case .success(let outcome) = result else { return XCTFail("Import must succeed.") }
        XCTAssertEqual(outcome.descriptor.name, "Loader")
        XCTAssertEqual(outcome.descriptor.kind, .dynamicLibrary)
        XCTAssertEqual(outcome.descriptor.byteSize, 3)
        XCTAssertEqual(try service.payload(for: outcome.descriptor.id), Data([1, 2, 3]))
        XCTAssertEqual(try service.all().count, 1)
    }

    func testEmptyPayloadRefuses() throws {
        guard case .failure(let refusal) = try service.importPayload(Data(), fileName: "empty.dylib") else {
            return XCTFail("An empty payload must refuse.")
        }
        XCTAssertEqual(refusal, .emptyFile)
        XCTAssertTrue(store.records.isEmpty)
    }

    func testOversizedPayloadRefusesBeforeHashing() throws {
        let tooBig = TweakLibraryService.maximumPayloadBytes + 1
        guard case .failure(.fileTooLarge) = try service.importPayload(Data(count: tooBig), fileName: "big.dylib") else {
            return XCTFail("An oversized payload must refuse.")
        }
        XCTAssertTrue(digest.requested.isEmpty)
    }

    func testDuplicateFingerprintRefuses() throws {
        digest.preparedDigest = preparedDigest()
        guard case .success = try service.importPayload(Data([1]), fileName: "a.dylib") else {
            return XCTFail("First import must succeed.")
        }
        // Same prepared digest → same fingerprint → duplicate.
        guard case .failure(.duplicate(let existingName)) = try service.importPayload(Data([2]), fileName: "b.dylib") else {
            return XCTFail("A duplicate fingerprint must refuse.")
        }
        XCTAssertEqual(existingName, "a")
        XCTAssertEqual(try service.all().count, 1)
    }

    func testRenameGroupAndTogglePersist() throws {
        digest.preparedDigest = preparedDigest()
        guard case .success(let outcome) = try service.importPayload(Data([9]), fileName: "mod.framework") else {
            return XCTFail("Import must succeed.")
        }
        let id = outcome.descriptor.id
        XCTAssertTrue(try service.rename(id: id, to: "Renamed"))
        XCTAssertFalse(try service.rename(id: id, to: "   "))
        try service.setGroup(id: id, group: "Theme")
        try service.setEnabled(id: id, enabled: false)
        let record = try service.record(id: id)
        XCTAssertEqual(record?.name, "Renamed")
        XCTAssertEqual(record?.group, "Theme")
        XCTAssertEqual(record?.enabledByDefault, false)
        XCTAssertEqual(try service.groups(), ["Theme"])
    }

    func testRemoveDeletesRecordAndPayload() throws {
        digest.preparedDigest = preparedDigest()
        guard case .success(let outcome) = try service.importPayload(Data([5]), fileName: "x.dylib") else {
            return XCTFail("Import must succeed.")
        }
        try service.remove(id: outcome.descriptor.id)
        XCTAssertTrue(try service.all().isEmpty)
        XCTAssertNil(try service.payload(for: outcome.descriptor.id))
    }

    func testPlanSelectionRespectsTheStore() throws {
        digest.preparedDigest = preparedDigest()
        guard case .success(let outcome) = try service.importPayload(Data([7]), fileName: "y.dylib") else {
            return XCTFail("Import must succeed.")
        }
        guard case .success(let plan) = try service.makePlan(selectionIDs: [outcome.descriptor.id]) else {
            return XCTFail("A valid selection must plan.")
        }
        XCTAssertEqual(plan.entries.map(\.id), [outcome.descriptor.id])
        guard case .failure(.empty) = try service.makePlan(selectionIDs: []) else {
            return XCTFail("An empty selection must refuse.")
        }
    }

    func testManifestSerializesDeterministically() throws {
        digest.preparedDigest = preparedDigest()
        guard case .success(let outcome) = try service.importPayload(Data([3]), fileName: "z.dylib") else {
            return XCTFail("Import must succeed.")
        }
        guard case .success(let plan) = try service.makePlan(selectionIDs: [outcome.descriptor.id]) else {
            return XCTFail("A valid selection must plan.")
        }
        let data = try service.manifestData(for: plan)
        XCTAssertTrue(data.count > 0)
        let decoded = try JSONDecoder().decode([TweakManifestEntry].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.targetDirectory, "Frameworks")
    }

    func testDisplayNameFallsBackGracefully() {
        XCTAssertEqual(TweakLibraryService.displayName(forFileName: "Some/Path/Loader.dylib"), "Loader")
        XCTAssertEqual(TweakLibraryService.displayName(forFileName: "noextension"), "noextension")
        XCTAssertEqual(TweakLibraryService.displayName(forFileName: ""), "Tweak")
    }
}
