import Foundation
import XCTest
@testable import ZynSign

/// Tests for deterministic archive writing.
///
/// Golden vectors are embedded as base64. They were produced independently
/// with Python's `struct`/`zlib` modules — not by the writer under test —
/// and cross-checked with both Python's `zipfile` module and Info-ZIP's
/// `unzip -t` before being committed here. Round-trip tests write with the
/// production writer and read back through the production reader.
final class ZipArchiveWriterTests: XCTestCase {

    private var temporaryDirectory: URL!
    private var openedReaders: [ZipArchiveReader] = []

    override func setUp() {
        super.setUp()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zynsign-writer-tests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Golden vectors

    func testEmptyArchiveMatchesGoldenVector() throws {
        let expected = try golden("UEsFBgAAAAAAAAAAAAAAAAAAAAAAAA==")
        let output = try ZipArchiveWriter().serializedArchive(entries: [])
        XCTAssertEqual(output, expected)
        XCTAssertEqual(output.count, 22)
    }

    func testSingleFileMatchesGoldenVector() throws {
        let expected = try golden("UEsDBBQAAAgAAAAAIQAHTGkwAgAAAAIAAAAFAAAAYS50eHRBQlBLAQItAxQAAAgAAAAAIQAHTGkwAgAAAAIAAAAFAAAAAAAAAAAAAACkgQAAAABhLnR4dFBLBQYAAAAAAQABADMAAAAlAAAAAAA=")
        let entry = try writeEntry(path: "a.txt", kind: .regularFile(isExecutable: false), content: Data("AB".utf8))
        let output = try ZipArchiveWriter().serializedArchive(entries: [entry])
        XCTAssertEqual(output, expected)
        XCTAssertEqual(output.count, 110)
    }

    func testMixedEntriesMatchGoldenVector() throws {
        // Entries are supplied out of order: the vector proves sorting and
        // implied-directory insertion, not just serialization.
        let expected = try golden(mixedGoldenBase64)
        let entries = try [
            writeEntry(path: "Payload/App.app/Link", kind: .symbolicLink, content: Data("App".utf8)),
            writeEntry(path: "Payload/App.app/App", kind: .regularFile(isExecutable: true), content: Data([1, 2, 3, 4])),
            writeEntry(path: "Payload/App.app/Info.plist", kind: .regularFile(isExecutable: false), content: Data("<plist/>".utf8)),
        ]
        let output = try ZipArchiveWriter().serializedArchive(entries: entries)
        XCTAssertEqual(output, expected)
        XCTAssertEqual(output.count, 595)
    }

    func testWritingIsDeterministic() throws {
        let entries = try mixedEntries()
        let first = try ZipArchiveWriter().serializedArchive(entries: entries)
        let second = try ZipArchiveWriter().serializedArchive(entries: entries.reversed())
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, try golden(mixedGoldenBase64))
    }

    func testPlanOrdersEntriesByAscendingNameBytes() throws {
        let plan = try ArchiveWritePlan.plan(entries: mixedEntries())
        XCTAssertEqual(
            plan.entries.map { ArchiveWritePlan.recordedName(for: $0) },
            ["Payload/", "Payload/App.app/", "Payload/App.app/App", "Payload/App.app/Info.plist", "Payload/App.app/Link"]
        )
    }

    // MARK: - Plan refusals

    func testPlanRefusesDuplicatePaths() throws {
        let first = try writeEntry(path: "a.txt", kind: .regularFile(isExecutable: false))
        let second = try writeEntry(path: "a.txt", kind: .regularFile(isExecutable: true))
        XCTAssertThrowsError(try ArchiveWritePlan.plan(entries: [first, second]))
    }

    func testPlanRefusesFileDirectoryConflict() throws {
        let file = try writeEntry(path: "a", kind: .regularFile(isExecutable: false))
        let nested = try writeEntry(path: "a/b.txt", kind: .regularFile(isExecutable: false))
        XCTAssertThrowsError(try ArchiveWritePlan.plan(entries: [file, nested]))
    }

    func testPlanRefusesDirectoryWithContent() throws {
        let directory = try writeEntry(path: "a", kind: .directory, content: Data([1]))
        XCTAssertThrowsError(try ArchiveWritePlan.plan(entries: [directory]))
    }

