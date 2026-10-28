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

    /// A synthetic container body: a DER `SEQUENCE` header followed by bytes
    /// that are not a real certificate. The reader is not a parser; it
    /// recognises the binary container and hands it on.
    private func containerBody(_ trailer: String = "synthetic PKCS#12 body") -> Data {
        var payload = Data([0x30, 0x82, 0x00, 0x10])
        payload.append(Data(trailer.utf8))
        return payload
    }

    func testReadsCoordinatedP12AndPfxFilesCaseInsensitively() throws {
        let payload = containerBody()
        let p12 = directory.appendingPathComponent("Identity.P12")
        let pfx = directory.appendingPathComponent("Identity.PfX")
        try payload.write(to: p12)
        try payload.write(to: pfx)

        let reader = CoordinatedPKCS12DocumentReader()
        XCTAssertEqual(try reader.readPKCS12(at: p12), payload)
        XCTAssertEqual(try reader.readPKCS12(at: pfx), payload)
    }

    func testRefusesTextByItsContentWhateverItIsCalled() throws {
        // The name decides nothing: text is refused for what it holds, under
        // any name a person or another app gave it.
        let namedAsCertificate = directory.appendingPathComponent("Identity.p12")
        let foreignName = directory.appendingPathComponent("Identity.cer")
        let text = Data("this is a note, not a certificate".utf8)
        try text.write(to: namedAsCertificate)
        try text.write(to: foreignName)

        for url in [namedAsCertificate, foreignName] {
            XCTAssertThrowsError(try CoordinatedPKCS12DocumentReader().readPKCS12(at: url)) { error in
                XCTAssertEqual(error as? PKCS12DocumentReadError, .unsupportedFileType)
            }
        }
    }

    func testAMissingDocumentIsReportedAsUnreadable() {
        let missing = directory.appendingPathComponent("Gone.p12")

        XCTAssertThrowsError(try CoordinatedPKCS12DocumentReader().readPKCS12(at: missing)) { error in
            XCTAssertEqual(error as? PKCS12DocumentReadError, .unreadable)
        }
    }

    /// A certificate handed out as Base64 — bare, or between the familiar
    /// armor lines — reaches the password form as the container it is.
    func testUnwrapsAnEncodedContainer() throws {
        let payload = containerBody()
        let encoded = payload.base64EncodedString()
        let bare = directory.appendingPathComponent("Identity.p12")
        let armored = directory.appendingPathComponent("Identity.pfx")
        try Data(encoded.utf8).write(to: bare)
        try Data("-----BEGIN PKCS12-----\n\(encoded)\n-----END PKCS12-----\n".utf8).write(to: armored)

        let reader = CoordinatedPKCS12DocumentReader()
        XCTAssertEqual(try reader.readPKCS12(at: bare), payload)
        XCTAssertEqual(try reader.readPKCS12(at: armored), payload)
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
        var acceptedBytes = Data([0x30])
        acceptedBytes.append(Data("1234567".utf8))
        var oversizedBytes = Data([0x30])
        oversizedBytes.append(Data("12345678".utf8))
        try acceptedBytes.write(to: accepted)
        try oversizedBytes.write(to: oversized)
        let reader = CoordinatedPKCS12DocumentReader(maximumByteCount: 8, chunkSize: 3)

        XCTAssertEqual(try reader.readPKCS12(at: accepted), acceptedBytes)
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

    /// The reported defect: Files and AirDrop rename. A certificate whose
    /// bytes are intact must still be readable when its name says nothing —
    /// content, not the extension, is the authority.
    func testAcceptsADatalessNamedFileWhoseContentBeginsLikePKCS12() throws {
        var payload = Data([0x30, 0x82])          // a DER SEQUENCE header
        payload.append(Data("synthetic PKCS#12 body".utf8))
        let renamed = directory.appendingPathComponent("Identity (1)")      // no extension
        let typedAsBin = directory.appendingPathComponent("Identity.bin")   // unknown extension
        try payload.write(to: renamed)
        try payload.write(to: typedAsBin)

        let reader = CoordinatedPKCS12DocumentReader()
        XCTAssertEqual(try reader.readPKCS12(at: renamed), payload)
        XCTAssertEqual(try reader.readPKCS12(at: typedAsBin), payload)
    }

    func testRefusesAnUnknownExtensionWhoseContentCannotBeAPKCS12Container() throws {
        let zipNamedData = directory.appendingPathComponent("Identity.bin")
        try Data("PK\u{03}\u{04} not a certificate".utf8).write(to: zipNamedData)

        XCTAssertThrowsError(try CoordinatedPKCS12DocumentReader().readPKCS12(at: zipNamedData)) { error in
            XCTAssertEqual(error as? PKCS12DocumentReadError, .unsupportedFileType)
        }
    }
}
