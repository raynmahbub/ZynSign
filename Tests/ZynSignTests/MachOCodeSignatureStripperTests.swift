import Foundation
import XCTest

/// Stripping a signature is the step that makes re-signing possible, so the
/// tests hold it to what a re-sign actually needs: the command is gone, every
/// other byte keeps its offset, and the file ends where the signature began.
final class MachOCodeSignatureStripperTests: XCTestCase {

    private func data(_ bytes: [UInt8]) -> Data { Data(bytes) }

    private func unsignedImage() -> Data {
        data(MachOFixtures.appendableThin())
    }

    func testAnUnsignedImageComesBackUnchanged() throws {
        let image = unsignedImage()
        XCTAssertEqual(try MachOCodeSignatureStripper.stripSignature(from: image), image)
        XCTAssertFalse(MachOCodeSignatureStripper.carriesSignature(image))
    }

    func testTheSignatureCommandIsRemoved() throws {
        let payload = Array(repeating: 0x43, count: 96)
        let signed = data(MachOFixtures.signedThin(payload))
        XCTAssertTrue(MachOCodeSignatureStripper.carriesSignature(signed))

        let stripped = try MachOCodeSignatureStripper.stripSignature(from: signed)
        XCTAssertFalse(MachOCodeSignatureStripper.carriesSignature(stripped))
        // The header's command count and the command table's length agree with
        // the removal: one command, sixteen bytes.
        XCTAssertEqual(readUInt32(stripped, at: 16), 0)
        XCTAssertEqual(readUInt32(stripped, at: 20), 0)
    }

    func testTheFileEndsWhereTheSignatureBegan() throws {
        let payload = Array(repeating: 0x43, count: 96)
        let signed = data(MachOFixtures.signedThin(payload))
        let stripped = try MachOCodeSignatureStripper.stripSignature(from: signed)
        XCTAssertLessThan(stripped.count, signed.count)
        XCTAssertEqual(stripped.count, 32 + 16)   // header plus the original command bytes
    }

    func testACommandTableKeepsItsLayoutAfterRemoval() throws {
        // Two commands: `__LINKEDIT`, then the signature. Removing the second
        // must leave the first exactly where it was, because every offset in
        // the file is relative to the layout.
        let fileOffset = UInt64(32 + 72 + 16)
        let segment = MachOFixtures.segment64(
            fileOffset: fileOffset, fileSize: 32, virtualMemorySize: 4_096)
        var signatureCommand = MachOFixtures.command(0x1D, size: 16)
        MachOFixtures.put(UInt64(32 + 72 + 16 + 16), at: 8, in: &signatureCommand)
        MachOFixtures.put(64, at: 12, in: &signatureCommand)
        let image = MachOFixtures.thin(
            commands: [segment, signatureCommand],
            payload: Array(repeating: 0x7E, count: 32) + Array(repeating: 0x11, count: 64)
        )
        let signed = data(image)

        let stripped = try MachOCodeSignatureStripper.stripSignature(from: signed)
        XCTAssertEqual(readUInt32(stripped, at: 16), 1)
        XCTAssertEqual(readUInt32(stripped, at: 20), 72)
        // The segment command is byte-identical and still at the same offset.
        XCTAssertEqual(Array(stripped[32..<(32 + 72)]), Array(signed[32..<(32 + 72)]))
        // The vacated 16 bytes are zeroed, not left holding a stale command.
        XCTAssertEqual(Array(stripped[(32 + 72)..<(32 + 72 + 16)]),
                       [UInt8](repeating: 0, count: 16))
    }