    func testPlanRefusesAbsoluteLinkTarget() throws {
        let link = try writeEntry(path: "a/link", kind: .symbolicLink, content: Data("/etc/passwd".utf8))
        XCTAssertThrowsError(try ArchiveWritePlan.plan(entries: [link]))
    }

    func testPlanRefusesEscapingLinkTarget() throws {
        let link = try writeEntry(path: "a/link", kind: .symbolicLink, content: Data("../../escape".utf8))
        XCTAssertThrowsError(try ArchiveWritePlan.plan(entries: [link]))
    }

    func testPlanRefusesEmptyLinkTarget() throws {
        let link = try writeEntry(path: "a/link", kind: .symbolicLink, content: Data())
        XCTAssertThrowsError(try ArchiveWritePlan.plan(entries: [link]))
    }

    func testPlanRefusesNonTextLinkTarget() throws {
        let link = try writeEntry(path: "a/link", kind: .symbolicLink, content: Data([0xFF, 0xFE]))
        XCTAssertThrowsError(try ArchiveWritePlan.plan(entries: [link]))
    }

    func testPlanAllowsContainedClimbingLinkTarget() throws {
        // The link sits two directories deep, so climbing twice stays inside.
        let link = try writeEntry(
            path: "a/b/link",
            kind: .symbolicLink,
            content: Data("../../c.txt".utf8)
        )
        let file = try writeEntry(path: "c.txt", kind: .regularFile(isExecutable: false))
        let plan = try ArchiveWritePlan.plan(entries: [link, file])
        XCTAssertEqual(plan.entries.count, 4)
    }

    func testPlanRefusesEntrySetBeyondPolicy() throws {
        let entry = try writeEntry(path: "a.txt", kind: .regularFile(isExecutable: false), content: Data([1, 2, 3, 4]))
        let tiny = ArchiveWritePolicy(maximumEntryCount: 100, maximumNameBytes: 100, maximumTotalBytes: 2)
        XCTAssertThrowsError(try ArchiveWritePlan.plan(entries: [entry], policy: tiny))
        let single = ArchiveWritePolicy(maximumEntryCount: 1, maximumNameBytes: 100, maximumTotalBytes: 100)
        XCTAssertThrowsError(try ArchiveWritePlan.plan(entries: [entry, entry], policy: single))
    }

    // MARK: - Reader round trip

    func testWrittenArchiveReadsBackThroughTheReader() throws {
        let output = try ZipArchiveWriter().serializedArchive(entries: mixedEntries())
        let reader = try reader(for: output)
        let table = try reader.readEntryTable()
        XCTAssertEqual(table.map { $0.rawName }, [
            "Payload/",
            "Payload/App.app/",
            "Payload/App.app/App",
            "Payload/App.app/Info.plist",
            "Payload/App.app/Link",
        ])
        XCTAssertEqual(table.map { $0.kind }, [
            .directory,
            .directory,
            .regularFile,
            .regularFile,
            .symbolicLink,
        ])
        XCTAssertTrue(table.allSatisfy { $0.isSafelyNamed })
        let plistPath = try XCTUnwrap(ArchivePath(rawValue: "Payload/App.app/Info.plist"))
        XCTAssertEqual(
            try reader.readEntryData(at: plistPath, maximumBytes: 1_000_000),
            Data("<plist/>".utf8)
        )
        let linkPath = try XCTUnwrap(ArchivePath(rawValue: "Payload/App.app/Link"))
        XCTAssertEqual(
            try reader.readEntryData(at: linkPath, maximumBytes: 1_000_000),
            Data("App".utf8)
        )
    }

    func testTamperedContentFailsReaderChecksum() throws {
        var output = try ZipArchiveWriter().serializedArchive(entries: mixedEntries())
        let needle = Data("<plist/>".utf8)
        guard let range = output.range(of: needle) else {
            return XCTFail("Expected the fixture content to appear in the output.")
        }
        output[range.lowerBound] = 0x58
        let reader = try reader(for: output)
        let plistPath = try XCTUnwrap(ArchivePath(rawValue: "Payload/App.app/Info.plist"))
        XCTAssertThrowsError(try reader.readEntryData(at: plistPath, maximumBytes: 1_000_000)) { error in
            XCTAssertEqual((error as? ZynSignError)?.category, .invalidInput)
        }
    }

