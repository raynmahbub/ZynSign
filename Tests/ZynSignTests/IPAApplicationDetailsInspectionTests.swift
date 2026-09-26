import Foundation
import XCTest
@testable import ZynSign

final class IPAApplicationDetailsInspectionTests: XCTestCase {

    private var records: InMemoryApplicationRecordStore!
    private var artifacts: SyntheticLibraryArtifactStore!
    private var library: ApplicationLibrary!

    override func setUp() {
        super.setUp()
        records = InMemoryApplicationRecordStore()
        artifacts = SyntheticLibraryArtifactStore()
        library = ApplicationLibrary(records: records, artifacts: artifacts)
    }

    override func tearDown() {
        library = nil
        artifacts = nil
        records = nil
        super.tearDown()
    }

    func testBuildsMetadataTreeArchiveAndComponentSummariesReadOnly() async throws {
        let record = try await recordAvailableApplication()
        let appInfo = try propertyList([
            "CFBundleIdentifier": "com.example.synthetic",
            "CFBundleDisplayName": "Example",
            "CFBundleShortVersionString": "1.2",
            "CFBundleVersion": "34",
            "MinimumOSVersion": "16.0",
            "CFBundleExecutable": "Example",
            "CFBundlePackageType": "APPL",
            "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "UIDeviceFamily": [1, 2],
        ])
        let extensionInfo = try propertyList([
            "CFBundleIdentifier": "com.example.synthetic.widget",
            "NSExtension": ["NSExtensionPointIdentifier": "com.apple.widgetkit-extension"],
        ])
        let executable = Data(MachOFixtures.thin())
        let table = [
            makeEntry("Payload", kind: .directory),
            makeEntry("Payload/Example.app", kind: .directory),
            makeEntry("Payload/Example.app/Info.plist", uncompressedSize: appInfo.count, compressedSize: max(1, appInfo.count / 2)),
            makeEntry("Payload/Example.app/Example", uncompressedSize: executable.count, compressedSize: executable.count),
            makeEntry("Payload/Example.app/Frameworks", kind: .directory),
            makeEntry("Payload/Example.app/Frameworks/Core.framework", kind: .directory),
            makeEntry("Payload/Example.app/Frameworks/Core.framework/Core", uncompressedSize: 200, compressedSize: 100),
            makeEntry("Payload/Example.app/Frameworks/libHelper.dylib", uncompressedSize: 80, compressedSize: 60),
            makeEntry("Payload/Example.app/PlugIns", kind: .directory),
            makeEntry("Payload/Example.app/PlugIns/Weather.appex", kind: .directory),
            makeEntry("Payload/Example.app/PlugIns/Weather.appex/Info.plist", uncompressedSize: extensionInfo.count, compressedSize: max(1, extensionInfo.count / 2)),
            makeEntry("Payload/Example.app/Watch/WatchApp.app", kind: .directory),
        ]
        let reader = SyntheticArchiveReader(
            entryTable: table,
            contentByPath: [
                "Payload/Example.app/Info.plist": appInfo,
                "Payload/Example.app/PlugIns/Weather.appex/Info.plist": extensionInfo,
                "Payload/Example.app/Example": executable,
            ]
        )

        let report = try await inspection(reading: reader).inspect(recordWithID: record.id)

        XCTAssertEqual(report.validationClassification, .valid)
        XCTAssertEqual(report.metadata?.identity.bundleIdentifier.rawValue, "com.example.synthetic")
        XCTAssertEqual(report.metadata?.minimumOSVersion, "16.0")
        XCTAssertEqual(report.metadata?.executableName, "Example")
        XCTAssertEqual(report.bundlePath?.rawValue, "Payload/Example.app")
        XCTAssertEqual(report.bundleContents?.folderCount, 6)
        XCTAssertEqual(report.bundleContents?.fileCount, 5)
        XCTAssertEqual(report.bundleType, "APPL")
        XCTAssertEqual(report.supportedPlatforms, ["iPhoneOS"])
        XCTAssertTrue(report.infoPlistEntries.contains { $0.key == "CFBundleDisplayName" && $0.valueDescription == "Example" })
        XCTAssertEqual(report.components.frameworks.map(\.name), ["Core.framework"])
        XCTAssertEqual(report.components.dynamicLibraries.map(\.name), ["libHelper.dylib"])
        XCTAssertEqual(report.components.appExtensions.count, 1)
        XCTAssertEqual(report.components.widgets.map(\.name), ["Weather.appex"])
        XCTAssertEqual(report.components.nestedApplications.map(\.name), ["WatchApp.app"])
        XCTAssertEqual(report.executable?.signatureState, .unsigned)
        XCTAssertEqual(report.executable?.architectureNames, ["ARM64"])
        XCTAssertEqual(report.archive.entryCount, table.count)
        XCTAssertEqual(report.archive.state, .compressed)
        XCTAssertEqual(reader.closeCount, 1)
        XCTAssertEqual(
            reader.requestedPaths.map(\.rawValue),
            [
                "Payload/Example.app/Info.plist",
                "Payload/Example.app/PlugIns/Weather.appex/Info.plist",
                "Payload/Example.app/Example",
            ]
        )
    }

