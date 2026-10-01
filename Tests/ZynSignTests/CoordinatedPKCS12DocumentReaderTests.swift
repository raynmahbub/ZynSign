import Foundation
import XCTest
@testable import ZynSign

final class CoordinatedPKCS12DocumentReaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZynSignPKCS12Reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    func testReadsCoordinatedP12AndPfxFilesCaseInsensitively() throws {
        let payload = Data("synthetic PKCS#12 bytes".utf8)
        let p12 = directory.appendingPathComponent("Identity.P12")
        let pfx = directory.appendingPathComponent("Identity.PfX")
        try payload.write(to: p12)
        try payload.write(to: pfx)

        let reader = CoordinatedPKCS12DocumentReader()
        XCTAssertEqual(try reader.readPKCS12(at: p12), payload)
        XCTAssertEqual(try reader.readPKCS12(at: pfx), payload)
    }

    func testRejectsUnsupportedExtensionsBeforeReading() {
        let url = directory.appendingPathComponent("Identity.pem")
        let reader = CoordinatedPKCS12DocumentReader()

        XCTAssertThrowsError(try reader.readPKCS12(at: url)) { error in
            XCTAssertEqual(error as? PKCS12DocumentReadError, .unsupportedFileType)
        }
    }

    func testRejectsEmptyFiles() throws {
        let url = directory.appendingPathComponent("Empty.p12")
        try Data().write(to: url)

        XCTAssertThrowsError(try CoordinatedPKCS12DocumentReader().readPKCS12(at: url)) { error in
            XCTAssertEqual(error as? PKCS12DocumentReadError, .emptyFile)
        }
    }

    func testEnforcesTheConfiguredSizeBoundWhileStreamingChunks() throws {
        let accepted = directory.appendingPathComponent("Accepted.p12")
        let oversized = directory.appendingPathComponent("Oversized.pfx")
        try Data("12345678".utf8).write(to: accepted)
        try Data("123456789".utf8).write(to: oversized)
        let reader = CoordinatedPKCS12DocumentReader(maximumByteCount: 8, chunkSize: 3)

        XCTAssertEqual(try reader.readPKCS12(at: accepted), Data("12345678".utf8))
        XCTAssertThrowsError(try reader.readPKCS12(at: oversized)) { error in
            XCTAssertEqual(error as? PKCS12DocumentReadError, .fileTooLarge)
        }
    }

    func testRejectsDirectoriesAndNonFileURLs() throws {
        let directoryNamedP12 = directory.appendingPathComponent("NotAFile.p12", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryNamedP12, withIntermediateDirectories: true)
        let reader = CoordinatedPKCS12DocumentReader()

        XCTAssertThrowsError(try reader.readPKCS12(at: directoryNamedP12)) { error in
            XCTAssertEqual(error as? PKCS12DocumentReadError, .unreadable)
        }
        let remoteURL = try XCTUnwrap(URL(string: "https://example.invalid/Identity.p12"))
        XCTAssertThrowsError(try reader.readPKCS12(at: remoteURL)) { error in
            XCTAssertEqual(error as? PKCS12DocumentReadError, .unreadable)
        }
    }
}
