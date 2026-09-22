import XCTest
@testable import ZynSign

/// Tests for the bundle-relative path value the explorer speaks.
///
/// The value must be constructible only for relative, canonical,
/// traversal-free locations inside a bundle, so that no navigation request
/// the explorer can receive names anything above the bundle root.
final class BundlePathTests: XCTestCase {

    // MARK: - Construction

    func testEmptyStringIsTheRoot() throws {
        let path = try XCTUnwrap(BundlePath(rawValue: ""))
        XCTAssertEqual(path, .root)
        XCTAssertTrue(path.isRoot)
        XCTAssertEqual(path.components, [])
        XCTAssertEqual(path.rawValue, "")
        XCTAssertEqual(path.depth, 0)
        XCTAssertNil(path.name)
        XCTAssertNil(path.parent)
    }

    func testAcceptsSingleAndNestedComponents() throws {
        let single = try XCTUnwrap(BundlePath(rawValue: "Info.plist"))
        XCTAssertEqual(single.components, ["Info.plist"])
        XCTAssertEqual(single.name, "Info.plist")
        XCTAssertEqual(single.depth, 1)
        XCTAssertEqual(single.parent, .root)

        let nested = try XCTUnwrap(BundlePath(rawValue: "Frameworks/Example.framework/Example"))
        XCTAssertEqual(nested.components, ["Frameworks", "Example.framework", "Example"])
        XCTAssertEqual(nested.rawValue, "Frameworks/Example.framework/Example")
        XCTAssertEqual(nested.name, "Example")
        XCTAssertEqual(nested.depth, 3)
        XCTAssertEqual(nested.parent?.rawValue, "Frameworks/Example.framework")
        XCTAssertEqual(nested.description, nested.rawValue)
    }

    func testPreservesCaseSpacesAndUnicode() throws {
        let path = try XCTUnwrap(BundlePath(rawValue: "Base Name.lproj/Ünïcødé 名前.strings"))
        XCTAssertEqual(path.components, ["Base Name.lproj", "Ünïcødé 名前.strings"])
        XCTAssertEqual(path.rawValue, "Base Name.lproj/Ünïcødé 名前.strings")
    }

    func testStripsSingleTrailingSeparator() throws {
        let slashed = try XCTUnwrap(BundlePath(rawValue: "Frameworks/"))
        let plain = try XCTUnwrap(BundlePath(rawValue: "Frameworks"))
        XCTAssertEqual(slashed, plain)
        XCTAssertEqual(slashed.rawValue, "Frameworks")
    }

    func testComponentInitializerMatchesTextualForm() throws {
        let fromComponents = try XCTUnwrap(BundlePath(components: ["PlugIns", "Widget.appex"]))
        let fromText = try XCTUnwrap(BundlePath(rawValue: "PlugIns/Widget.appex"))
        XCTAssertEqual(fromComponents, fromText)
        XCTAssertEqual(fromComponents.hashValue, fromText.hashValue)
        XCTAssertEqual(BundlePath(components: []), .root)
    }

    // MARK: - Refusals

    func testRefusesAbsoluteLocations() {
        XCTAssertNil(BundlePath(rawValue: "/"))
        XCTAssertNil(BundlePath(rawValue: "/Info.plist"))
        XCTAssertNil(BundlePath(rawValue: "/Payload/Example.app/Info.plist"))
    }

    func testRefusesTraversalAndDotComponents() {
        XCTAssertNil(BundlePath(rawValue: ".."))
        XCTAssertNil(BundlePath(rawValue: "."))
        XCTAssertNil(BundlePath(rawValue: "../Other.app/Info.plist"))
        XCTAssertNil(BundlePath(rawValue: "Frameworks/../../Other.app"))
        XCTAssertNil(BundlePath(rawValue: "Frameworks/./Example.framework"))
        XCTAssertNil(BundlePath(rawValue: "Frameworks/.."))
        XCTAssertNil(BundlePath(components: ["Frameworks", ".."]))
        XCTAssertNil(BundlePath(components: ["."]))
    }

    func testRefusesEmptyComponents() {
        XCTAssertNil(BundlePath(rawValue: "Frameworks//Example"))
        XCTAssertNil(BundlePath(rawValue: "Frameworks/Example//"))
        XCTAssertNil(BundlePath(components: [""]))
        XCTAssertNil(BundlePath(components: ["Frameworks", ""]))
    }

