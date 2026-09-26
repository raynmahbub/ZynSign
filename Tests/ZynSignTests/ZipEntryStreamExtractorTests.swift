import XCTest
@testable import ZynSign

/// Tests for extracting one package out of a ZIP archive: exact bytes for
/// stored and compressed entries, and refusal — before or while writing —
/// of everything that would make extraction unsafe.
///
/// Archives are generated in memory by the fixture builder; hostile variants
/// are made by patching fields of the central directory the extractor
/// trusts, exactly as a crafted archive would.
final class ZipEntryStreamExtractorTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZynSignExtractorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private static let packageBytes: [UInt8] = Array(ImportHubFixtures.package())
    private static let pattern: [UInt8] = (0..<20_000).map { UInt8(truncatingIfNeeded: $0 % 251) }

    private func write(_ archive: [UInt8]) -> URL {
        ImportFixtures.writeFile(named: "Archive.zip", content: Data(archive), in: directory)
    }

    private var destination: URL {
        directory.appendingPathComponent("out.ipa")
    }

    private func extract(
        _ entry: String,
        from archive: [UInt8],
        chunkSize: Int = 1_048_576
    ) throws -> Data {
        let extractor = ZipEntryStreamExtractor(archive: write(archive), chunkSize: chunkSize)
        try extractor.extract(makePath(entry), to: destination, reporting: nil)
        return try Data(contentsOf: destination)
    }

    private func refusal(_ entry: String, from archive: [UInt8]) -> ZynSignError? {
        do {
            _ = try extract(entry, from: archive)
            XCTFail("Expected the extraction of \(entry) to be refused.")
            return nil
        } catch let error as ZynSignError {
            return error
        } catch {
            XCTFail("Unexpected error \(error)")
            return nil
        }
    }

    /// Overwrites a little-endian field of the central directory record for
    /// `name`.
    private func patchCentralDirectory(
        _ archive: [UInt8],
        entry name: String,
        fieldOffset: Int,
        value: UInt32,
        width: Int
    ) -> [UInt8] {
        var bytes = archive
        let nameBytes = Array(name.utf8)
        var index = 0
        while index + 46 <= bytes.count {
            if bytes[index] == 0x50, bytes[index + 1] == 0x4B, bytes[index + 2] == 0x01, bytes[index + 3] == 0x02 {
                let nameLength = Int(bytes[index + 28]) | (Int(bytes[index + 29]) << 8)
                if index + 46 + nameLength <= bytes.count,
                   Array(bytes[(index + 46)..<(index + 46 + nameLength)]) == nameBytes {
                    for byte in 0..<width {
                        bytes[index + fieldOffset + byte] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(byte)))
                    }
                    return bytes
                }
            }
            index += 1
        }
        XCTFail("No central directory record for \(name).")
        return bytes
    }

    // MARK: - Exact extraction

    func testAStoredEntryIsExtractedByteForByte() throws {
        let archive = ZipFixtureBuilder.archive([
            ZipFixtureBuilder.Entry(name: "Other.txt", content: [0x01, 0x02]),
            ZipFixtureBuilder.Entry(name: "Apps/App.ipa", content: Self.packageBytes),
        ])
        XCTAssertEqual(try extract("Apps/App.ipa", from: archive), Data(Self.packageBytes))
    }

    func testACompressedEntryIsExtractedByteForByteInSmallChunks() throws {
        let archive = ZipFixtureBuilder.archive([
            ZipFixtureBuilder.Entry(name: "App.ipa", content: Self.pattern, deflate: true),
        ])
        XCTAssertEqual(try extract("App.ipa", from: archive, chunkSize: 97), Data(Self.pattern))
    }

    func testOnlyTheRequestedEntryIsWritten() throws {
        let archive = ZipFixtureBuilder.archive([
            ZipFixtureBuilder.Entry(name: "One.ipa", content: [0x01]),
            ZipFixtureBuilder.Entry(name: "Two.ipa", content: [0x02, 0x02]),
        ])
        _ = try extract("Two.ipa", from: archive)
        XCTAssertEqual(ImportFixtures.fileNames(in: directory), ["Archive.zip", "out.ipa"])
    }

    func testExtractionReportsProgressUpToTheDeclaredSize() throws {
        final class Recorder: ImportProgressReporting, @unchecked Sendable {
            var reports: [ImportProgress] = []
            func report(_ progress: ImportProgress) { reports.append(progress) }
        }
        let recorder = Recorder()
        let archive = ZipFixtureBuilder.archive([
            ZipFixtureBuilder.Entry(name: "App.ipa", content: Self.pattern, deflate: true),
        ])
        let extractor = ZipEntryStreamExtractor(archive: write(archive), chunkSize: 1_000)
        try extractor.extract(makePath("App.ipa"), to: destination, reporting: recorder)

        XCTAssertTrue(recorder.reports.allSatisfy { $0.stage == .copying })
        XCTAssertEqual(recorder.reports.last?.completedUnitCount, Self.pattern.count)
        XCTAssertEqual(recorder.reports.last?.totalUnitCount, Self.pattern.count)
        let completed = recorder.reports.map(\.completedUnitCount)
        XCTAssertEqual(completed, completed.sorted())
    }

    // MARK: - Refusals

    func testAMissingEntryIsRefused() {
        let archive = ZipFixtureBuilder.archive([ZipFixtureBuilder.Entry(name: "One.ipa", content: [0x01])])
        XCTAssertEqual(refusal("Missing.ipa", from: archive)?.category, .invalidInput)
    }

    func testADuplicatedEntryIsRefused() {
        let archive = ZipFixtureBuilder.archive([
            ZipFixtureBuilder.Entry(name: "App.ipa", content: [0x01]),
            ZipFixtureBuilder.Entry(name: "App.ipa", content: [0x02]),
        ])
        XCTAssertEqual(refusal("App.ipa", from: archive)?.userMessage, ZynSignError.unsafeArchiveEntry().userMessage)
    }

    func testALinkIsRefusedEvenWithAPackageName() {
        let archive = ZipFixtureBuilder.archive([
            .symbolicLink("App.ipa", target: "/etc/passwd"),
        ])
        XCTAssertEqual(refusal("App.ipa", from: archive)?.userMessage, ZynSignError.unsafeArchiveEntry().userMessage)
    }

    func testADirectoryIsRefused() {
        let archive = ZipFixtureBuilder.archive([.directory("Folder.ipa")])
        XCTAssertNotNil(refusal("Folder.ipa", from: archive))
    }

    func testAnEncryptedEntryIsRefused() {
        let archive = patchCentralDirectory(
            ZipFixtureBuilder.archive([ZipFixtureBuilder.Entry(name: "App.ipa", content: [0x01, 0x02, 0x03])]),
            entry: "App.ipa",
            fieldOffset: 8,
            value: 0x0001,
            width: 2
        )
        XCTAssertEqual(refusal("App.ipa", from: archive)?.category, .unsupportedInput)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "Nothing is written for a refused entry.")
    }

    func testAChecksumMismatchIsRefused() {
        let archive = patchCentralDirectory(
            ZipFixtureBuilder.archive([ZipFixtureBuilder.Entry(name: "App.ipa", content: Self.pattern, deflate: true)]),
            entry: "App.ipa",
            fieldOffset: 16,
            value: 0xDEAD_BEEF,
            width: 4
        )
        XCTAssertEqual(refusal("App.ipa", from: archive)?.category, .invalidInput)
    }

    func testContentBeyondTheDeclaredSizeIsRefused() {
        let archive = patchCentralDirectory(
            ZipFixtureBuilder.archive([ZipFixtureBuilder.Entry(name: "App.ipa", content: Self.pattern, deflate: true)]),
            entry: "App.ipa",
            fieldOffset: 24,
            value: 1_000,
            width: 4
        )
        XCTAssertEqual(
            refusal("App.ipa", from: archive)?.userMessage,
            ZynSignError.archiveResourceLimitExceeded().userMessage
        )
    }

    func testAnImplausibleCompressionRatioIsRefusedBeforeWriting() {
        let archive = patchCentralDirectory(
            ZipFixtureBuilder.archive([ZipFixtureBuilder.Entry(name: "App.ipa", content: Array(repeating: 0, count: 64), deflate: true)]),
            entry: "App.ipa",
            fieldOffset: 24,
            value: 900_000_000,
            width: 4
        )
        XCTAssertEqual(
            refusal("App.ipa", from: archive)?.userMessage,
            ZynSignError.archiveResourceLimitExceeded().userMessage
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testAStoredEntryDeclaringTwoSizesIsRefused() {
        let archive = patchCentralDirectory(
            ZipFixtureBuilder.archive([ZipFixtureBuilder.Entry(name: "App.ipa", content: [0x01, 0x02, 0x03, 0x04])]),
            entry: "App.ipa",
            fieldOffset: 24,
            value: 2,
            width: 4
        )
        XCTAssertNotNil(refusal("App.ipa", from: archive))
    }

    func testACancelledExtractionStops() async throws {
        let archive = write(ZipFixtureBuilder.archive([
            ZipFixtureBuilder.Entry(name: "App.ipa", content: Self.pattern),
        ]))
        let output = destination
        let task = Task.detached { () throws -> Void in
            withUnsafeCurrentTask { $0?.cancel() }
            try ZipEntryStreamExtractor(archive: archive, chunkSize: 100).extract(makePath("App.ipa"), to: output, reporting: nil)
        }
        do {
            try await task.value
            XCTFail("Expected the extraction to stop.")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.category, .cancelled)
        }
    }

    // MARK: - Checksum

    func testTheIncrementalChecksumMatchesTheKnownValue() {
        var checksum = ZipChecksum()
        checksum.update(Data("123456789".utf8))
        XCTAssertEqual(checksum.value, 0xCBF4_3926)

        var split = ZipChecksum()
        split.update(Data("1234".utf8))
        split.update(Data("56789".utf8))
        XCTAssertEqual(split.value, checksum.value)
    }
}