    func testLinkEditShrinksToTheNewFileEnd() throws {
        let fileOffset = UInt64(32 + 72)
        let segment = MachOFixtures.segment64(
            fileOffset: fileOffset, fileSize: 32, virtualMemorySize: 4_096)
        var signatureCommand = MachOFixtures.command(0x1D, size: 16)
        MachOFixtures.put(UInt64(32 + 72 + 16 + 32), at: 8, in: &signatureCommand)
        MachOFixtures.put(64, at: 12, in: &signatureCommand)
        let image = MachOFixtures.thin(
            commands: [segment, signatureCommand],
            payload: Array(repeating: 0x7E, count: 32) + Array(repeating: 0x11, count: 64)
        )
        let stripped = try MachOCodeSignatureStripper.stripSignature(from: data(image))

        let fileSize = readUInt64(stripped, at: 32 + 48)
        let virtualSize = readUInt64(stripped, at: 32 + 32)
        let signatureOffset = UInt64(32 + 72 + 16 + 32)
        XCTAssertEqual(fileSize, signatureOffset - fileOffset)
        XCTAssertGreaterThanOrEqual(virtualSize, fileSize)
        XCTAssertEqual(virtualSize % 16_384, 0, "the virtual size keeps page alignment")
    }

    func testStrippingTwiceIsTheSameAsOnce() throws {
        let signed = data(MachOFixtures.signedThin(Array(repeating: 0x43, count: 96)))
        let once = try MachOCodeSignatureStripper.stripSignature(from: signed)
        XCTAssertEqual(try MachOCodeSignatureStripper.stripSignature(from: once), once)
    }

    func testAFatContainerIsRefused() {
        var fat = [UInt8](repeating: 0, count: 64)
        fat[0] = 0xCA; fat[1] = 0xFE; fat[2] = 0xBA; fat[3] = 0xBE
        XCTAssertThrowsError(try MachOCodeSignatureStripper.stripSignature(from: data(fat))) { error in
            XCTAssertEqual(error as? MachOCodeSignatureStripper.Failure, .unsupportedForm)
        }
    }

    func testANonMachOFileIsRefused() {
        XCTAssertThrowsError(try MachOCodeSignatureStripper.stripSignature(
            from: Data("not a mach-o image at all".utf8))) { error in
            XCTAssertEqual(error as? MachOCodeSignatureStripper.Failure, .unsupportedForm)
        }
    }

    func testASignatureOutsideTheFileIsRefused() {
        var signatureCommand = MachOFixtures.command(0x1D, size: 16)
        MachOFixtures.put(9_999, at: 8, in: &signatureCommand)
        MachOFixtures.put(64, at: 12, in: &signatureCommand)
        let image = data(MachOFixtures.thin(commands: [signatureCommand],
                                            payload: [UInt8](repeating: 0, count: 32)))
        XCTAssertThrowsError(try MachOCodeSignatureStripper.stripSignature(from: image)) { error in
            XCTAssertEqual(error as? MachOCodeSignatureStripper.Failure, .invalidSignatureRegion)
        }
    }

    func testATruncatedHeaderIsRefused() {
        XCTAssertThrowsError(try MachOCodeSignatureStripper.stripSignature(
            from: Data([0xCF, 0xFA, 0xED, 0xFE]))) { error in
            XCTAssertEqual(error as? MachOCodeSignatureStripper.Failure, .malformedImage)
        }
    }

    func testA32BitImageRemovesItsCommand() throws {
        let payload = Array(repeating: 0x22, count: 64)
        let signed = data(MachOFixtures.signedThin(payload, wordSize: .bits32))
        let stripped = try MachOCodeSignatureStripper.stripSignature(from: signed)
        XCTAssertEqual(readUInt32(stripped, at: 16), 0)
        XCTAssertEqual(readUInt32(stripped, at: 20), 0)
        XCTAssertEqual(stripped.count, 28 + 16)
    }

    // MARK: - Helpers

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let bytes = [UInt8](data)
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        let bytes = [UInt8](data)
        guard offset + 8 <= bytes.count else { return 0 }
        var value: UInt64 = 0
        for index in (0..<8).reversed() { value = (value << 8) | UInt64(bytes[offset + index]) }
        return value
    }
}
