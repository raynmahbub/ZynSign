import Foundation
import XCTest
@testable import ZynSign

/// Tests for safe archive extraction.
///
/// Every container these tests extract is built at run time by
/// `ZipFixtureBuilder` with synthetic names and content, and every
/// extraction lands in a temporary directory the test removes. No real
/// package is involved.
final class DirectoryArchiveExtractorTests: XCTestCase {

    private var temporaryDirectory: URL!
    private var openedReaders: [ZipArchiveReader] = []

    override func setUp() {
        super.setUp()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zynsign-extractor-tests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Success paths

    func testExtractsFilesAndDirectories() async throws {
        let reader = try reader(for: [
            .directory("Payload"),
            .directory("Payload/App.app"),
            ZipFixtureBuilder.Entry(name: "Payload/App.app/Info.plist", content: Array("plist".utf8)),
            ZipFixtureBuilder.Entry(name: "Payload/App.app/nested/deep.txt", content: Array("deep".utf8)),
        ])
        let destination = try destinationDirectory()
        let report = try await DirectoryArchiveExtractor(destination: destination).extract(reader: reader)

        XCTAssertEqual(report.fileCount, 2)
        XCTAssertEqual(report.symbolicLinkCount, 0)
        XCTAssertEqual(report.extractedBytes, 9)
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("Payload/App.app/Info.plist")),
            Data("plist".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("Payload/App.app/nested/deep.txt")),
            Data("deep".utf8)
        )
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("Payload/App.app/nested").path,
            isDirectory: &isDirectory
        ))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testRestoresExecutablePermissionsFromRecordedMode() async throws {
        let reader = try reader(for: [
            ZipFixtureBuilder.Entry(name: "Payload/App", content: Array("exec".utf8), unixMode: 0o100_755),
            ZipFixtureBuilder.Entry(name: "Payload/Info.plist", content: Array("plain".utf8), unixMode: 0o100_644),
        ])
        let destination = try destinationDirectory()
        _ = try await DirectoryArchiveExtractor(destination: destination).extract(reader: reader)

        let executable = try permissions(of: destination.appendingPathComponent("Payload/App"))
        XCTAssertNotEqual(executable & 0o111, 0)
        let plain = try permissions(of: destination.appendingPathComponent("Payload/Info.plist"))
        XCTAssertEqual(plain & 0o111, 0)
    }

    func testRecreatesContainedLinksUnderPolicy() async throws {
        let reader = try reader(for: [
            .directory("Payload"),
            ZipFixtureBuilder.Entry(name: "Payload/target.txt", content: Array("target".utf8)),
            ZipFixtureBuilder.Entry.symbolicLink("Payload/link", target: "target.txt"),
        ])
        let destination = try destinationDirectory()
        let policy = ArchiveExtractionPolicy(
            maximumExtractedBytes: 1_000_000,
            maximumLinkTargetBytes: 4_096,
            symlinkPolicy: .recreateWithinRoot
        )
        let report = try await DirectoryArchiveExtractor(destination: destination, policy: policy)
            .extract(reader: reader)

        XCTAssertEqual(report.symbolicLinkCount, 1)
        let linkURL = destination.appendingPathComponent("Payload/link")
        let values = try linkURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertEqual(values.isSymbolicLink, true)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path), "target.txt")
    }

    // MARK: - Refusals

    func testRefusesUnsafeEntryNames() async throws {
        let reader = try reader(for: [
            ZipFixtureBuilder.Entry(name: "Payload/../../evil.txt", content: Array("evil".utf8)),
        ])
        let destination = try destinationDirectory()
        await assertThrowsCategory(.invalidInput) {
            try await DirectoryArchiveExtractor(destination: destination).extract(reader: reader)
        }
    }

    func testRefusesDuplicateLocations() async throws {
        let reader = try reader(for: [
            ZipFixtureBuilder.Entry(name: "Payload/a.txt", content: Array("one".utf8)),
            ZipFixtureBuilder.Entry(name: "Payload/a.txt", content: Array("two".utf8)),
        ])
        let destination = try destinationDirectory()
        await assertThrowsCategory(.invalidInput) {
            try await DirectoryArchiveExtractor(destination: destination).extract(reader: reader)
        }
    }

    func testRefusesFileDirectoryConflict() async throws {
        let reader = try reader(for: [
            ZipFixtureBuilder.Entry(name: "Payload/a", content: Array("file".utf8)),
            ZipFixtureBuilder.Entry(name: "Payload/a/b.txt", content: Array("nested".utf8)),
        ])
        let destination = try destinationDirectory()
        await assertThrowsCategory(.invalidInput) {
            try await DirectoryArchiveExtractor(destination: destination).extract(reader: reader)
        }
    }

    func testRefusesSymbolicLinksByDefault() async throws {
        let reader = try reader(for: [
            .directory("Payload"),
            ZipFixtureBuilder.Entry(name: "Payload/target.txt", content: Array("target".utf8)),
            ZipFixtureBuilder.Entry.symbolicLink("Payload/link", target: "target.txt"),
        ])
        let destination = try destinationDirectory()
        await assertThrowsCategory(.invalidInput) {
            try await DirectoryArchiveExtractor(destination: destination).extract(reader: reader)
        }
    }

    func testRefusesAbsoluteLinkTarget() async throws {
        let reader = try reader(for: [
            .directory("Payload"),
            ZipFixtureBuilder.Entry.symbolicLink("Payload/link", target: "/etc/passwd"),
        ])
        let destination = try destinationDirectory()
        await assertThrowsExtracting(reader: reader, destination: destination)
    }

    func testRefusesEscapingLinkTarget() async throws {
        let reader = try reader(for: [
            .directory("Payload"),
            ZipFixtureBuilder.Entry.symbolicLink("Payload/link", target: "../../escape"),
        ])
        let destination = try destinationDirectory()
        await assertThrowsExtracting(reader: reader, destination: destination)
    }

    func testRefusesUnsupportedEntryKind() async throws {
        let reader = try reader(for: [
            ZipFixtureBuilder.Entry(name: "Payload/node", content: [], unixMode: 0o060_644),
        ])
        let destination = try destinationDirectory()
        do {
            _ = try await DirectoryArchiveExtractor(destination: destination).extract(reader: reader)
            XCTFail("Expected the unsupported entry kind to be refused.")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.category, .unsupportedInput)
        }
    }

    func testEnforcesExtractedBytesBound() async throws {
        let reader = try reader(for: [
            ZipFixtureBuilder.Entry(name: "Payload/a.txt", content: Array("12345678".utf8)),
        ])
        let destination = try destinationDirectory()
        let policy = ArchiveExtractionPolicy(
            maximumExtractedBytes: 4,
            maximumLinkTargetBytes: 4_096,
            symlinkPolicy: .refuse
        )
        do {
            _ = try await DirectoryArchiveExtractor(destination: destination, policy: policy)
                .extract(reader: reader)
            XCTFail("Expected the byte bound to be enforced.")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.category, .invalidInput)
        }
    }

    // MARK: - Helpers

    private func reader(for entries: [ZipFixtureBuilder.Entry]) throws -> ZipArchiveReader {
        let location = temporaryDirectory.appendingPathComponent("\(UUID().uuidString).ipa", isDirectory: false)
        try Data(ZipFixtureBuilder.archive(entries)).write(to: location)
        let reader = ZipArchiveReader(location: location)
        openedReaders.append(reader)
        return reader
    }

    private func destinationDirectory() throws -> URL {
        let url = temporaryDirectory.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue)
    }

    private func assertThrowsCategory(
        _ category: DiagnosticCategory,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () async throws -> ArchiveExtractionReport
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected the extraction to fail.", file: file, line: line)
        } catch let error as ZynSignError {
            XCTAssertEqual(error.category, category, file: file, line: line)
        } catch {
            XCTFail("Expected a ZynSignError, not \(error).", file: file, line: line)
        }
    }

    private func assertThrowsExtracting(reader: ZipArchiveReader, destination: URL) async {
        let policy = ArchiveExtractionPolicy(
            maximumExtractedBytes: 1_000_000,
            maximumLinkTargetBytes: 4_096,
            symlinkPolicy: .recreateWithinRoot
        )
        await assertThrowsCategory(.invalidInput) {
            try await DirectoryArchiveExtractor(destination: destination, policy: policy).extract(reader: reader)
        }
    }
}