    func testRefusesSeparatorsInsideComponentsBackslashesAndNULBytes() {
        XCTAssertNil(BundlePath(components: ["Frameworks/Example"]))
        XCTAssertNil(BundlePath(rawValue: "Frameworks\\Example"))
        XCTAssertNil(BundlePath(components: ["Frameworks\\Example"]))
        XCTAssertNil(BundlePath(rawValue: "Info\0.plist"))
        XCTAssertNil(BundlePath(components: ["Info\0.plist"]))
    }

    func testRefusesPathsOverTheMaximumLength() {
        let overLimit = String(repeating: "a", count: BundlePath.maximumLength + 1)
        XCTAssertNil(BundlePath(rawValue: overLimit))
        XCTAssertNil(BundlePath(components: [overLimit]))
        let atLimit = String(repeating: "a", count: BundlePath.maximumLength)
        XCTAssertNotNil(BundlePath(rawValue: atLimit))
    }

    func testDotPrefixedNamesAreOrdinaryNames() throws {
        let hidden = try XCTUnwrap(BundlePath(rawValue: ".hidden"))
        XCTAssertEqual(hidden.name, ".hidden")
        let dotted = try XCTUnwrap(BundlePath(rawValue: "...three"))
        XCTAssertEqual(dotted.name, "...three")
    }

    // MARK: - Relations

    func testContainmentIsAStrictComponentPrefix() throws {
        let frameworks = try XCTUnwrap(BundlePath(rawValue: "Frameworks"))
        let framework = try XCTUnwrap(BundlePath(rawValue: "Frameworks/Example.framework"))
        let lookalike = try XCTUnwrap(BundlePath(rawValue: "Frameworks2/Example.framework"))

        XCTAssertTrue(framework.isWithin(frameworks))
        XCTAssertTrue(framework.isWithin(.root))
        XCTAssertTrue(frameworks.isWithin(.root))
        XCTAssertFalse(frameworks.isWithin(framework))
        XCTAssertFalse(frameworks.isWithin(frameworks))
        XCTAssertFalse(BundlePath.root.isWithin(.root))
        XCTAssertFalse(lookalike.isWithin(frameworks))
    }

    func testAppendingValidatesTheNewComponent() throws {
        let frameworks = try XCTUnwrap(BundlePath(rawValue: "Frameworks"))
        XCTAssertEqual(frameworks.appending(component: "Example.framework")?.rawValue, "Frameworks/Example.framework")
        XCTAssertEqual(BundlePath.root.appending(component: "Info.plist")?.rawValue, "Info.plist")
        XCTAssertNil(frameworks.appending(component: ".."))
        XCTAssertNil(frameworks.appending(component: ""))
        XCTAssertNil(frameworks.appending(component: "a/b"))
    }

    // MARK: - Derivation from archive locations

    func testDerivesLocationsRelativeToTheBundleDirectory() throws {
        let bundle = makePath("Payload/Example.app")

        let root = try XCTUnwrap(BundlePath(makePath("Payload/Example.app"), relativeTo: bundle))
        XCTAssertTrue(root.isRoot)

        let file = try XCTUnwrap(BundlePath(makePath("Payload/Example.app/Info.plist"), relativeTo: bundle))
        XCTAssertEqual(file.rawValue, "Info.plist")

        let nested = try XCTUnwrap(BundlePath(makePath("Payload/Example.app/Frameworks/A.framework/A"), relativeTo: bundle))
        XCTAssertEqual(nested.rawValue, "Frameworks/A.framework/A")
    }

    func testEntriesOutsideTheBundleDoNotDerive() {
        let bundle = makePath("Payload/Example.app")
        XCTAssertNil(BundlePath(makePath("Payload"), relativeTo: bundle))
        XCTAssertNil(BundlePath(makePath("Payload/Other.app/Info.plist"), relativeTo: bundle))
        XCTAssertNil(BundlePath(makePath("Payload/Example.app2/Info.plist"), relativeTo: bundle))
        XCTAssertNil(BundlePath(makePath("Example.app/Info.plist"), relativeTo: bundle))
        XCTAssertNil(BundlePath(makePath("iTunesMetadata.plist"), relativeTo: bundle))
    }
}
