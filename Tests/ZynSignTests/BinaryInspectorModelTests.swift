import Foundation
import XCTest
@testable import ZynSign

/// Tests for the inspector's presentation state: the event-driven phase
/// machine, derived state, search, and report export.
///
/// The model is driven with `apply(_:)` — the use case's event stream —
/// without a package, and with real reports built from
/// `BinaryInspectionFixtures` through the production parser and verifier.
@MainActor
final class BinaryInspectorModelTests: XCTestCase {

    private let mainTarget = BinaryInspectionTestSupport.mainTarget

    private let frameworkTarget = BinaryTarget(
        kind: .framework,
        name: "Core",
        executablePath: BinaryInspectionTestSupport.bundlePath("Frameworks/Core.framework/Core"),
        containerPath: BinaryInspectionTestSupport.bundlePath("Frameworks/Core.framework"),
        declaredByteCount: nil
    )

    private func makeModel() -> BinaryInspectorModel {
        let library = ApplicationLibrary(
            records: InMemoryApplicationRecordStore(),
            artifacts: SyntheticLibraryArtifactStore()
        )
        let useCase = IPABinaryInspection(
            library: library,
            readerProvider: SyntheticArchiveReaderProvider.failing(
                with: ZynSignError.bundleInspectionFailure(diagnosticDetail: "not used in this test")
            ),
            makePackageReader: { _ in SyntheticArchiveReader(entryTable: [], failure: .entryTableUnreadable) },
            signedPackagesDirectory: nil,
            parser: ReadOnlyMachOParser(),
            decoder: ReadOnlyMachOLoadCommandDecoder(),
            verifier: BinarySignatureVerifier(
                digest: CryptoKitMessageDigest(),
                cmsVerifier: StubCodeSignatureCMSVerifier()
            ),
            digest: CryptoKitMessageDigest(),
            limits: .default
        )
        return BinaryInspectorModel(
            inspection: useCase,
            source: .libraryRecord(ApplicationRecordIdentifier()),
            applicationName: "Example",
            bundleIdentifier: "com.example.synthetic",
            generator: "ZynSign Test"
        )
    }

    // MARK: - Phase machine

    func testApplyDrivesPhasesAndDerivedState() throws {
        let model = makeModel()
        XCTAssertEqual(model.phase, .loading)
        XCTAssertFalse(model.isFinished)

        let overview = BinaryBundleOverview(
            bundleName: "Example.app",
            targets: [mainTarget, frameworkTarget],
            omittedTargetCount: 0
        )
        model.apply(.discovered(overview))
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.targets.map(\.name), ["Example", "Core"])
        XCTAssertEqual(model.state(for: mainTarget), .pending)
        XCTAssertEqual(model.finishedCount, 0)

        model.apply(.targetStarted(targetID: mainTarget.id))
        XCTAssertEqual(model.state(for: mainTarget), .inspecting)

        let structure = BinaryInspectionReport(
            target: mainTarget,
            fileSize: 10,
            container: .thin,
            architectures: [],
            inspectedAt: BinaryInspectionTestSupport.fixedDate,
            integrity: nil
        )
        model.apply(.structureReady(structure))
        XCTAssertEqual(model.state(for: mainTarget).report, structure)
        XCTAssertFalse(model.isFinished, "Structure alone is not finished; verification is running.")

        model.apply(.verificationProgress(targetID: mainTarget.id, completed: 1, total: 2))
        XCTAssertEqual(model.verificationFraction[mainTarget.id], 0.5)

        let finished = try finishedReport()
        model.apply(.completed(finished))
        XCTAssertEqual(model.state(for: mainTarget), .completed(finished))
        XCTAssertNil(model.verificationFraction[mainTarget.id])
        XCTAssertEqual(model.finishedCount, 1)
        XCTAssertFalse(model.isFinished, "The framework is still pending.")
        XCTAssertEqual(model.completedReports.map(\.target.name), ["Example"])

        model.apply(.unavailable(targetID: frameworkTarget.id, limitation: .missingExecutable))
        XCTAssertTrue(model.isFinished)
        XCTAssertEqual(model.finishedCount, 2)

