import XCTest
@testable import ZynSign

final class ArchivePathTests: XCTestCase {

    func testAcceptsConventionalPayloadPath() throws {
        let path = try XCTUnwrap(ArchivePath(rawValue: "Payload/Example.app/Info.plist"))
        XCTAssertEqual(path.rawValue, "Payload/Example.app/Info.plist")
        XCTAssertEqual(path.components, ["Payload", "Example.app", "Info.plist"])
        XCTAssertEqual(path.lastComponent, "Info.plist")
    }

    func testPreservesCaseAndSpaces() throws {
        let path = try XCTUnwrap(ArchivePath(rawValue: "Payload/My App.app/Info.plist"))
        XCTAssertEqual(path.rawValue, "Payload/My App.app/Info.plist")
    }

    func testStripsSingleTrailingSlash() throws {
        let slashed = try XCTUnwrap(ArchivePath(rawValue: "Payload/Example.app/"))
        let plain = try XCTUnwrap(ArchivePath(rawValue: "Payload/Example.app"))
        XCTAssertEqual(slashed, plain)
        XCTAssertEqual(slashed.rawValue, "Payload/Example.app")
    }

    func testRejectsEmptyAndRootPaths() {
        XCTAssertNil(ArchivePath(rawValue: ""))
        XCTAssertNil(ArchivePath(rawValue: "/"))
    }

    func testRejectsAbsolutePaths() {
        XCTAssertNil(ArchivePath(rawValue: "/Payload/Example.app"))
    }

    func testRejectsDriveStylePrefixes() {
        XCTAssertNil(ArchivePath(rawValue: "C:/Payload/Example.app"))
        XCTAssertNil(ArchivePath(rawValue: "C:Example.app"))
    }

    func testRejectsTraversalAndDotComponents() {
        XCTAssertNil(ArchivePath(rawValue: "../Example.app"))
        XCTAssertNil(ArchivePath(rawValue: "Payload/../Example.app"))
        XCTAssertNil(ArchivePath(rawValue: "Payload/./Example.app"))
        XCTAssertNil(ArchivePath(rawValue: "."))
        XCTAssertNil(ArchivePath(rawValue: ".."))
    }

    func testRejectsEmptyComponents() {
        XCTAssertNil(ArchivePath(rawValue: "Payload//Example.app"))
        XCTAssertNil(ArchivePath(rawValue: "Payload/Example.app//"))
    }

    func testRejectsBackslashesAndNULBytes() {
        XCTAssertNil(ArchivePath(rawValue: "Payload\\Example.app"))
        XCTAssertNil(ArchivePath(rawValue: "Payload/Example\0.app"))
    }

    func testRejectsPathOverMaximumLength() {
        let overLimit = String(repeating: "a", count: ArchivePath.maximumLength + 1)
        XCTAssertNil(ArchivePath(rawValue: overLimit))
    }

    func testAcceptsPathAtMaximumLength() {
        let atLimit = String(repeating: "a", count: ArchivePath.maximumLength)
        XCTAssertNotNil(ArchivePath(rawValue: atLimit))
    }

    func testParentReturnsContainingPath() throws {
        let path = try XCTUnwrap(ArchivePath(rawValue: "Payload/Example.app/Info.plist"))
        XCTAssertEqual(path.parent, ArchivePath(rawValue: "Payload/Example.app"))
    }

    func testParentOfSingleComponentIsNil() throws {
        let path = try XCTUnwrap(ArchivePath(rawValue: "Payload"))
        XCTAssertNil(path.parent)
    }

    func testIsWithinRequiresStrictDescendant() throws {
        let bundle = try XCTUnwrap(ArchivePath(rawValue: "Payload/Example.app"))
        let nested = try XCTUnwrap(ArchivePath(rawValue: "Payload/Example.app/Example"))
        let sibling = try XCTUnwrap(ArchivePath(rawValue: "Payload/Other.app"))
        let unrelated = try XCTUnwrap(ArchivePath(rawValue: "Payload/Example.app-Doppelganger/Info.plist"))
        XCTAssertTrue(nested.isWithin(bundle))
        XCTAssertFalse(bundle.isWithin(bundle))
        XCTAssertFalse(sibling.isWithin(bundle))
        XCTAssertFalse(bundle.isWithin(nested))
        XCTAssertFalse(unrelated.isWithin(bundle))
    }

    func testAppendingValidComponent() throws {
        let bundle = try XCTUnwrap(ArchivePath(rawValue: "Payload/Example.app"))
        XCTAssertEqual(bundle.appending(component: "Info.plist")?.rawValue, "Payload/Example.app/Info.plist")
    }

    func testAppendingRejectsUnsafeComponents() throws {
        let bundle = try XCTUnwrap(ArchivePath(rawValue: "Payload/Example.app"))
        XCTAssertNil(bundle.appending(component: ""))
        XCTAssertNil(bundle.appending(component: ".."))
        XCTAssertNil(bundle.appending(component: "Nested/Info.plist"))
    }

    func testDescriptionIsTheRawValue() throws {
        let path = try XCTUnwrap(ArchivePath(rawValue: "Payload/Example.app"))
        XCTAssertEqual(path.description, "Payload/Example.app")
    }
}
