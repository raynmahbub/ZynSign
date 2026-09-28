import Foundation
import XCTest
@testable import ZynSign

final class BackupRecoveryTests: XCTestCase {
    private let passphrase = "correct horse battery staple"

    private func setup() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(LibraryCatalogDocument()).write(to: root.appendingPathComponent("catalog.json"))
        let preferences = try JSONEncoder().encode(ZynSignPreferences.shippedDefault)
        let document = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1,
            "preferences": try JSONSerialization.jsonObject(with: preferences)])
        try document.write(to: root.appendingPathComponent("Preferences.json"))
        return root
    }

    func testEncryptedSelectiveBackupAndColdRestore() async throws {
        let root = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RecoveryStore(root: root)
        let item = try await service.create(categories: [.library], password: passphrase)
        let file = await service.url(for: item)
        let bytes = try Data(contentsOf: file)
        XCTAssertTrue(bytes.starts(with: Data("ZYNSBK01".utf8)))
        XCTAssertFalse(bytes.range(of: Data("schemaVersion".utf8)) != nil)
        let preview = try await service.inspect(file, password: passphrase)
        XCTAssertEqual(preview.version, 1)
        XCTAssertEqual(preview.categories, [.library])
        XCTAssertEqual(preview.entries.map(\.path), ["catalog.json"])

        try Data("damaged".utf8).write(to: root.appendingPathComponent("catalog.json"))
        _ = try await service.prepare(file, password: passphrase, categories: [.library])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("catalog.json")), Data("damaged".utf8))
        RecoveryStore.applyPending(at: root)
        XCTAssertEqual(try FileApplicationRecordStore.readCatalog(at: root.appendingPathComponent("catalog.json")).count, 0)
        let status = await service.status()
        XCTAssertEqual(status, "Restore verified after restart")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Preferences.json").path))
    }

    func testRejectsWrongPassphraseAndCorruptionWithoutReplacingPreviousBackup() async throws {
        let root = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RecoveryStore(root: root)
        let item = try await service.create(categories: [.library], password: passphrase)
        let url = await service.url(for: item)
        do { _ = try await service.inspect(url, password: "incorrect-long-passphrase"); XCTFail("Accepted wrong passphrase") }
        catch { XCTAssertNotNil(error.localizedDescription) }
        var bytes = try Data(contentsOf: url)
        bytes[bytes.count - 1] ^= 1
        let damaged = root.appendingPathComponent("damaged.zynbackup")
        try bytes.write(to: damaged)
        do { _ = try await service.prepare(damaged, password: passphrase, categories: [.library]); XCTFail("Accepted corruption") }
        catch { XCTAssertNotNil(error.localizedDescription) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Recovery/PendingRestore.json").path))
    }

    func testRejectsUnselectedScopeAndLeavesLibraryIntact() async throws {
        let root = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RecoveryStore(root: root)
        let item = try await service.create(categories: [.library], password: passphrase)
        let file = await service.url(for: item)
        do { _ = try await service.prepare(file, password: passphrase, categories: [.settings]); XCTFail("Accepted absent scope") }
        catch { XCTAssertNotNil(error.localizedDescription) }
        XCTAssertEqual(try FileApplicationRecordStore.readCatalog(at: root.appendingPathComponent("catalog.json")).count, 0)
    }

    func testStreamsLargePackageButNeverExportsQueueProfilesOrKeys() async throws {
        let root = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = Data((0..<(2_200_000)).map { UInt8($0 % 251) })
        let artifact = LibraryFixtures.reference(to: package)
        let record = LibraryFixtures.record(artifact: artifact)
        let files = root.appendingPathComponent("Artifacts")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try package.write(to: files.appendingPathComponent(artifact.artifactID.rawValue + ".ipa"))
        let catalog = FileApplicationRecordStore(catalogLocation: root.appendingPathComponent("catalog.json"))
        try await catalog.insert(record)
        let privateFolder = root.appendingPathComponent("SigningQueue/Profiles")
        try FileManager.default.createDirectory(at: privateFolder, withIntermediateDirectories: true)
        try Data("DO NOT EXPORT PRIVATE MATERIAL".utf8).write(to: privateFolder.appendingPathComponent("private.mobileprovision"))

        let store = RecoveryStore(root: root)
        let item = try await store.create(categories: [.library], password: passphrase)
        let file = await store.url(for: item)
        let encrypted = try Data(contentsOf: file)
        XCTAssertNil(encrypted.range(of: Data("DO NOT EXPORT PRIVATE MATERIAL".utf8)))
        let manifest = try await store.inspect(file, password: passphrase)
        XCTAssertEqual(manifest.libraryItems, 1)
        XCTAssertEqual(manifest.entries.count, 2)
        XCTAssertFalse(manifest.entries.contains { $0.path.contains("SigningQueue") })
        XCTAssertEqual(manifest.entries.last?.bytes, Int64(package.count))
    }

    func testDamagedStagedRestoreDoesNotTouchLiveData() async throws {
        let root = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(root: root)
        let item = try await store.create(categories: [.library], password: passphrase)
        let file = await store.url(for: item)
        _ = try await store.prepare(file, password: passphrase, categories: [.library])
        let before = try Data(contentsOf: root.appendingPathComponent("catalog.json"))
        let recovery = root.appendingPathComponent("Recovery")
        let stage = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: recovery, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("Stage-") })
        try Data("broken".utf8).write(to: stage.appendingPathComponent("catalog.json"))
        RecoveryStore.applyPending(at: root)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("catalog.json")), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.appendingPathComponent("PendingRestore.json").path))
        let status = await store.status()
        XCTAssertTrue(status.contains("damaged"))
    }

    func testHistoryRenameDeleteAndRecoveryOfUnindexedBackup() async throws {
        let root = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(root: root)
        let item = try await store.create(categories: [.settings], password: passphrase)
        try await store.rename(item, to: "Moving to iPad")
        let renamed = try await store.history()
        XCTAssertEqual(renamed.first?.name, "Moving to iPad")
        try FileManager.default.removeItem(at: root.appendingPathComponent("Recovery/History.json"))
        let discovered = try await store.history()
        XCTAssertEqual(discovered.first?.name, "Recovered local backup")
        let backup = await store.url(for: item)
        _ = try await store.inspect(backup, password: passphrase)
        try await store.delete(discovered[0])
        let remaining = try await store.history()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

}
