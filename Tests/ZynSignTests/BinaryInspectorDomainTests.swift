import Foundation
import XCTest
@testable import ZynSign

/// Tests for the pure decision logic behind the Binary & Signature
/// Inspector: search indexes, comparisons, the signature timeline, export
/// rendering, health evaluation, verdict policy, check aggregation,
/// nested-signature evaluation, and target discovery.
///
/// The reports under test are built by running the production parser,
/// decoder, and verifier over the synthetic images in
/// `BinaryInspectionFixtures` — every page hash is a real SHA-256.
final class BinaryInspectorDomainTests: XCTestCase {

    // MARK: - Report fixtures

    private func signedOptions(cmsPayload: Data? = nil) -> BinaryInspectionFixtures.Options {
        var options = BinaryInspectionFixtures.Options()
        options.codeDirectoryFlags = CodeDirectoryFlagTable.adHoc
        options.cmsPayload = cmsPayload
        return options
    }

    /// A signed, certificate-form image whose on-device verification passes.
    private func validReport() throws -> BinaryInspectionReport {
        let options = signedOptions(cmsPayload: CodeSignatureCMSFixtures.codeSignatureShape)
        return try BinaryInspectionTestSupport.report(
            for: BinaryInspectionFixtures.binary(options),
            cms: BinaryInspectionTestSupport.evaluated()
        )
    }

    private func signedAdHocReport() throws -> BinaryInspectionReport {
        try BinaryInspectionTestSupport.report(
            for: BinaryInspectionFixtures.binary(signedOptions())
        )
    }

    private func tamperedReport() throws -> BinaryInspectionReport {
        let built = BinaryInspectionFixtures.build(signedOptions(cmsPayload: CodeSignatureCMSFixtures.codeSignatureShape))
        let tampered = BinaryInspectionFixtures.flipping(built.bytes, at: built.layout.contentOffset + 100)
        return try BinaryInspectionTestSupport.report(
            for: tampered,
            cms: BinaryInspectionTestSupport.evaluated()
        )
    }

    private func unsignedReport() throws -> BinaryInspectionReport {
        var options = BinaryInspectionFixtures.Options()
        options.signed = false
        return try BinaryInspectionTestSupport.report(
            for: BinaryInspectionFixtures.binary(options)
        )
    }

    // MARK: - Search

    func testSearchFindsLibrariesArchitecturesAndSignatureFields() throws {
        let index = BinarySearchIndex(report: try signedAdHocReport())

        let libraries = index.search("UIKit").filter { $0.scope == .library }
        XCTAssertEqual(libraries.count, 1)
        XCTAssertEqual(libraries.first?.scope, .library)
        XCTAssertEqual(libraries.first?.title, "UIKit")
        XCTAssertEqual(
            libraries.first?.detail,
            "/System/Library/Frameworks/UIKit.framework/UIKit · Required · 1.0"
        )

        let architectures = index.search("arm64").filter { $0.scope == .architecture }
        XCTAssertFalse(architectures.isEmpty, "Architecture fields must be searchable.")
        XCTAssertTrue(architectures.allSatisfy { $0.scope == .architecture })

        let identifiers = index.search("com.example.synthetic")
        XCTAssertFalse(identifiers.isEmpty)
        XCTAssertTrue(identifiers.allSatisfy { $0.scope == .signature })
        XCTAssertTrue(identifiers.contains { $0.title == "Identifier" })

        let team = index.search("team123456")
        XCTAssertTrue(team.contains { $0.title == "Team ID" && $0.detail == "TEAM123456" })

        let rpath = index.search("@rpath")
        XCTAssertTrue(rpath.contains { $0.title == "Search Path" && $0.detail == "@executable_path/Frameworks" })
    }

    func testSearchRequiresEveryWordAndRespectsTheLimit() throws {
        let index = BinarySearchIndex(report: try signedAdHocReport())

        XCTAssertTrue(index.search("").isEmpty)
        XCTAssertTrue(index.search("   ").isEmpty)
        // "uikit" alone matches; both words must appear together.
        XCTAssertFalse(index.search("uikit framework").isEmpty)
        XCTAssertTrue(index.search("uikit nonexistentword").isEmpty)
        XCTAssertTrue(index.search("zzz-not-present-anywhere").isEmpty)
        XCTAssertLessThanOrEqual(index.search("a", limit: 2).count, 2)
    }

    // MARK: - Comparison

