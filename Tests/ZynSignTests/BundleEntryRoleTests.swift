import XCTest
@testable import ZynSign

/// Tests for the descriptive labels the explorer attaches to conventional
/// bundle locations.
///
/// A label is recognized from location, name, and kind alone, and its text
/// describes without concluding: nothing in a label may claim that an
/// application is signed, trusted, or installable.
final class BundleEntryRoleTests: XCTestCase {

    private func path(_ rawValue: String) throws -> BundlePath {
        try XCTUnwrap(BundlePath(rawValue: rawValue))
    }

    func testRecognizesRootLevelFiles() throws {
        XCTAssertEqual(
            BundleEntryRole.recognize(path: try path("Info.plist"), kind: .regularFile),
            .bundleInformation
        )
        XCTAssertEqual(
            BundleEntryRole.recognize(path: try path("embedded.mobileprovision"), kind: .regularFile),
            .embeddedProvisioningProfile
        )
        XCTAssertEqual(
            BundleEntryRole.recognize(path: try path("Example"), kind: .regularFile, declaredExecutableName: "Example"),
            .executable
        )
    }

    func testRecognizesRootLevelDirectories() throws {
        XCTAssertEqual(BundleEntryRole.recognize(path: try path("_CodeSignature"), kind: .directory), .codeSignatureDirectory)
        XCTAssertEqual(BundleEntryRole.recognize(path: try path("Frameworks"), kind: .directory), .frameworksDirectory)
        XCTAssertEqual(BundleEntryRole.recognize(path: try path("PlugIns"), kind: .directory), .plugInsDirectory)
        XCTAssertEqual(BundleEntryRole.recognize(path: try path("Extensions"), kind: .directory), .extensionsDirectory)
    }

    func testRecognizesTheCodeResourcesRecord() throws {
        XCTAssertEqual(
            BundleEntryRole.recognize(path: try path("_CodeSignature/CodeResources"), kind: .regularFile),
            .codeResources
        )
        XCTAssertNil(BundleEntryRole.recognize(path: try path("_CodeSignature/CodeResources"), kind: .directory))
        XCTAssertNil(BundleEntryRole.recognize(path: try path("_CodeSignature/Other"), kind: .regularFile))
        XCTAssertNil(BundleEntryRole.recognize(path: try path("Other/CodeResources"), kind: .regularFile))
    }

    func testMatchesNamesExactly() throws {
        XCTAssertNil(BundleEntryRole.recognize(path: try path("info.plist"), kind: .regularFile))
        XCTAssertNil(BundleEntryRole.recognize(path: try path("Info.plist.bak"), kind: .regularFile))
        XCTAssertNil(BundleEntryRole.recognize(path: try path("frameworks"), kind: .directory))
        XCTAssertNil(BundleEntryRole.recognize(path: try path("Plugins"), kind: .directory))
        XCTAssertNil(BundleEntryRole.recognize(path: try path("Embedded.mobileprovision"), kind: .regularFile))
        XCTAssertNil(BundleEntryRole.recognize(path: try path("Example"), kind: .regularFile, declaredExecutableName: "example"))
    }

    func testRequiresTheConventionalKind() throws {
        XCTAssertNil(BundleEntryRole.recognize(path: try path("Info.plist"), kind: .directory))
        XCTAssertNil(BundleEntryRole.recognize(path: try path("Info.plist"), kind: .symbolicLink))
        XCTAssertNil(BundleEntryRole.recognize(path: try path("Frameworks"), kind: .regularFile))
        XCTAssertNil(BundleEntryRole.recognize(path: try path("Frameworks"), kind: .symbolicLink))
        XCTAssertNil(BundleEntryRole.recognize(path: try path("Example"), kind: .directory, declaredExecutableName: "Example"))
        XCTAssertNil(BundleEntryRole.recognize(path: try path("Example"), kind: .unsupported, declaredExecutableName: "Example"))
    }

    func testRequiresTheConventionalDepth() throws {
        XCTAssertNil(BundleEntryRole.recognize(path: try path("Frameworks/A.framework/Info.plist"), kind: .regularFile))
        XCTAssertNil(BundleEntryRole.recognize(path: try path("PlugIns/W.appex/embedded.mobileprovision"), kind: .regularFile))
        XCTAssertNil(BundleEntryRole.recognize(path: try path("PlugIns/W.appex/_CodeSignature"), kind: .directory))
        XCTAssertNil(BundleEntryRole.recognize(path: try path("Frameworks/Frameworks"), kind: .directory))
        XCTAssertNil(BundleEntryRole.recognize(path: .root, kind: .directory))
    }

    func testExecutableRequiresADeclaredName() throws {
        XCTAssertNil(BundleEntryRole.recognize(path: try path("Example"), kind: .regularFile))
        XCTAssertNil(BundleEntryRole.recognize(path: try path("Example"), kind: .regularFile, declaredExecutableName: nil))
        XCTAssertNil(BundleEntryRole.recognize(path: try path("Example"), kind: .regularFile, declaredExecutableName: ""))
        XCTAssertNil(BundleEntryRole.recognize(path: try path("Example"), kind: .regularFile, declaredExecutableName: "Other"))
    }

    func testEveryRoleHasDistinctNonEmptyText() {
        let names = BundleEntryRole.allCases.map(\.displayName)
        let explanations = BundleEntryRole.allCases.map(\.explanation)
        XCTAssertTrue(names.allSatisfy { !$0.isEmpty })
        XCTAssertTrue(explanations.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(Set(explanations).count, explanations.count)
    }

    func testRoleTextMakesNoAffirmativeTrustClaims() {
        // Word-boundary matching: negations such as "untrusted" are honest
        // cautions, not affirmative claims.
        func claims(_ text: String, _ phrase: String) -> Bool {
            text.range(of: "\\b" + phrase + "\\b", options: .regularExpression) != nil
        }
        for role in BundleEntryRole.allCases {
            let text = (role.displayName + " " + role.explanation).lowercased()
            XCTAssertFalse(claims(text, "trusted"), role.rawValue)
            XCTAssertFalse(claims(text, "verified"), role.rawValue)
            XCTAssertFalse(claims(text, "genuine"), role.rawValue)
            XCTAssertFalse(claims(text, "safe to"), role.rawValue)
            XCTAssertFalse(claims(text, "valid signature"), role.rawValue)
        }
    }

    func testSecuritySensitiveRolesStateWhatTheyDoNotEstablish() {
        XCTAssertTrue(BundleEntryRole.codeSignatureDirectory.explanation.contains("not evidence"))
        XCTAssertTrue(BundleEntryRole.codeResources.explanation.contains("does not mean"))
        XCTAssertTrue(BundleEntryRole.codeResources.explanation.contains("does not read or verify"))
        XCTAssertTrue(BundleEntryRole.embeddedProvisioningProfile.explanation.contains("does not read or evaluate"))
        XCTAssertTrue(BundleEntryRole.executable.explanation.contains("does not open, load, or run"))
    }
}