    func testMissingExecutableBecomesStructuredErrorDiagnostic() async throws {
        let record = try await recordAvailableApplication(executableName: nil)
        let info = try propertyList(["CFBundleIdentifier": "com.example.synthetic"])
        let table = [
            makeEntry("Payload", kind: .directory),
            makeEntry("Payload/Example.app", kind: .directory),
            makeEntry("Payload/Example.app/Info.plist", uncompressedSize: info.count, compressedSize: info.count),
        ]
        let reader = SyntheticArchiveReader(
            entryTable: table,
            contentByPath: ["Payload/Example.app/Info.plist": info]
        )

        let report = try await inspection(reading: reader).inspect(recordWithID: record.id)

        XCTAssertEqual(report.validationClassification, .invalid)
        XCTAssertEqual(report.executable?.signatureState, .notInspected(.missingExecutable))
        XCTAssertTrue(report.diagnostics.contains { $0.code == ValidationIssueCode.missingExecutable.rawValue && $0.severity == .error })
        XCTAssertEqual(reader.closeCount, 1)
    }

    func testExecutableOverTheReadLimitIsNotLoadedOrMisreportedAsUnsigned() async throws {
        let record = try await recordAvailableApplication()
        let info = try propertyList([
            "CFBundleIdentifier": "com.example.synthetic",
            "CFBundleExecutable": "Example",
        ])
        let table = [
            makeEntry("Payload", kind: .directory),
            makeEntry("Payload/Example.app", kind: .directory),
            makeEntry("Payload/Example.app/Info.plist", uncompressedSize: info.count, compressedSize: info.count),
            makeEntry("Payload/Example.app/Example", uncompressedSize: 16, compressedSize: 8),
        ]
        let reader = SyntheticArchiveReader(
            entryTable: table,
            contentByPath: ["Payload/Example.app/Info.plist": info]
        )

        let report = try await IPAApplicationDetailsInspection(
            library: library,
            readerProvider: SyntheticArchiveReaderProvider.providing(reader),
            maximumExecutableReadBytes: 8
        ).inspect(recordWithID: record.id)

        XCTAssertEqual(report.executable?.signatureState, .notInspected(.exceedsReadLimit))
        XCTAssertFalse(reader.requestedPaths.contains(makePath("Payload/Example.app/Example")))
        XCTAssertTrue(report.diagnostics.contains { $0.severity == .unsupported && $0.code == "executable.read-limit" })
        XCTAssertEqual(reader.closeCount, 1)
    }

    func testMissingArtifactFailsBeforeOpeningArchive() async throws {
        let record = try await recordAvailableApplication()
        artifacts.drop(record.artifact.artifactID)
        let reader = SyntheticArchiveReader(entryTable: validPackageEntryTable())

        do {
            _ = try await inspection(reading: reader).inspect(recordWithID: record.id)
            XCTFail("Expected missing artifact to fail.")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.userMessage, ZynSignError.bundleArtifactMissing().userMessage)
        }
        XCTAssertEqual(reader.closeCount, 0)
    }

    // MARK: - Helpers

    @discardableResult
    private func recordAvailableApplication(executableName: String? = "Example") async throws -> ApplicationRecord {
        let bytes = Data(repeating: 0x5A, count: 2_048)
        let artifactID = ArtifactIdentifier()
        artifacts.hold(bytes, as: artifactID)
        let record = LibraryFixtures.record(
            identity: LibraryFixtures.identity(),
            executableName: executableName,
            artifact: LibraryFixtures.reference(to: bytes, artifactID: artifactID)
        )
        try await records.insert(record)
        return record
    }

    private func inspection(reading reader: any ArchiveReader) -> IPAApplicationDetailsInspection {
        IPAApplicationDetailsInspection(
            library: library,
            readerProvider: SyntheticArchiveReaderProvider.providing(reader)
        )
    }

    private func propertyList(_ values: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
    }
}
