import Foundation
import XCTest
@testable import ZynSign

/// A tweak is only injected when its bytes are inside the bundle before the
/// executable that loads it is signed. These tests hold staging to that: the
/// payload lands in `Frameworks`, the load command names it, a name that would
/// overwrite different bytes is refused, and the options refuse the shapes a
/// load command cannot express.
final class TweakStagingTests: XCTestCase {

    private var workspace: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("TweakStagingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// A bundle whose executable is a thin 64-bit image with room for several
    /// more load commands (the signature's and the tweaks').
    private func makeBundle(executableName: String = "Synthetic") throws -> URL {
        let bundle = workspace.appendingPathComponent("Synthetic.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let information: [String: Any] = [
            "CFBundleExecutable": executableName,
            "CFBundleIdentifier": "com.example.synthetic",
            "CFBundleName": "Synthetic"
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: information, format: .xml, options: 0)
        try data.write(to: bundle.appendingPathComponent("Info.plist"))
        try Data(MachOFixtures.appendableThin(headerPaddingLength: 512))
            .write(to: bundle.appendingPathComponent(executableName))
        return bundle
    }

    private func tweak(_ name: String = "Loader.dylib", byte: UInt8 = 0x7A) -> SideloadStagedTweak {
        SideloadStagedTweak(fileName: name, bytes: Data([byte, byte, byte]))
    }

    // MARK: - Options

    func testAValidLibraryNameIsAccepted() {
        XCTAssertTrue(SideloadSigningOptions.isTweakFileName("Loader.dylib"))
        XCTAssertTrue(SideloadSigningOptions.isTweakFileName("Loader_v2-1.dylib"))
        XCTAssertFalse(SideloadSigningOptions.isTweakFileName("Loader.framework"))
        XCTAssertFalse(SideloadSigningOptions.isTweakFileName("Sub/Loader.dylib"))
        XCTAssertFalse(SideloadSigningOptions.isTweakFileName("../Loader.dylib"))
        XCTAssertFalse(SideloadSigningOptions.isTweakFileName(".dylib"))
    }

    func testOptionsRefuseATweakThatIsNotADylib() {
        let options = SideloadSigningOptions(tweaks: [tweak("Loader.framework")])
        XCTAssertThrowsError(try options.validate(hasCertificate: true)) { error in
            XCTAssertEqual(error as? SideloadOptionError, .invalidTweakFileName("Loader.framework"))
        }
    }

    func testAStagedTweakCannotReuseATypedLibrarysInstallName() {
        let options = SideloadSigningOptions(
            injectedLibraries: [InjectedLibrary(installName: "@executable_path/Frameworks/Loader.dylib")],
            tweaks: [tweak()]
        )
        XCTAssertThrowsError(try options.validate(hasCertificate: true)) { error in
            XCTAssertEqual(error as? SideloadOptionError,
                           .duplicateInstallName("@executable_path/Frameworks/Loader.dylib"))
        }
    }

    func testOptionsRefuseAnEmptyPayloadAndADuplicateName() {
        let empty = SideloadSigningOptions(tweaks: [
            SideloadStagedTweak(fileName: "Loader.dylib", bytes: Data())
        ])
        XCTAssertThrowsError(try empty.validate(hasCertificate: true)) { error in
            XCTAssertEqual(error as? SideloadOptionError, .emptyTweakPayload("Loader.dylib"))
        }
        let duplicate = SideloadSigningOptions(tweaks: [tweak(), tweak(byte: 0x7B)])
        XCTAssertThrowsError(try duplicate.validate(hasCertificate: true)) { error in
            XCTAssertEqual(error as? SideloadOptionError, .duplicateTweakFileName("Loader.dylib"))
        }
    }

    func testOptionsRefuseTooManyStagedTweaks() {
        let tweaks = (0...SideloadSigningOptions.maximumStagedTweaks).map {
            tweak("Loader\($0).dylib", byte: UInt8($0 % 255))
        }
        let options = SideloadSigningOptions(tweaks: tweaks)
        XCTAssertThrowsError(try options.validate(hasCertificate: true)) { error in
            XCTAssertEqual(error as? SideloadOptionError, .tooManyStagedTweaks(
                limit: SideloadSigningOptions.maximumStagedTweaks))
        }
    }

    // MARK: - Editor

    func testStagingWritesThePayloadAndInjectsItsLoadCommand() throws {
        let bundle = try makeBundle()
        let payload = tweak()
        let original = try Data(contentsOf: bundle.appendingPathComponent("Synthetic"))
        let report = try SideloadPackageEditor(
            options: SideloadSigningOptions(tweaks: [payload])
        ).apply(in: bundle)

        XCTAssertEqual(report.stagedTweaks, ["Loader.dylib"])
        XCTAssertEqual(report.injectedLibraries, [payload.installName])
        XCTAssertTrue(report.patchedBinaries.contains("Synthetic"))
        XCTAssertEqual(
            try Data(contentsOf: bundle.appendingPathComponent("Frameworks/Loader.dylib")),
            payload.bytes
        )

        let edited = try Data(contentsOf: bundle.appendingPathComponent("Synthetic"))
        XCTAssertTrue(edited.range(of: Data(payload.installName.utf8)) != nil)
        // The command is written into header padding: the file does not grow.
        XCTAssertEqual(edited.count, original.count)
    }

    func testANameHoldingDifferentBytesIsRefusedRatherThanOverwritten() throws {
        let bundle = try makeBundle()
        let frameworks = bundle.appendingPathComponent("Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        try Data([0x01]).write(to: frameworks.appendingPathComponent("Loader.dylib"))

        XCTAssertThrowsError(try SideloadPackageEditor(
            options: SideloadSigningOptions(tweaks: [tweak()])
        ).apply(in: bundle)) { error in
            XCTAssertEqual(error as? SideloadEditError, .tweakNameConflict("Loader.dylib"))
        }
        XCTAssertEqual(
            try Data(contentsOf: frameworks.appendingPathComponent("Loader.dylib")),
            Data([0x01])
        )
    }

    func testStagedTweaksAndTypedLibrariesShareTheHeaderBudget() throws {
        let bundle = try makeBundle()
        let options = SideloadSigningOptions(
            injectedLibraries: [InjectedLibrary(installName: "@executable_path/Frameworks/A.dylib")],
            tweaks: [tweak(), tweak("Other.dylib", byte: 0x7C)]
        )
        let report = try SideloadPackageEditor(options: options).apply(in: bundle)
        XCTAssertEqual(report.stagedTweaks.count, 2)
        XCTAssertEqual(report.injectedLibraries.count, 3)
    }

    // MARK: - Files-app exposure

    func testFileSharingWritesBothDocumentedKeys() {
        let plan = InfoPlistOverrides.mainApplicationPlan(
            SideloadSigningOptions(enablesFileSharing: true))
        XCTAssertEqual(plan.values["UIFileSharingEnabled"], .boolean(true))
        XCTAssertEqual(plan.values["LSSupportsOpeningDocumentsInPlace"], .boolean(true))
    }

    func testFileSharingIsOffUnlessAsked() {
        let plan = InfoPlistOverrides.mainApplicationPlan(SideloadSigningOptions())
        XCTAssertNil(plan.values["UIFileSharingEnabled"])
        XCTAssertNil(plan.values["LSSupportsOpeningDocumentsInPlace"])
        XCTAssertTrue(plan.isEmpty)
    }

    func testTheEditorWritesTheFileSharingKeysIntoTheInfoPlist() throws {
        let bundle = try makeBundle()
        _ = try SideloadPackageEditor(
            options: SideloadSigningOptions(enablesFileSharing: true)
        ).apply(in: bundle)

        let data = try Data(contentsOf: bundle.appendingPathComponent("Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        let dictionary = try XCTUnwrap(plist as? [String: Any])
        XCTAssertEqual(dictionary["UIFileSharingEnabled"] as? Bool, true)
        XCTAssertEqual(dictionary["LSSupportsOpeningDocumentsInPlace"] as? Bool, true)
    }
}