    func testIdenticalStatesCompareClean() throws {
        let report = try validReport()
        let comparison = BinaryComparator.compare(before: report, after: report)
        XCTAssertFalse(comparison.hasDifferences)
        XCTAssertEqual(comparison.comparedArchitectureNames, ["arm64"])
    }

    func testComparisonReportsSizeDifferences() throws {
        var grown = signedOptions(cmsPayload: CodeSignatureCMSFixtures.codeSignatureShape)
        grown.codeByteCount = 7_000
        let before = try validReport()
        let after = try BinaryInspectionTestSupport.report(
            for: BinaryInspectionFixtures.binary(grown),
            cms: BinaryInspectionTestSupport.evaluated()
        )

        let comparison = BinaryComparator.compare(before: before, after: after)
        let sizes = comparison.differences(in: .size)
        XCTAssertTrue(sizes.contains { $0.field == "File size" && $0.change == .changed })
        // One architecture, so the field carries no architecture prefix.
        XCTAssertTrue(sizes.contains { $0.field == "Architecture size" && $0.change == .changed })
        // The page count and every CodeDirectory field are unchanged.
        XCTAssertTrue(comparison.differences(in: .codeDirectory).isEmpty)
    }

    func testComparisonReportsSignatureAndVerificationChanges() throws {
        let before = try validReport()
        let after = try unsignedReport()

        let comparison = BinaryComparator.compare(before: before, after: after)
        let signatures = comparison.differences(in: .signature)
        XCTAssertTrue(signatures.contains { $0.field == "Signature" && $0.before == "Present" && $0.after == "Absent" })
        XCTAssertTrue(signatures.contains { $0.field == "Signature form" && $0.after == "None" })
        let verdicts = comparison.differences(in: .verification)
        XCTAssertTrue(verdicts.contains { $0.field == "Verdict" && $0.after == "Unsigned" })
    }

    func testComparisonReportsAddedArchitectures() throws {
        let before = try validReport()
        let options = signedOptions(cmsPayload: CodeSignatureCMSFixtures.codeSignatureShape)
        var arm64eOptions = options
        arm64eOptions.cpuSubtype = 2
        let universal = BinaryInspectionFixtures.universal([options, arm64eOptions])
        let after = try BinaryInspectionTestSupport.report(
            for: universal,
            cms: BinaryInspectionTestSupport.evaluated()
        )
        XCTAssertEqual(after.architectureSummary, "arm64, arm64e")

        let comparison = BinaryComparator.compare(before: before, after: after)
        XCTAssertTrue(
            comparison.differences(in: .architectures).contains {
                $0.change == .added && $0.after == "arm64e"
            }
        )
    }

    func testComparisonReportsEntitlementKeyChanges() throws {
        var beforeOptions = signedOptions(cmsPayload: CodeSignatureCMSFixtures.codeSignatureShape)
        beforeOptions.entitlements = ["a.key": "value-a", "b.key": "value-b"]
        var afterOptions = beforeOptions
        afterOptions.entitlements = ["b.key": "value-b", "c.key": "value-c"]
        let before = try BinaryInspectionTestSupport.report(
            for: BinaryInspectionFixtures.binary(beforeOptions),
            cms: BinaryInspectionTestSupport.evaluated()
        )
        let after = try BinaryInspectionTestSupport.report(
            for: BinaryInspectionFixtures.binary(afterOptions),
            cms: BinaryInspectionTestSupport.evaluated()
        )

        let changes = BinaryComparator.compare(before: before, after: after).differences(in: .entitlements)
        XCTAssertEqual(changes.count, 2)
        XCTAssertTrue(changes.contains { $0.change == .added && $0.after == "c.key" })
        XCTAssertTrue(changes.contains { $0.change == .removed && $0.before == "a.key" })
    }

    // MARK: - Signature timeline

