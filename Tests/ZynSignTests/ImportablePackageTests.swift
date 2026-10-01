import XCTest
import UniformTypeIdentifiers
@testable import ZynSign

final class ImportablePackageTests: XCTestCase {

    func testPickerAdvertisesIPATIPAAndTheirArchiveSupertypes() throws {
        let types = ImportablePackage.contentTypes
        let ipa = try XCTUnwrap(UTType(filenameExtension: "ipa"))
        let tipa = try XCTUnwrap(UTType(filenameExtension: "tipa"))

        XCTAssertTrue(types.contains(ipa), "The picker must include the .ipa extension type")
        XCTAssertTrue(types.contains(tipa), "The picker must include the .tipa alias type")
        XCTAssertTrue(types.contains(.data))
        XCTAssertTrue(types.contains(.zip))
        XCTAssertTrue(types.contains(.item))
    }

    func testPickerTypePolicyAndImportPolicyShareTheSamePackageExtensions() {
        XCTAssertEqual(Set(IPAFileFormat.acceptedPathExtensions), ["ipa", "tipa"])
        XCTAssertTrue(IPAFileFormat.acceptsForImport(URL(fileURLWithPath: "/tmp/Example.ipa")))
        XCTAssertTrue(IPAFileFormat.acceptsForImport(URL(fileURLWithPath: "/tmp/Example.tipa")))
        XCTAssertTrue(IPAFileFormat.acceptsForImport(URL(fileURLWithPath: "/tmp/Packages.zip")))
        XCTAssertFalse(IPAFileFormat.acceptsForImport(URL(fileURLWithPath: "/tmp/Example.tipa.backup")))
    }
}
