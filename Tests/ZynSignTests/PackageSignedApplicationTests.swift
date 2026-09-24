import Foundation
import XCTest
@testable import ZynSign

/// Tests for rebuilding a signed bundle directory as a package container.
///
/// Every bundle these tests package is built at run time in a temporary
/// directory from synthetic content. No real application is involved.
final class PackageSignedApplicationTests: XCTestCase {

    private var temporaryDirectory: URL!

    override func setUp() {
        super.setUp()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zynsign-packaging-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
        super.tearDown()
    }

    // MARK: - Success paths

    func testPackagesBundleDirectory() async throws {
        let bundle = try makeBundle(named: "MyApp.app")
        let output = temporaryDirectory.appendingPathComponent("MyApp.ipa")
        let useCase = PackageSignedApplication(writer: ZipArchiveWriter())

        let report = try await useCase.package(PackageSignedApplicationRequest(
            bundleDirectory: bundle,
            bundleName: "MyApp.app",
            outputURL: output
        ))

        XCTAssertEqual(report.bundlePath, ArchivePath(rawValue: "Payload/MyApp.app"))
        XCTAssertEqual(report.entryCount, 7)
        XCTAssertGreaterThan(report.outputBytes, 0)

        // The rebuilt container reopens through the ordinary boundary with
        // content, executable bits, and links intact.
        let reader = ZipArchiveReader(location: output)
        defer { reader.close() }
        let table = try reader.readEntryTable()
        XCTAssertEqual(table.map { $0.rawName }.sorted(), [
            "Payload/",
            "Payload/MyApp.app/",
            "Payload/MyApp.app/Frameworks/",
            "Payload/MyApp.app/Info.plist",
            "Payload/MyApp.app/MyApp",
            "Payload/MyApp.app/Frameworks/Helper.dylib",
            "Payload/MyApp.app/Link",
        ].sorted())
        XCTAssertEqual(
            try reader.readEntryData(at: XCTUnwrap(ArchivePath(rawValue: "Payload/MyApp.app/MyApp"))),
            Data("executable".utf8)
        )
        let executable = try XCTUnwrap(table.first { $0.rawName == "Payload/MyApp.app/MyApp" })
        XCTAssertEqual(executable.unixMode, 0o100_755)
        let link = try XCTUnwrap(table.first { $0.rawName == "Payload/MyApp.app/Link" })
        XCTAssertEqual(link.kind, .symbolicLink)
        XCTAssertEqual(
            try reader.readEntryData(at: XCTUnwrap(ArchivePath(rawValue: "Payload/MyApp.app/Link"))),
            Data("Info.plist".utf8)
        )
    }

    func testPackagingIsDeterministic() async throws {
        let bundle = try makeBundle(named: "MyApp.app")
        let useCase = PackageSignedApplication(writer: ZipArchiveWriter())
        let first = temporaryDirectory.appendingPathComponent("first.ipa")
        let second = temporaryDirectory.appendingPathComponent("second.ipa")

        _ = try await useCase.package(PackageSignedApplicationRequest(
            bundleDirectory: bundle,
            bundleName: "MyApp.app",
            outputURL: first
        ))
        _ = try await useCase.package(PackageSignedApplicationRequest(
            bundleDirectory: bundle,
            bundleName: "MyApp.app",
            outputURL: second
        ))
        XCTAssertEqual(try Data(contentsOf: first), try Data(contentsOf: second))
    }

    // MARK: - Refusals

    func testRefusesNonBundleName() async throws {
        let bundle = try makeBundle(named: "MyApp.app")
        let useCase = PackageSignedApplication(writer: ZipArchiveWriter())
        do {
            _ = try await useCase.package(PackageSignedApplicationRequest(
                bundleDirectory: bundle,
                bundleName: "MyApp.txt",
                outputURL: temporaryDirectory.appendingPathComponent("out.ipa")
            ))
            XCTFail("Expected the non-bundle name to be refused.")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.category, .internalFailure)
        }
    }

    func testRefusesMissingInformationFile() async throws {
        let bundle = temporaryDirectory.appendingPathComponent("Empty.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("exec".utf8).write(to: bundle.appendingPathComponent("Empty"))
        let useCase = PackageSignedApplication(writer: ZipArchiveWriter())
        do {
            _ = try await useCase.package(PackageSignedApplicationRequest(
                bundleDirectory: bundle,
                bundleName: "Empty.app",
                outputURL: temporaryDirectory.appendingPathComponent("out.ipa")
            ))
            XCTFail("Expected the missing information file to be refused.")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.category, .internalFailure)
        }
    }

    func testRefusesAbsoluteSymbolicLink() async throws {
        let bundle = temporaryDirectory.appendingPathComponent("Linked.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("plist".utf8).write(to: bundle.appendingPathComponent("Info.plist"))
        try FileManager.default.createSymbolicLink(
            at: bundle.appendingPathComponent("Escape"),
            withDestinationPath: "/etc/hostname"
        )
        let useCase = PackageSignedApplication(writer: ZipArchiveWriter())
        let output = temporaryDirectory.appendingPathComponent("out.ipa")
        do {
            _ = try await useCase.package(PackageSignedApplicationRequest(
                bundleDirectory: bundle,
                bundleName: "Linked.app",
                outputURL: output
            ))
            XCTFail("Expected the absolute link to be refused.")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.category, .internalFailure)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testFailedReopenValidationRemovesTheOutput() async throws {
        let bundle = try makeBundle(named: "MyApp.app")
        let garbage = temporaryDirectory.appendingPathComponent("garbage.zip")
        try Data("not a container".utf8).write(to: garbage)
        let output = temporaryDirectory.appendingPathComponent("out.ipa")
        // The reader substitution forces the reopen step to read garbage
        // instead of the rebuilt container.
        let useCase = PackageSignedApplication(
            writer: ZipArchiveWriter(),
            makeReader: { _ in ZipArchiveReader(location: garbage) }
        )
        do {
            _ = try await useCase.package(PackageSignedApplicationRequest(
                bundleDirectory: bundle,
                bundleName: "MyApp.app",
                outputURL: output
            ))
            XCTFail("Expected the failed reopen to be reported.")
        } catch {
            XCTAssertTrue(error is ZynSignError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    // MARK: - Helpers

    @discardableResult
    private func makeBundle(named name: String) throws -> URL {
        let bundle = temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("plist".utf8).write(to: bundle.appendingPathComponent("Info.plist"))
        let executable = bundle.appendingPathComponent("MyApp")
        try Data("executable".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let frameworks = bundle.appendingPathComponent("Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        try Data("dylib".utf8).write(to: frameworks.appendingPathComponent("Helper.dylib"))
        try FileManager.default.createSymbolicLink(
            at: bundle.appendingPathComponent("Link"),
            withDestinationPath: "Info.plist"
        )
        return bundle
    }
}
