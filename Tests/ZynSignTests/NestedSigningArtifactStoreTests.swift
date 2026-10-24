import Foundation
import XCTest
@testable import ZynSign

/// Filesystem-backed regression tests for the nested-signing artifact store.
///
/// Every test works in a temporary directory it creates and removes, with
/// synthetic byte content only. The store resolves each bundle-relative path
/// against a bundle root and must refuse anything whose canonical location
/// is not the root itself or strictly beneath it.
final class NestedSigningArtifactStoreTests: XCTestCase {

    private var workDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDirectory = try LibraryFixtures.makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        if let workDirectory {
            try? FileManager.default.removeItem(at: workDirectory)
        }
        workDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - Path confinement

    func testReadBinaryReadsAFileStrictlyInsideTheBundle() throws {
        let bundle = try makeBundle(named: "App.app")
        let nested = bundle.appendingPathComponent("Frameworks/Core", isDirectory: false)
        try FileManager.default.createDirectory(
            at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        let content = Data("nested-bytes".utf8)
        try content.write(to: nested)

        let store = FileNestedSigningArtifactStore(bundleURL: bundle)
        let path = try XCTUnwrap(BundlePath(rawValue: "Frameworks/Core"))
        XCTAssertEqual(try store.readBinary(at: path), content)
    }

    func testReadBinaryRefusesASymlinkEscapeOutsideTheBundle() throws {
        let bundle = try makeBundle(named: "App.app")
        let outside = workDirectory.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside.appendingPathComponent("x"))
        try FileManager.default.createSymbolicLink(
            atPath: bundle.appendingPathComponent("Out").path, withDestinationPath: "../Outside")

        let store = FileNestedSigningArtifactStore(bundleURL: bundle)
        let path = try XCTUnwrap(BundlePath(rawValue: "Out/x"))
        XCTAssertThrowsError(try store.readBinary(at: path)) { error in
            XCTAssertEqual((error as? NestedSigningFailure)?.reason, .invalidSigningPlan)
        }
    }

    func testReadBinaryRefusesASiblingPrefixEscapeThroughASymlink() throws {
        // `App.app-evil/x` starts with the string `App.app` without being
        // inside it. Confinement must fall on a path separator, so a symlink
        // that resolves there is refused rather than read.
        let bundle = try makeBundle(named: "App.app")
        let sibling = workDirectory.appendingPathComponent("App.app-evil", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data("sibling".utf8).write(to: sibling.appendingPathComponent("x"))
        try FileManager.default.createSymbolicLink(
            atPath: bundle.appendingPathComponent("Link").path, withDestinationPath: "../App.app-evil")

        let store = FileNestedSigningArtifactStore(bundleURL: bundle)
        let path = try XCTUnwrap(BundlePath(rawValue: "Link/x"))
        XCTAssertThrowsError(try store.readBinary(at: path)) { error in
            let failure = error as? NestedSigningFailure
            XCTAssertEqual(failure?.reason, .invalidSigningPlan)
            XCTAssertEqual(failure?.path, path)
        }
    }

    func testWriteBinaryRefusesASiblingPrefixEscapeThroughASymlink() throws {
        let bundle = try makeBundle(named: "App.app")
        let sibling = workDirectory.appendingPathComponent("App.app-evil", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: bundle.appendingPathComponent("Link").path, withDestinationPath: "../App.app-evil")

        let store = FileNestedSigningArtifactStore(bundleURL: bundle)
        let path = try XCTUnwrap(BundlePath(rawValue: "Link/x"))
        XCTAssertThrowsError(try store.writeBinary(Data("no-write".utf8), at: path)) { error in
            XCTAssertEqual((error as? NestedSigningFailure)?.reason, .invalidSigningPlan)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sibling.appendingPathComponent("x").path))
    }

    // MARK: - Working-copy resource walk

    /// A path the caller states as nested code is stated once: by the
    /// nested-code seal. The walk leaves it out instead of reporting it as a
    /// resource the file seal would also hash and record.
    func testNestedCodePathsAreNeitherListedNorDescendedInto() throws {
        let bundle = try makeBundle(named: "App.app")
        let framework = bundle.appendingPathComponent("Frameworks/Kit.framework", isDirectory: true)
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        try Data("plist".utf8).write(to: framework.appendingPathComponent("Info.plist"))
        try Data("frameworks".utf8).write(to: bundle.appendingPathComponent("App"))
        let nested = try XCTUnwrap(BundlePath(rawValue: "Frameworks/Kit.framework"))

        let store = WorkingCopyResourceContentStore(
            bundleDirectory: bundle,
            nestedCodePaths: [nested]
        )
        let listing = try store.listEntries()
        let paths = Set(listing.map(\.path))

        XCTAssertFalse(paths.contains(nested))
        XCTAssertFalse(listing.contains { $0.path.rawValue.hasPrefix("Frameworks/Kit.framework/") })
        XCTAssertTrue(paths.contains(try XCTUnwrap(BundlePath(rawValue: "App"))))
    }

    /// The directory that holds nested code is walked; the code inside it is
    /// not. Listing the holder keeps the walk honest about the tree without
    /// reaching into what another seal owns.
    func testDirectoriesThatHoldNestedCodeAreStillWalked() throws {
        let bundle = try makeBundle(named: "App.app")
        let framework = bundle.appendingPathComponent("Frameworks/Kit.framework/Kit", isDirectory: false)
        try FileManager.default.createDirectory(
            at: framework.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("kit".utf8).write(to: framework)
        let nested = try XCTUnwrap(BundlePath(rawValue: "Frameworks/Kit.framework"))

        let listing = try WorkingCopyResourceContentStore(
            bundleDirectory: bundle,
            nestedCodePaths: [nested]
        ).listEntries()

        XCTAssertEqual(listing.map(\.path.rawValue), ["Frameworks"])
        XCTAssertEqual(listing.map(\.kind), [.directory])
    }

    // MARK: - Helpers

    private func makeBundle(named name: String) throws -> URL {
        let bundle = workDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        return bundle
    }
}