        // The bundle-level nested check follows the nested target's fate.
        let nested = model.nestedSignaturesCheck
        XCTAssertEqual(nested.kind, .nestedSignatures)
        XCTAssertEqual(nested.status, .notPerformed)
        XCTAssertEqual(nested.summary, "0 of 1 nested executables verified")
    }

    func testApplyReportsUnavailabilityBeforeDiscoveryEnds() {
        let model = makeModel()
        model.apply(.discovered(BinaryBundleOverview(
            bundleName: "Example.app",
            targets: [mainTarget],
            omittedTargetCount: 0
        )))
        model.apply(.unavailable(targetID: mainTarget.id, limitation: .exceedsReadLimit(limit: 100, declared: 200)))
        XCTAssertTrue(model.isFinished)
        XCTAssertEqual(model.completedReports.count, 0)
        let limitation = model.state(for: mainTarget)
        XCTAssertEqual(limitation, .unavailable(.exceedsReadLimit(limit: 100, declared: 200)))
    }

    private func finishedReport() throws -> BinaryInspectionReport {
        var options = BinaryInspectionFixtures.Options()
        options.codeDirectoryFlags = CodeDirectoryFlagTable.adHoc
        options.cmsPayload = CodeSignatureCMSFixtures.codeSignatureShape
        return try BinaryInspectionTestSupport.report(
            for: BinaryInspectionFixtures.binary(options),
            target: mainTarget,
            cms: BinaryInspectionTestSupport.evaluated()
        )
    }

    // MARK: - Search

    func testSearchResultsGroupByTargetAndFollowTheQuery() throws {
        let model = makeModel()
        model.apply(.discovered(BinaryBundleOverview(
            bundleName: "Example.app",
            targets: [mainTarget],
            omittedTargetCount: 0
        )))
        var options = BinaryInspectionFixtures.Options()
        options.codeDirectoryFlags = CodeDirectoryFlagTable.adHoc
        let report = try BinaryInspectionTestSupport.report(
            for: BinaryInspectionFixtures.binary(options)
        )
        model.apply(.completed(report))

        XCTAssertTrue(model.searchResults(for: "   ").isEmpty, "A blank query matches nothing.")
        XCTAssertTrue(model.searchResults(for: "zzz-not-present").isEmpty)

        let groups = model.searchResults(for: "UIKit")
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.target.id, mainTarget.id)
        let libraryEntry = groups.first?.entries.first { $0.scope == .library }
        XCTAssertEqual(libraryEntry?.title, "UIKit")
    }

    func testSearchIndexIsBuiltOncePerReport() throws {
        let model = makeModel()
        var options = BinaryInspectionFixtures.Options()
        options.codeDirectoryFlags = CodeDirectoryFlagTable.adHoc
        let report = try BinaryInspectionTestSupport.report(
            for: BinaryInspectionFixtures.binary(options)
        )
        let first = model.searchIndex(for: report)
        let second = model.searchIndex(for: report)
        XCTAssertEqual(first.entries, second.entries)
        XCTAssertFalse(first.entries.isEmpty)
    }

    // MARK: - Export

    func testExportWritesARemovableReportFile() throws {
        let model = makeModel()
        model.apply(.discovered(BinaryBundleOverview(
            bundleName: "Example.app",
            targets: [mainTarget],
            omittedTargetCount: 0
        )))
        let report = try finishedReport()
        model.apply(.completed(report))

        let url = try model.exportFile(for: model.completedReports, format: .json)
        XCTAssertEqual(url.pathExtension, "json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url)
        guard let root = (try JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let application = root["application"] as? [String: Any] else {
            return XCTFail("The exported report must decode as a JSON object.")
        }
        XCTAssertEqual(application["name"] as? String, "Example")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("group.secret-value"),
                       "Entitlement values must never leave the inspection boundary.")
    }

    func testFailureMessagePreservesTypedErrorsAndReducesOthers() {
        let typed = ZynSignError.libraryRecordNotFound(diagnosticDetail: "synthetic")
        XCTAssertEqual(
            BinaryInspectorModel.failureMessage(for: typed),
            typed.userMessage
        )
        XCTAssertEqual(
            BinaryInspectorModel.failureMessage(for: SyntheticError()),
            "The application's executables could not be inspected."
        )
    }

    private struct SyntheticError: Error {}
}
