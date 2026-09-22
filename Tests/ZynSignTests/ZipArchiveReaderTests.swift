import XCTest
@testable import ZynSign

/// Integration tests for the ZIP container reader.
///
/// Every container these tests read is built at run time by
/// `ZipFixtureBuilder`, written to a temporary directory that the test removes,
/// and contains only synthetic names and content. No real package, signing
/// material, profile, or certificate is involved, and no binary fixture is
/// committed to the repository.
final class ZipArchiveReaderTests: XCTestCase {

    private var temporaryDirectory: URL!
    private var openedReaders: [ZipArchiveReader] = []

    override func setUp() {
        super.setUp()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zynsign-archive-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        openedReaders.forEach { $0.close() }
        openedReaders = []
        try? FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func reader(for bytes: [UInt8], limits: ArchiveLimits = .default) throws -> ZipArchiveReader {
        let location = temporaryDirectory.appendingPathComponent("fixture.ipa", isDirectory: false)
        try Data(bytes).write(to: location)
        let reader = ZipArchiveReader(location: location, limits: limits)
        openedReaders.append(reader)
        return reader
    }

    private func reader(for entries: [ZipFixtureBuilder.Entry]) throws -> ZipArchiveReader {
        try reader(for: ZipFixtureBuilder.archive(entries))
    }

    private func thrownError(
        _ body: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ZynSignError {
        var captured: (any Error)?
        do {
            try body()
        } catch {
            captured = error
        }
        let error = try XCTUnwrap(captured, "Expected the operation to fail.", file: file, line: line)
        guard let zynSignError = error as? ZynSignError else {
            XCTFail("Expected a ZynSignError, got \(type(of: error))", file: file, line: line)
            throw error
        }
        return zynSignError
    }

    private func contentOffsetOfFirstEntry(in bytes: [UInt8]) -> Int {
        30 + (Int(bytes[26]) | (Int(bytes[27]) << 8)) + (Int(bytes[28]) | (Int(bytes[29]) << 8))
    }

    // MARK: - Valid containers

    func testReadsEntryTableFromValidContainer() throws {
        let reader = try reader(for: ZipFixtureBuilder.validPackage())
        let table = try reader.readEntryTable()

        XCTAssertEqual(
            table.compactMap(\.path).map(\.rawValue),
            [
                "Payload",
                "Payload/Example.app",
                "Payload/Example.app/Info.plist",
                "Payload/Example.app/Example",
            ]
        )
        XCTAssertTrue(table.allSatisfy(\.isSafelyNamed))
    }

    func testPreservesContainerEntryOrder() throws {
        let reader = try reader(for: ZipFixtureBuilder.validPackage())
        let table = try reader.readEntryTable()
        XCTAssertEqual(table.first?.path?.rawValue, "Payload")
        XCTAssertEqual(table.last?.path?.rawValue, "Payload/Example.app/Example")
    }

    func testReportsDirectoryAndFileKinds() throws {
        let reader = try reader(for: ZipFixtureBuilder.validPackage())
        XCTAssertEqual(try reader.entryKind(at: makePath("Payload")), .directory)
        XCTAssertEqual(try reader.entryKind(at: makePath("Payload/Example.app")), .directory)
        XCTAssertEqual(try reader.entryKind(at: makePath("Payload/Example.app/Info.plist")), .regularFile)
        XCTAssertNil(try reader.entryKind(at: makePath("Payload/Absent")))
    }

    func testContainsEntryReflectsTheContainer() throws {
        let reader = try reader(for: ZipFixtureBuilder.validPackage())
        XCTAssertTrue(try reader.containsEntry(at: makePath("Payload/Example.app/Info.plist")))
        XCTAssertFalse(try reader.containsEntry(at: makePath("Payload/Example.app/Absent")))
    }

    func testValidContainerPassesStructuralValidation() throws {
        let reader = try reader(for: ZipFixtureBuilder.validPackage())
        let inspection = IPAStructureValidator().validate(entryTable: try reader.readEntryTable())
        XCTAssertEqual(inspection.validation.classification, .valid)
        XCTAssertEqual(inspection.bundle?.bundlePath.rawValue, "Payload/Example.app")
    }

    func testReadsStoredEntryContent() throws {
        let reader = try reader(for: ZipFixtureBuilder.validPackage())
        let data = try reader.readEntryData(
            at: makePath("Payload/Example.app/Info.plist"),
            maximumBytes: 4_096
        )
        XCTAssertEqual(Array(data), ZipFixtureBuilder.syntheticPlist)
    }

    func testReadsDeflatedEntryContent() throws {
        let reader = try reader(for: ZipFixtureBuilder.validPackage())
        let data = try reader.readEntryData(
            at: makePath("Payload/Example.app/Example"),
            maximumBytes: 4_096
        )
        XCTAssertEqual(Array(data), Array(repeating: 0x90, count: 64))
    }

    // MARK: - Unreadable containers

    func testRejectsInputThatIsNotAContainer() throws {
        let reader = try reader(for: ZipFixtureBuilder.notAnArchive())
        let error = try thrownError { _ = try reader.readEntryTable() }
        XCTAssertEqual(error.category, .invalidInput)
        XCTAssertTrue(error.diagnosticDetail?.contains("end-of-central-directory") ?? false)
    }

    func testRejectsContainerWithDamagedCentralDirectory() throws {
        let reader = try reader(
            for: ZipFixtureBuilder.corruptCentralDirectory(ZipFixtureBuilder.validPackage())
        )
        let error = try thrownError { _ = try reader.readEntryTable() }
        XCTAssertEqual(error.category, .invalidInput)
    }

    func testRejectsTruncatedContainer() throws {
        let reader = try reader(
            for: ZipFixtureBuilder.truncated(ZipFixtureBuilder.validPackage())
        )
        let error = try thrownError { _ = try reader.readEntryTable() }
        XCTAssertEqual(error.category, .invalidInput)
    }

    func testRejectsAbsentContainer() throws {
        let location = temporaryDirectory.appendingPathComponent("absent.ipa", isDirectory: false)
        let reader = ZipArchiveReader(location: location)
        openedReaders.append(reader)
        let error = try thrownError { _ = try reader.readEntryTable() }
        XCTAssertEqual(error.category, .invalidInput)
    }

    // MARK: - Unsafe entry names

    func testReportsEscapingEntryNameAsUnsafe() throws {
        let reader = try reader(for: ZipFixtureBuilder.validPackage() + [
            ZipFixtureBuilder.Entry(name: "Payload/Example.app/../../../etc/passwd", content: [0x00]),
        ])
        let table = try reader.readEntryTable()
        let unsafe = table.filter { !$0.isSafelyNamed }
        XCTAssertEqual(unsafe.count, 1)
        let inspection = IPAStructureValidator().validate(entryTable: table)
        XCTAssertTrue(inspection.validation.errors.contains { $0.code == .unsafePath })
    }

    func testReportsAbsoluteEntryNameAsUnsafe() throws {
        let reader = try reader(for: [
            ZipFixtureBuilder.Entry(name: "/etc/passwd", content: [0x00]),
        ])
        let table = try reader.readEntryTable()
        XCTAssertFalse(table.first?.isSafelyNamed ?? true)
    }

    func testReportsBackslashEntryNameAsUnsafe() throws {
        let reader = try reader(for: [
            ZipFixtureBuilder.Entry(name: "Payload\\Example.app\\Info.plist", content: [0x00]),
        ])
        let table = try reader.readEntryTable()
        XCTAssertFalse(table.first?.isSafelyNamed ?? true)
    }

    func testReportsOverlongEntryNameAsUnsafe() throws {
        let longName = "Payload/" + String(repeating: "a", count: 200) + ".app/Info.plist"
        let limits = ArchiveLimits(
            maximumEntryCount: 100,
            maximumEntryNameLength: 64,
            maximumPathDepth: 32,
            maximumEntryBytes: 1_024,
            maximumTotalUncompressedBytes: 4_096,
            maximumCompressionRatio: 100,
            maximumInspectionReadBytes: 1_024
        )
        let reader = try reader(
            for: [ZipFixtureBuilder.Entry(name: longName, content: [0x00])],
            limits: limits
        )
        let table = try reader.readEntryTable()
        XCTAssertFalse(table.first?.isSafelyNamed ?? true)
    }

    func testReportsUndecodableEntryNameAsUnsafe() throws {
        let reader = try reader(for: [ZipFixtureBuilder.Entry.undecodableName(content: [0x00])])
        let table = try reader.readEntryTable()
        XCTAssertEqual(table.count, 1)
        XCTAssertFalse(table.first?.isSafelyNamed ?? true)
    }

    // MARK: - Entry kinds and collisions

    func testReportsSymbolicLinkEntry() throws {
        let reader = try reader(for: ZipFixtureBuilder.validPackage() + [
            ZipFixtureBuilder.Entry.symbolicLink("Payload/Example.app/Link", target: "../../../etc"),
        ])
        let table = try reader.readEntryTable()
        let link = table.first { $0.path?.rawValue == "Payload/Example.app/Link" }
        XCTAssertEqual(link?.kind, .symbolicLink)
    }

    func testReportsDuplicateEntryNames() throws {
        let reader = try reader(for: ZipFixtureBuilder.validPackage() + [
            ZipFixtureBuilder.Entry(name: "Payload/Example.app/Info.plist", content: [0x00]),
        ])
        let table = try reader.readEntryTable()
        let duplicates = table.filter { $0.path?.rawValue == "Payload/Example.app/Info.plist" }
        XCTAssertEqual(duplicates.count, 2)
        let inspection = IPAStructureValidator().validate(entryTable: table)
        XCTAssertTrue(inspection.validation.errors.contains { $0.code == .conflictingPaths })
    }

    // MARK: - Resource policy

    func testStopsScanningOnceTheEntryCountPolicyIsExceeded() throws {
        let limits = ArchiveLimits(
            maximumEntryCount: 3,
            maximumEntryNameLength: 256,
            maximumPathDepth: 32,
            maximumEntryBytes: 4_096,
            maximumTotalUncompressedBytes: 65_536,
            maximumCompressionRatio: 100,
            maximumInspectionReadBytes: 4_096
        )
        let entries = (0..<40).map { index in
            ZipFixtureBuilder.Entry(name: "entry-\(index)", content: [0x00])
        }
        let reader = try reader(for: entries, limits: limits)
        let table = try reader.readEntryTable()
        XCTAssertEqual(table.count, limits.maximumEntryCount + 1)
    }

    // MARK: - Bounded reads

    func testRefusesReadBeyondTheRequestedBound() throws {
        let reader = try reader(for: ZipFixtureBuilder.validPackage())
        let error = try thrownError {
            _ = try reader.readEntryData(at: makePath("Payload/Example.app/Info.plist"), maximumBytes: 4)
        }
        XCTAssertEqual(error.category, .invalidInput)
    }

    func testRefusesReadBeyondThePolicyBound() throws {
        let limits = ArchiveLimits(
            maximumEntryCount: 100,
            maximumEntryNameLength: 256,
            maximumPathDepth: 32,
            maximumEntryBytes: 65_536,
            maximumTotalUncompressedBytes: 65_536,
            maximumCompressionRatio: 1_000,
            maximumInspectionReadBytes: 16
        )
        let reader = try reader(for: ZipFixtureBuilder.validPackage(), limits: limits)
        let error = try thrownError {
            _ = try reader.readEntryData(
                at: makePath("Payload/Example.app/Info.plist"),
                maximumBytes: 1_000_000
            )
        }
        XCTAssertEqual(error.category, .invalidInput)
    }

    func testRefusesReadOfAbsentEntry() throws {
        let reader = try reader(for: ZipFixtureBuilder.validPackage())
        let error = try thrownError {
            _ = try reader.readEntryData(at: makePath("Payload/Example.app/Absent"), maximumBytes: 64)
        }
        XCTAssertEqual(error.category, .invalidInput)
    }

    func testRejectsEntryWhoseStoredContentIsDamaged() throws {
        var bytes = ZipFixtureBuilder.archive([
            ZipFixtureBuilder.Entry(name: "Payload/Example.app/Info.plist", content: Array(repeating: 0x41, count: 32)),
        ])
        bytes[contentOffsetOfFirstEntry(in: bytes)] ^= 0xFF
        let reader = try reader(for: bytes)
        let error = try thrownError {
            _ = try reader.readEntryData(at: makePath("Payload/Example.app/Info.plist"), maximumBytes: 4_096)
        }
        XCTAssertEqual(error.category, .invalidInput)
        XCTAssertTrue(error.diagnosticDetail?.contains("checksum") ?? false)
    }

    // MARK: - Lifecycle

    func testCloseIsIdempotentAndPreventsFurtherUse() throws {
        let reader = try reader(for: ZipFixtureBuilder.validPackage())
        _ = try reader.readEntryTable()
        reader.close()
        reader.close()
        let error = try thrownError { _ = try reader.readEntryTable() }
        XCTAssertEqual(error.category, .storageFailure)
    }
}
