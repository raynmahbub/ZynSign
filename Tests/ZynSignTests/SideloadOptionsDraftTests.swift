import Foundation
import XCTest
@testable import ZynSign

/// The form's draft is a value conversion, so it is testable without a screen:
/// empty text means "keep the package's value", and the draft refuses with the
/// domain's own sentences rather than inventing a second set of rules.
final class SideloadOptionsDraftTests: XCTestCase {

    func testAnUntouchedDraftChangesNothing() {
        let draft = SideloadOptionsDraft()
        XCTAssertFalse(draft.isEdited)
        XCTAssertEqual(draft.editCount, 0)
        XCTAssertEqual(draft.options, .none)
        XCTAssertNil(draft.problem(hasCertificate: true))
    }

    func testEmptyTextMeansKeepThePackagesValue() {
        var draft = SideloadOptionsDraft()
        draft.bundleIdentifier = "   "
        draft.displayName = ""
        XCTAssertNil(draft.options.bundleIdentifier)
        XCTAssertNil(draft.options.displayName)
        XCTAssertFalse(draft.isEdited)
    }

    func testWhitespaceIsTrimmedRatherThanShipped() {
        var draft = SideloadOptionsDraft()
        draft.bundleIdentifier = "  com.example.renamed  "
        XCTAssertEqual(draft.options.bundleIdentifier, "com.example.renamed")
    }

    func testAMalformedIdentifierIsRefusedByTheDomain() {
        var draft = SideloadOptionsDraft()
        draft.bundleIdentifier = "not reverse dns"
        let problem = draft.problem(hasCertificate: true)
        XCTAssertNotNil(problem)
        XCTAssertTrue(problem?.contains("reverse-DNS") ?? false)
    }

    func testAMalformedVersionIsRefused() {
        var draft = SideloadOptionsDraft()
        draft.shortVersion = "1.2.3.4"
        XCTAssertNotNil(draft.problem(hasCertificate: true))
    }

    func testAdHocWithACertificateIsRefused() {
        var draft = SideloadOptionsDraft()
        draft.adHoc = true
        XCTAssertNotNil(draft.problem(hasCertificate: true))
        XCTAssertNil(draft.problem(hasCertificate: false))
    }

    func testEverySwitchReachesTheOptions() {
        var draft = SideloadOptionsDraft()
        draft.removesAppExtensions = true
        draft.removesPlugIns = true
        draft.removesWatchApps = true
        draft.removesURLSchemes = true
        draft.injectsIntoNestedCode = true
        draft.hardenedRuntime = true
        let options = draft.options
        XCTAssertTrue(options.removesAppExtensions)
        XCTAssertTrue(options.removesPlugIns)
        XCTAssertTrue(options.removesWatchApps)
        XCTAssertTrue(options.removesURLSchemes)
        XCTAssertTrue(options.injectsIntoNestedCode)
        XCTAssertTrue(options.hardenedRuntime)
    }

    func testALibraryIsAddedOnceAndTrimmed() {
        var draft = SideloadOptionsDraft()
        draft.libraryField = "  @executable_path/Frameworks/Tweak.dylib "
        draft.addLibrary()
        XCTAssertEqual(draft.libraries, ["@executable_path/Frameworks/Tweak.dylib"])
        XCTAssertTrue(draft.libraryField.isEmpty)
        draft.libraryField = "@executable_path/Frameworks/Tweak.dylib"
        draft.addLibrary()
        XCTAssertEqual(draft.libraries.count, 1, "a duplicate is not added twice")
    }

    func testAnInvalidInstallNameIsRefused() {
        var draft = SideloadOptionsDraft()
        draft.libraryField = "not-an-install-name"
        draft.addLibrary()
        XCTAssertNotNil(draft.problem(hasCertificate: true))
    }

    func testRemovingALibrary() {
        var draft = SideloadOptionsDraft()
        draft.libraryField = "@rpath/A.dylib"
        draft.addLibrary()
        draft.libraryField = "@rpath/B.dylib"
        draft.addLibrary()
        XCTAssertEqual(draft.editCount, 2)
        draft.removeLibrary("@rpath/A.dylib")
        XCTAssertEqual(draft.libraries, ["@rpath/B.dylib"])
    }

    func testInjectionIsCapped() {
        var draft = SideloadOptionsDraft()
        draft.libraries = (0..<(SideloadSigningOptions.maximumInjectedLibraries + 1))
            .map { "@rpath/Tweak\($0).dylib" }
        let problem = draft.problem(hasCertificate: true)
        XCTAssertNotNil(problem)
        XCTAssertTrue(problem?.contains("limited") ?? false)
    }

    func testTheDraftRoundTripsThroughItsOptions() {
        var draft = SideloadOptionsDraft()
        draft.bundleIdentifier = "com.example.renamed"
        draft.displayName = "Renamed"
        draft.shortVersion = "2.0"
        draft.removesAppExtensions = true
        draft.libraryField = "@rpath/T.dylib"
        draft.addLibrary()
        let options = draft.options
        XCTAssertEqual(options.bundleIdentifier, "com.example.renamed")
        XCTAssertEqual(options.displayName, "Renamed")
        XCTAssertEqual(options.shortVersion, "2.0")
        XCTAssertTrue(options.removesAppExtensions)
        XCTAssertEqual(options.injectedLibraries.map(\.installName), ["@rpath/T.dylib"])
        XCTAssertEqual(draft.editCount, 5)
    }
}