    func testTimelineShowsTheSigningLifecycleForVerifiedCode() throws {
        let steps = BinarySignatureTimeline.steps(for: try validReport())

        XCTAssertEqual(steps.map(\.kind), [.executable, .codeDirectory, .pageHashes, .signatureApplied, .verification])
        XCTAssertEqual(steps[0].state, .complete)
        XCTAssertEqual(steps[1].title, "CodeDirectory Generated")
        XCTAssertTrue(steps[1].detail.contains("SHA-256"))
        XCTAssertTrue(steps[1].detail.contains("com.example.synthetic"))
        let pageSizeText = ByteCountFormatter.string(fromByteCount: 4_096, countStyle: .memory)
        XCTAssertTrue(steps[2].detail.contains("2 page hashes of \(pageSizeText)"))
        XCTAssertEqual(steps[3].state, .complete)
        XCTAssertTrue(steps[3].detail.contains("Apple Development: Example (TEAM123456)"))
        // The declared signing time is the signer's own clock, never a trusted one.
        XCTAssertEqual(steps[3].timestamp, CodeSignatureCMSFixtures.declaredSigningTime)
        XCTAssertNotNil(steps[3].timestampNote)
        XCTAssertEqual(steps[4].state, .complete)
        XCTAssertEqual(steps[4].title, "Verification Passed")
        XCTAssertEqual(steps[4].timestamp, BinaryInspectionTestSupport.fixedDate)
    }

    func testTimelineShowsTheFailure() throws {
        let steps = BinarySignatureTimeline.steps(for: try tamperedReport())
        XCTAssertEqual(steps.last?.kind, .verification)
        XCTAssertEqual(steps.last?.state, .failed)
        XCTAssertEqual(steps.last?.title, "Verification Failed")
    }

    func testTimelineSkipsTheSignatureStepsForUnsignedCode() throws {
        let steps = BinarySignatureTimeline.steps(for: try unsignedReport())
        XCTAssertEqual(steps[1].state, .skipped)
        XCTAssertEqual(steps[2].state, .skipped)
        XCTAssertEqual(steps[3].state, .skipped)
        XCTAssertEqual(steps[4].state, .skipped)
        XCTAssertEqual(steps[4].title, "Verification Not Applicable")
    }

    // MARK: - Export

    private var exportContext: BinaryInspectionExportContext {
        BinaryInspectionExportContext(
            applicationName: "Example",
            bundleIdentifier: "com.example.synthetic",
            generatedAt: BinaryInspectionTestSupport.fixedDate,
            generator: "ZynSign Test 0.1.0 (4)",
            nestedSignatures: BinaryVerificationCheck(
                kind: .nestedSignatures,
                status: .notApplicable,
                summary: "No nested code",
                detail: "The bundle contains no frameworks, libraries, or extensions with executables."
            )
        )
    }

