import XCTest
@testable import ZynSign

final class ArchiveEntryTests: XCTestCase {

    func testAcceptedNameProducesValidatedPath() throws {
        let entry = makeEntry("Payload/Example.app/Info.plist", kind: .regularFile, uncompressedSize: 10, compressedSize: 4)
        XCTAssertEqual(entry.path?.rawValue, "Payload/Example.app/Info.plist")
        XCTAssertEqual(entry.rawName, "Payload/Example.app/Info.plist")
        XCTAssertTrue(entry.isSafelyNamed)
        XCTAssertEqual(entry.kind, .regularFile)
        XCTAssertEqual(entry.uncompressedSize, 10)
        XCTAssertEqual(entry.compressedSize, 4)
    }

    func testRejectedNameProducesNoPath() {
        let entry = makeRejectedEntry("../outside/Info.plist")
        XCTAssertNil(entry.path)
        XCTAssertFalse(entry.isSafelyNamed)
        XCTAssertEqual(entry.rawName, "../outside/Info.plist")
    }

    func testNegativeDeclaredSizesAreClampedToZero() throws {
        let entry = ArchiveEntry(
            path: makePath("Payload/Example.app/Info.plist"),
            kind: .regularFile,
            uncompressedSize: -5,
            compressedSize: -1
        )
        XCTAssertEqual(entry.uncompressedSize, 0)
        XCTAssertEqual(entry.compressedSize, 0)
    }

    func testDiagnosticNameStripsControlCharacters() {
        let entry = makeRejectedEntry("Payload/Example.app\nForged-Log-Line")
        XCTAssertFalse(entry.diagnosticName.contains("\n"))
        XCTAssertTrue(entry.diagnosticName.contains("Payload/Example.app"))
    }

    func testDiagnosticNameIsTruncated() {
        let longName = String(repeating: "a", count: ArchiveEntry.diagnosticNameLength + 500)
        let entry = makeRejectedEntry(longName)
        XCTAssertEqual(entry.diagnosticName.count, ArchiveEntry.diagnosticNameLength + 1)
    }

    func testDirectoryEntryKindIsUsable() {
        XCTAssertTrue(ArchiveEntryKind.directory.isUsable)
        XCTAssertTrue(ArchiveEntryKind.regularFile.isUsable)
    }

    func testLinkAndUnmodelledEntryKindsAreNotUsable() {
        XCTAssertFalse(ArchiveEntryKind.symbolicLink.isUsable)
        XCTAssertFalse(ArchiveEntryKind.unsupported.isUsable)
    }

    func testEntryKindDisplayNamesAreDistinctAndNonEmpty() {
        let names = ArchiveEntryKind.allCases.map(\.displayName)
        XCTAssertTrue(names.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(names).count, names.count)
    }
}