    // MARK: - Sink behavior

    func testSinkReceivesIncrementalChunks() throws {
        var chunks: [Data] = []
        try ZipArchiveWriter().writeArchive(entries: mixedEntries(), policy: .default) { chunk in
            chunks.append(chunk)
        }
        XCTAssertGreaterThan(chunks.count, 1)
        let concatenated = chunks.reduce(Data(), +)
        XCTAssertEqual(concatenated, try ZipArchiveWriter().serializedArchive(entries: mixedEntries()))
    }

    func testThrowingSinkPropagatesItsError() throws {
        struct SinkError: Error {}
        XCTAssertThrowsError(
            try ZipArchiveWriter().writeArchive(entries: mixedEntries(), policy: .default) { _ in
                throw SinkError()
            }
        ) { error in
            XCTAssertTrue(error is SinkError)
        }
    }

    // MARK: - Helpers

    private func writeEntry(
        path: String,
        kind: ArchiveWriteEntryKind,
        content: Data = Data()
    ) throws -> ArchiveWriteEntry {
        let archivePath = try XCTUnwrap(ArchivePath(rawValue: path))
        return ArchiveWriteEntry(path: archivePath, kind: kind, content: content)
    }

    private func mixedEntries() throws -> [ArchiveWriteEntry] {
        try [
            writeEntry(path: "Payload/App.app/Link", kind: .symbolicLink, content: Data("App".utf8)),
            writeEntry(path: "Payload/App.app/App", kind: .regularFile(isExecutable: true), content: Data([1, 2, 3, 4])),
            writeEntry(path: "Payload/App.app/Info.plist", kind: .regularFile(isExecutable: false), content: Data("<plist/>".utf8)),
        ]
    }

    private func golden(_ base64: String) throws -> Data {
        try XCTUnwrap(Data(base64Encoded: base64))
    }

    private func reader(for bytes: Data) throws -> ZipArchiveReader {
        let location = temporaryDirectory.appendingPathComponent("written.ipa", isDirectory: false)
        try bytes.write(to: location)
        let reader = ZipArchiveReader(location: location)
        openedReaders.append(reader)
        return reader
    }

    private let mixedGoldenBase64 = "UEsDBBQAAAgAAAAAIQAAAAAAAAAAAAAAAAAIAAAAUGF5bG9hZC9QSwMEFAAACAAAAAAhAAAAAAAAAAAAAAAAABAAAABQYXlsb2FkL0FwcC5hcHAvUEsDBBQAAAgAAAAAIQDN+zy2BAAAAAQAAAATAAAAUGF5bG9hZC9BcHAuYXBwL0FwcAECAwRQSwMEFAAACAAAAAAhAFV5M0kIAAAACAAAABoAAABQYXlsb2FkL0FwcC5hcHAvSW5mby5wbGlzdDxwbGlzdC8+UEsDBBQAAAgAAAAAIQAvNiPxAwAAAAMAAAAUAAAAUGF5bG9hZC9BcHAuYXBwL0xpbmtBcHBQSwECLQMUAAAIAAAAACEAAAAAAAAAAAAAAAAACAAAAAAAAAAAAAAA7UEAAAAAUGF5bG9hZC9QSwECLQMUAAAIAAAAACEAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAA7UEmAAAAUGF5bG9hZC9BcHAuYXBwL1BLAQItAxQAAAgAAAAAIQDN+zy2BAAAAAQAAAATAAAAAAAAAAAAAADtgVQAAABQYXlsb2FkL0FwcC5hcHAvQXBwUEsBAi0DFAAACAAAAAAhAFV5M0kIAAAACAAAABoAAAAAAAAAAAAAAKSBiQAAAFBheWxvYWQvQXBwLmFwcC9JbmZvLnBsaXN0UEsBAi0DFAAACAAAAAAhAC82I/EDAAAAAwAAABQAAAAAAAAAAAAAAP+hyQAAAFBheWxvYWQvQXBwLmFwcC9MaW5rUEsFBgAAAAAFAAUAPwEAAP4AAAAAAA=="
}