    func testTextExportCarriesResultsAndNoSecrets() throws {
        let data = BinaryInspectionReportRenderer.render(
            [try validReport()],
            context: exportContext,
            format: .text
        )
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("ZynSign — Binary & Signature Inspection Report"))
        XCTAssertTrue(text.contains("Application: Example (com.example.synthetic)"))
        XCTAssertTrue(text.contains("Verification: Valid"))
        XCTAssertTrue(text.contains("identifier com.example.synthetic"))
        XCTAssertTrue(text.contains("Apple Development: Example (TEAM123456)"))
        XCTAssertTrue(text.contains("2 of 2 page hashes match"))
        XCTAssertTrue(text.contains("Generated:"))
        XCTAssertTrue(text.contains(BinaryInspectionReportRenderer.exclusionStatement))
        // Entitlement values never leave the boundary; keys only.
        XCTAssertFalse(text.contains("group.secret-value"))
        XCTAssertTrue(text.contains("com.apple.security.application-groups"))
    }

    func testJSONExportDecodesAndListsKeysNotValues() throws {
        let data = BinaryInspectionReportRenderer.render(
            [try validReport()],
            context: exportContext,
            format: .json
        )
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("group.secret-value"))
        guard let root = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return XCTFail("The JSON export must decode as an object.")
        }
        let application = root["application"] as? [String: Any]
        XCTAssertEqual(application?["name"] as? String, "Example")
        XCTAssertEqual(application?["bundleIdentifier"] as? String, "com.example.synthetic")
        guard let executables = root["executables"] as? [[String: Any]], executables.count == 1 else {
            return XCTFail("The JSON export must list one executable.")
        }
        XCTAssertEqual(executables[0]["name"] as? String, "Example")
        XCTAssertEqual(executables[0]["verdict"] as? String, "valid")
        XCTAssertEqual(
            (executables[0]["codeSignature"] as? [String: Any])?["entitlementKeys"] as? [String],
            ["application-identifier", "com.apple.security.application-groups"]
        )
        guard let verification = executables[0]["verification"] as? [String: Any],
              let checks = verification["checks"] as? [[String: Any]] else {
            return XCTFail("The JSON export must carry the verification results.")
        }
        XCTAssertTrue(checks.contains { $0["check"] as? String == "pageHashes" && $0["status"] as? String == "passed" })
    }

    func testSuggestedFileNameIsFilesystemSafe() {
        XCTAssertEqual(
            BinaryInspectionReportRenderer.suggestedFileName(
                applicationName: "My App! (beta)",
                executableName: nil,
                format: .text
            ),
            "My-App-beta-binary-inspection.txt"
        )
        XCTAssertEqual(
            BinaryInspectionReportRenderer.suggestedFileName(
                applicationName: "My App! (beta)",
                executableName: "My App! (beta)",
                format: .json
            ),
            "My-App-beta-binary-inspection.json"
        )
        XCTAssertEqual(
            BinaryInspectionReportRenderer.suggestedFileName(
                applicationName: "My App! (beta)",
                executableName: "Helper",
                format: .json
            ),
            "My-App-beta-Helper-binary-inspection.json"
        )
    }

    // MARK: - Verdict policy

    private func check(
        _ kind: BinaryVerificationCheckKind,
        _ status: BinaryCheckStatus,
        _ summary: String = "summary",
        _ detail: String = "detail"
    ) -> BinaryVerificationCheck {
        BinaryVerificationCheck(kind: kind, status: status, summary: summary, detail: detail)
    }

    func testVerdictPolicyCountsOnlyChecksThatAffectTheVerdict() {
        XCTAssertEqual(BinaryVerdictPolicy.verdict(isSigned: false, checks: [check(.codeDirectory, .passed)]), .unsigned)
        XCTAssertEqual(BinaryVerdictPolicy.verdict(isSigned: true, checks: [check(.codeDirectory, .passed)]), .valid)
        XCTAssertEqual(
            BinaryVerdictPolicy.verdict(isSigned: true, checks: [check(.codeDirectory, .passed), check(.cmsSignature, .notPerformed)]),
            .warning
        )
        XCTAssertEqual(
            BinaryVerdictPolicy.verdict(isSigned: true, checks: [check(.codeDirectory, .passed), check(.pageHashes, .failed)]),
            .failed
        )
        // Certificate trust is never counted: it cannot make a verdict worse
        // or better.
        XCTAssertEqual(BinaryVerdictPolicy.verdict(isSigned: true, checks: [check(.certificateTrust, .notPerformed)]), .notVerified)
        XCTAssertEqual(
            BinaryVerdictPolicy.verdict(isSigned: true, checks: [check(.codeDirectory, .passed), check(.certificateTrust, .notPerformed)]),
            .valid
        )
        // A failed check outranks a warning.
        XCTAssertEqual(
            BinaryVerdictPolicy.verdict(
                isSigned: true,
                checks: [check(.codeDirectory, .warning), check(.pageHashes, .failed)]
            ),
            .failed
        )
    }

    // MARK: - Aggregation

    private func sliceResult(index: Int, _ checks: [BinaryVerificationCheck]) -> ArchitectureIntegrityResult {
        ArchitectureIntegrityResult(
            architectureIndex: index,
            isSigned: true,
            pageHashes: [],
            specialSlots: [],
            cms: .absent,
            checks: checks
        )
    }

    func testAggregationCombinesIdenticalSlicesIntoOneRow() {
        let a = sliceResult(index: 0, [check(.codeDirectory, .passed, "Same", "the detail")])
        let b = sliceResult(index: 1, [check(.codeDirectory, .passed, "Same", "the detail")])
        let rows = BinaryIntegrityAggregation.aggregate([a, b], architectureNames: [0: "arm64", 1: "arm64e"])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.status, .passed)
        XCTAssertEqual(rows.first?.summary, "Same")
        XCTAssertEqual(rows.first?.detail, "Same result in all 2 architectures. the detail")
    }

    func testAggregationNamesSlicesWhenTheyDiffer() {
        let a = sliceResult(index: 0, [check(.codeDirectory, .passed, "Same", "the detail")])
        let b = sliceResult(index: 1, [check(.codeDirectory, .passed, "Different", "other detail")])
        let rows = BinaryIntegrityAggregation.aggregate([a, b], architectureNames: [0: "arm64", 1: "arm64e"])
        XCTAssertEqual(rows.first?.summary, "arm64: Same · arm64e: Different")
    }

    func testAggregationTakesTheWorstStatusAndItsDetail() {
        let a = sliceResult(index: 0, [check(.pageHashes, .passed, "all match", "good detail")])
        let b = sliceResult(index: 1, [check(.pageHashes, .failed, "1 page differs", "bad detail")])
        let rows = BinaryIntegrityAggregation.aggregate([a, b], architectureNames: [0: "arm64", 1: "arm64e"])
        XCTAssertEqual(rows.first?.status, .failed)
        XCTAssertEqual(rows.first?.detail, "bad detail")
    }

    // MARK: - Nested signatures

    private let frameworkTarget = BinaryTarget(
        kind: .framework,
        name: "Core",
        executablePath: BinaryInspectionTestSupport.bundlePath("Frameworks/Core.framework/Core"),
        containerPath: BinaryInspectionTestSupport.bundlePath("Frameworks/Core.framework"),
        declaredByteCount: nil
    )

    func testNestedSignatureEvaluationStates() throws {
        let valid = try validReport()
        let failed = try tamperedReport()

        let allVerified = NestedSignatureEvaluation.check(
            nestedTargets: [frameworkTarget],
            progress: [frameworkTarget.id: .completed(valid)]
        )
        XCTAssertEqual(allVerified.status, .passed)
        XCTAssertEqual(allVerified.summary, "All 1 nested executables verified")

        let oneFailed = NestedSignatureEvaluation.check(
            nestedTargets: [frameworkTarget],
            progress: [frameworkTarget.id: .completed(failed)]
        )
        XCTAssertEqual(oneFailed.status, .failed)
        XCTAssertTrue(oneFailed.summary.contains("1 of 1"))

        let running = NestedSignatureEvaluation.check(
            nestedTargets: [frameworkTarget],
            progress: [frameworkTarget.id: .inspecting]
        )
        XCTAssertEqual(running.status, .notPerformed)
        XCTAssertEqual(running.summary, "Verifying nested code — 0 of 1 done")

        let unavailable = NestedSignatureEvaluation.check(
            nestedTargets: [frameworkTarget],
            progress: [frameworkTarget.id: .unavailable(.missingExecutable)]
        )
        XCTAssertEqual(unavailable.status, .notPerformed)
        XCTAssertEqual(unavailable.summary, "0 of 1 nested executables verified")

        let omitted = NestedSignatureEvaluation.check(
            nestedTargets: [],
            progress: [:],
            omittedTargetCount: 3
        )
        XCTAssertEqual(omitted.status, .notPerformed)
        XCTAssertEqual(omitted.summary, "3 nested executable(s) not inspected")

        let none = NestedSignatureEvaluation.check(nestedTargets: [], progress: [:])
        XCTAssertEqual(none.status, .notApplicable)
        XCTAssertEqual(none.summary, "No nested code")
    }

    // MARK: - Health

    func testHealthEvaluatorHeadlines() throws {
        let unsigned = BinaryHealthEvaluator.evaluate(try unsignedReport())
        XCTAssertEqual(unsigned.headline, "No code signature")
        XCTAssertTrue(unsigned.findings.contains { $0.severity == .critical && $0.title == "No code signature" })

        let valid = BinaryHealthEvaluator.evaluate(try validReport())
        XCTAssertEqual(valid.headline, "Signature intact and verified")
        XCTAssertTrue(valid.findings.contains { $0.severity == .positive && $0.title == "Signature intact" })

        let tampered = BinaryHealthEvaluator.evaluate(try tamperedReport())
        XCTAssertEqual(tampered.headline, "Code changed after signing")
        XCTAssertTrue(tampered.findings.contains { $0.severity == .critical && $0.title == "Code changed after signing" })
    }

    func testHealthEvaluatorFlagsEncryptedCode() throws {
        var options = signedOptions()
        options.cryptID = 2
        let report = try BinaryInspectionTestSupport.report(for: BinaryInspectionFixtures.binary(options))
        XCTAssertEqual(report.encryptionState, .encrypted)
        let health = BinaryHealthEvaluator.evaluate(report)
        XCTAssertTrue(health.findings.contains { $0.title == "App Store encryption active" && $0.severity == .warning })
    }

    func testHealthEvaluatorFlagsMissingDeviceArchitecture() throws {
        var options = signedOptions()
        options.cpu = MachOFixtures.x86_64
        let report = try BinaryInspectionTestSupport.report(for: BinaryInspectionFixtures.binary(options))
        XCTAssertFalse(report.hasDeviceArchitecture)
        XCTAssertTrue(
            BinaryHealthEvaluator.evaluate(report).findings.contains { $0.title == "No iPhone or iPad architecture" }
        )
    }

    // MARK: - Target discovery

    private var discoveryTable: [ArchiveEntry] {
        [
            makeEntry("Payload", kind: .directory),
            makeEntry("Payload/Example.app", kind: .directory),
            makeEntry("Payload/Example.app/Info.plist", uncompressedSize: 128),
            makeEntry("Payload/Example.app/Example", uncompressedSize: 4_096),
            makeEntry("Payload/Example.app/Frameworks", kind: .directory),
            makeEntry("Payload/Example.app/Frameworks/Core.framework", kind: .directory),
            makeEntry("Payload/Example.app/Frameworks/Core.framework/Core", uncompressedSize: 4_096),
            makeEntry("Payload/Example.app/Frameworks/extra.dylib", uncompressedSize: 4_096),
            makeEntry("Payload/Example.app/PlugIns", kind: .directory),
            makeEntry("Payload/Example.app/PlugIns/Messages.appex", kind: .directory),
            makeEntry("Payload/Example.app/PlugIns/Messages.appex/Messages", uncompressedSize: 4_096),
            makeEntry("Payload/Example.app/Watch", kind: .directory),
            makeEntry("Payload/Example.app/Watch/Complication.app", kind: .directory),
            makeEntry("Payload/Example.app/Watch/Complication.app/Complication", uncompressedSize: 4_096),
        ]
    }

    private func discovery(
        declared: [BundlePath: String] = [:],
        mainExecutableName: String? = "Example",
        maximumNestedTargets: Int = 128
    ) -> BinaryBundleOverview {
        let contents = BundleContents(entryTable: discoveryTable, bundlePath: makePath("Payload/Example.app"))
        return BinaryTargetDiscovery.discover(
            contents: contents,
            mainExecutableName: mainExecutableName,
            declaredExecutableNames: declared,
            maximumNestedTargets: maximumNestedTargets
        )
    }

    func testDiscoveryListsConventionalExecutablesInDashboardOrder() {
        let overview = discovery()
        XCTAssertEqual(
            overview.targets.map { $0.name + ":\(String(describing: $0.kind))" },
            [
                "Example:mainExecutable",
                "Core:framework",
                "extra.dylib:dynamicLibrary",
                "Messages:appExtension",
                "Complication:nestedApplication",
            ]
        )
        XCTAssertEqual(overview.mainTarget?.name, "Example")
        XCTAssertEqual(overview.omittedTargetCount, 0)
        XCTAssertEqual(overview.targets.last?.containerName, "Complication.app")
    }

    func testDiscoveryHonoursDeclaredExecutableNames() {
        let declared: [BundlePath: String] = [
            BinaryInspectionTestSupport.bundlePath("Frameworks/Core.framework"): "RenamedCore",
        ]
        let overview = discovery(declared: declared)
        XCTAssertEqual(overview.targets.map(\.name).first { $0.hasSuffix("Core") }, "RenamedCore")
    }

    func testDiscoveryCountsExecutablesBeyondTheBound() {
        let overview = discovery(maximumNestedTargets: 1)
        XCTAssertEqual(overview.targets.map(\.kind), [.mainExecutable, .framework])
        XCTAssertEqual(overview.omittedTargetCount, 3)
    }

    func testDiscoveryRejectsUnsafeDeclaredNames() {
        let declared: [BundlePath: String] = [
            BinaryInspectionTestSupport.bundlePath("Frameworks/Core.framework"): "../Evil",
        ]
        let overview = discovery(declared: declared)
        // The unsafe declaration falls back to the platform naming rule.
        XCTAssertEqual(overview.targets.map(\.name).first { $0 == "Core" }, "Core")
    }

    func testDiscoveryRequiresARegularFileCandidate() {
        var table = discoveryTable
        table.removeAll { $0.path?.rawValue == "Payload/Example.app/Frameworks/Core.framework/Core" }
        let contents = BundleContents(entryTable: table, bundlePath: makePath("Payload/Example.app"))
        let overview = BinaryTargetDiscovery.discover(
            contents: contents,
            mainExecutableName: "Example",
            declaredExecutableNames: [:],
            maximumNestedTargets: 128
        )
        XCTAssertEqual(overview.targets.map(\.name), ["Example", "extra.dylib", "Messages", "Complication"])
    }
}
