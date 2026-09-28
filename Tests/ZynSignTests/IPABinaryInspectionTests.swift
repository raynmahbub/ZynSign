import Foundation
import XCTest
@testable import ZynSign

/// Tests for the Binary & Signature Inspector use case: the bundle pass that
/// finds every executable in a package, streams structure before
/// verification, verifies signatures on-device, and stays read-only and
/// bounded.
///
/// Every package here is synthetic: the executable bytes come from
/// `BinaryInspectionFixtures` (parser-valid Mach-O images with real SHA-256
/// page hashes), the archive is `SyntheticArchiveReader`, and the library is
/// in memory. No package file, certificate, or key appears on disk.
final class IPABinaryInspectionTests: XCTestCase {

    // MARK: - Scaffolding

    private let executablePath = "Payload/Example.app/Example"
    private let infoPlistPath = "Payload/Example.app/Info.plist"
    private let codeResourcesPath = "Payload/Example.app/_CodeSignature/CodeResources"

    /// A reader provider that routes each artifact to its prepared reader.
    private struct RoutingReaderProvider: ArtifactArchiveReaderProvider {
        let readers: [ArtifactIdentifier: any ArchiveReader]

        func archiveReader(for artifact: ArtifactIdentifier) throws -> any ArchiveReader {
            guard let reader = readers[artifact] else {
                throw ZynSignError.libraryRecordNotFound(
                    diagnosticDetail: "synthetic: no reader prepared for \(artifact.rawValue)"
                )
            }
            return reader
        }
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let expectation: String
        init(expected: String) { self.expectation = expected }
        static func expected(_ message: String) -> TestFailure { TestFailure(expected: message) }
        var description: String { "Expected \(expectation)" }
    }

    /// The ad-hoc signed image every package in these tests carries, with a
    /// deterministic code body.
    private func signedOptions() -> BinaryInspectionFixtures.Options {
        var options = BinaryInspectionFixtures.Options()
        options.codeDirectoryFlags = CodeDirectoryFlagTable.adHoc
        return options
    }

    private func packageReader(
        executable: Data,
        infoPlist: Data = BinaryInspectionFixtures.propertyList(["CFBundleExecutable": "Example"]),
        codeResources: Data? = nil,
        extraEntries: [ArchiveEntry] = [],
        extraContent: [String: Data] = [:]
    ) -> SyntheticArchiveReader {
        var content: [String: Data] = [
            infoPlistPath: infoPlist,
            executablePath: executable,
        ]
        var tableExtras = extraEntries
        if let codeResources {
            content[codeResourcesPath] = codeResources
            // Content alone is invisible to the bundle walker: the seal must
            // also be listed as an entry for the inspector to find it.
            tableExtras.append(makeEntry(codeResourcesPath, uncompressedSize: codeResources.count))
        }
        for (path, data) in extraContent where content[path] == nil {
            content[path] = data
        }
        return SyntheticArchiveReader(entryTable: validPackageEntryTable() + tableExtras, contentByPath: content)
    }

    /// Builds one in-memory library record per reader, and the use case that
    /// reads through the routing provider.
    private func makeUseCase(
        readers: [SyntheticArchiveReader],
        cms: CodeSignatureCMSAssessment = .unreadable("No CMS mechanism in this test."),
        limits: BinaryInspectionLimits = .default,
        signedPackagesDirectory: URL? = nil,
        packageReaderOpened: @escaping () -> Void = {}
    ) async throws -> (ApplicationLibrary, [ApplicationRecord], IPABinaryInspection) {
        let records = InMemoryApplicationRecordStore()
        let artifacts = SyntheticLibraryArtifactStore()
        let library = ApplicationLibrary(records: records, artifacts: artifacts)
        var providerReaders: [ArtifactIdentifier: any ArchiveReader] = [:]
        var made: [ApplicationRecord] = []
        for reader in readers {
            let artifactID = ArtifactIdentifier()
            let stored = Data([0])
            artifacts.hold(stored, as: artifactID)
            let record = LibraryFixtures.record(
                artifact: LibraryFixtures.reference(to: stored, artifactID: artifactID)
            )
            try await records.insert(record)
            providerReaders[artifactID] = reader
            made.append(record)
        }
        let useCase = IPABinaryInspection(
            library: library,
            readerProvider: RoutingReaderProvider(readers: providerReaders),
            makePackageReader: { _ in
                packageReaderOpened()
                return SyntheticArchiveReader(entryTable: [], failure: .entryTableUnreadable)
            },
            signedPackagesDirectory: signedPackagesDirectory,
            parser: ReadOnlyMachOParser(),
            decoder: ReadOnlyMachOLoadCommandDecoder(),
            verifier: BinarySignatureVerifier(
                digest: CryptoKitMessageDigest(),
                cmsVerifier: StubCodeSignatureCMSVerifier(cms),
                now: { BinaryInspectionTestSupport.fixedDate }
            ),
            digest: CryptoKitMessageDigest(),
            limits: limits,
            now: { BinaryInspectionTestSupport.fixedDate }
        )
        return (library, made, useCase)
    }

    private func run(_ useCase: IPABinaryInspection, _ source: BinaryInspectionSource) async throws -> [BinaryInspectionEvent] {
        var events: [BinaryInspectionEvent] = []
        for try await event in useCase.inspectBundle(source) {
            events.append(event)
        }
        return events
    }

    private func completedReport(_ events: [BinaryInspectionEvent]) throws -> BinaryInspectionReport {
        guard case .completed(let report) = events.last else {
            throw TestFailure.expected("a completed event, got \(String(describing: events.last))")
        }
        return report
    }

    private func limitation(_ events: [BinaryInspectionEvent]) throws -> BinaryTargetLimitation {
        guard case .unavailable(_, let limitation) = events.last else {
            throw TestFailure.expected("an unavailable event, got \(String(describing: events.last))")
        }
        return limitation
    }

    /// A resource seal listing one sealed file, the bundle's Info.plist.
    private func seal(infoPlist: Data, infoPlistHash: Data? = nil) -> Data {
        let plist: [String: Any] = [
            "files2": [
                "Info.plist": ["hash2": infoPlistHash ?? BinaryInspectionFixtures.sha256Data(infoPlist)],
            ],
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
            preconditionFailure("A fixture seal could not be serialized.")
        }
        return data
    }

    // MARK: - The bundle pass

    func testSignedPackageVerifiesEndToEnd() async throws {
        let infoPlist = BinaryInspectionFixtures.propertyList(["CFBundleExecutable": "Example"])
        var options = signedOptions()
        options.infoPlist = infoPlist
        // A CMS blob is present so the injected CMS verifier is consulted.
        options.cmsPayload = CodeSignatureCMSFixtures.codeSignatureShape
        let bytes = BinaryInspectionFixtures.binary(options)
        let reader = packageReader(executable: bytes, infoPlist: infoPlist)
        let (_, records, useCase) = try await makeUseCase(
            readers: [reader],
            cms: BinaryInspectionTestSupport.evaluated()
        )

        let events = try await run(useCase, .libraryRecord(records[0].id))

        guard case .discovered(let overview) = events.first else {
            throw TestFailure.expected("discovered first, got \(String(describing: events.first))")
        }
        XCTAssertEqual(overview.targets.count, 1)
        XCTAssertEqual(overview.targets.first?.kind, .mainExecutable)
        XCTAssertEqual(overview.targets.first?.name, "Example")
        XCTAssertEqual(overview.omittedTargetCount, 0)
        guard case .targetStarted(let targetID) = events[1] else {
            throw TestFailure.expected("targetStarted second, got \(String(describing: events[1]))")
        }
        XCTAssertEqual(targetID, "Example")
        guard case .structureReady(let structure) = events[2] else {
            throw TestFailure.expected("structureReady third, got \(String(describing: events[2]))")
        }
        XCTAssertNil(structure.integrity, "Structure must be reported before verification finishes.")
        XCTAssertEqual(structure.architectureSummary, "arm64")
        XCTAssertEqual(structure.signaturePresence, .present)
        XCTAssertEqual(structure.fileSize, bytes.count)
        guard case .completed(let report) = events.last else {
            throw TestFailure.expected("completed last, got \(String(describing: events.last))")
        }
        // discovered, targetStarted, structureReady, final progress, completed.
        XCTAssertEqual(events.count, 5)

        XCTAssertEqual(report.verdict, .valid)
        XCTAssertEqual(report.integrity?.check(.codeDirectory)?.status, .passed)
        XCTAssertEqual(report.integrity?.check(.codeDirectory)?.summary, "Version 2.4 · SHA-256 · 2 pages")
        XCTAssertEqual(report.integrity?.check(.pageHashes)?.status, .passed)
        XCTAssertEqual(report.integrity?.check(.pageHashes)?.summary, "2 of 2 page hashes match")
        XCTAssertEqual(report.integrity?.check(.specialSlots)?.status, .passed)
        XCTAssertEqual(report.integrity?.check(.specialSlots)?.summary, "3 of 3 bound slots match")
        XCTAssertEqual(report.integrity?.check(.cmsSignature)?.status, .passed)
        XCTAssertEqual(
            report.integrity?.check(.cmsSignature)?.summary,
            "Verifies with Apple Development: Example (TEAM123456)"
        )
        XCTAssertEqual(report.integrity?.check(.requirements)?.status, .passed)
        XCTAssertEqual(report.integrity?.check(.requirements)?.summary, "Empty requirement set")
        XCTAssertEqual(report.integrity?.check(.entitlements)?.status, .passed)
        XCTAssertEqual(report.integrity?.check(.entitlements)?.summary, "2 entitlement(s) decode")
        // Certificate trust is never evaluated; it is shown, never counted.
        XCTAssertEqual(report.integrity?.check(.certificateTrust)?.status, .notPerformed)
        guard case .notSealed = report.integrity?.resourceIntegrity else {
            throw TestFailure.expected("the signature to bind no resource seal")
        }
        XCTAssertEqual(report.integrity?.verifiedAt, BinaryInspectionTestSupport.fixedDate)
        XCTAssertEqual(reader.closeCount, 1)
    }

    func testTamperedCodeFailsPageHashesAndVerdict() async throws {
        let infoPlist = BinaryInspectionFixtures.propertyList(["CFBundleExecutable": "Example"])
        var options = signedOptions()
        options.infoPlist = infoPlist
        let built = BinaryInspectionFixtures.build(options)
        let tampered = BinaryInspectionFixtures.flipping(built.bytes, at: built.layout.contentOffset + 100)
        let reader = packageReader(executable: tampered, infoPlist: infoPlist)
        let (_, records, useCase) = try await makeUseCase(readers: [reader])

        let report = try completedReport(await run(useCase, .libraryRecord(records[0].id)))

        XCTAssertEqual(report.verdict, .failed)
        XCTAssertEqual(report.integrity?.check(.pageHashes)?.status, .failed)
        XCTAssertEqual(report.integrity?.check(.pageHashes)?.summary, "1 of 2 page hashes do not match")
        // The signature's other parts are still internally consistent.
        XCTAssertEqual(report.integrity?.check(.specialSlots)?.status, .passed)
        XCTAssertEqual(report.integrity?.check(.codeDirectory)?.status, .passed)
        XCTAssertEqual(BinaryHealthEvaluator.evaluate(report).headline, "Code changed after signing")
    }

    func testUnsignedImageVerifiesAsUnsigned() async throws {
        var options = BinaryInspectionFixtures.Options()
        options.signed = false
        let reader = packageReader(executable: BinaryInspectionFixtures.binary(options))
        let (_, records, useCase) = try await makeUseCase(readers: [reader])

        let report = try completedReport(await run(useCase, .libraryRecord(records[0].id)))

        XCTAssertEqual(report.signaturePresence, .absent)
        XCTAssertEqual(report.verdict, .unsigned)
        XCTAssertEqual(report.integrity?.check(.codeDirectory)?.status, .warning)
        XCTAssertEqual(report.integrity?.check(.codeDirectory)?.summary, "No code signature")
        XCTAssertEqual(report.integrity?.check(.pageHashes)?.status, .notApplicable)
    }

    func testNonMachOIsReportedNotMachO() async throws {
        let reader = packageReader(executable: Data("definitely not a Mach-O image".utf8))
        let (_, records, useCase) = try await makeUseCase(readers: [reader])

        let limitation = try await limitation(run(useCase, .libraryRecord(records[0].id)))
        XCTAssertEqual(limitation, .notMachO)
    }

    func testCorruptedSignatureIsReportedMalformedSignature() async throws {
        let built = BinaryInspectionFixtures.build(signedOptions())
        // Corrupt the SuperBlob magic so the bounded parser refuses the region.
        let corrupted = BinaryInspectionFixtures.flipping(built.bytes, at: built.layout.signatureOffset)
        let reader = packageReader(executable: corrupted)
        let (_, records, useCase) = try await makeUseCase(readers: [reader])

        let limitation = try await limitation(run(useCase, .libraryRecord(records[0].id)))
        XCTAssertEqual(limitation, .malformedSignature)
    }

    func testOversizedExecutableIsReportedWithoutReading() async throws {
        let bytes = BinaryInspectionFixtures.binary(signedOptions())
        let reader = packageReader(executable: bytes)
        let limits = BinaryInspectionLimits(
            maximumExecutableBytes: 100,
            maximumNestedTargets: 128,
            maximumBundleInformationBytes: 1 * 1_024 * 1_024,
            maximumResourceSealBytes: 16 * 1_024 * 1_024,
            maximumSealedFileBytes: 256 * 1_024 * 1_024
        )
        let (_, records, useCase) = try await makeUseCase(readers: [reader], limits: limits)

        let limitation = try await limitation(run(useCase, .libraryRecord(records[0].id)))
        XCTAssertEqual(limitation, .exceedsReadLimit(limit: 100, declared: 4096))
        XCTAssertFalse(
            reader.requestedPaths.contains { $0.rawValue == executablePath },
            "An over-bound executable must not be read."
        )
    }

    func testPackageWithNoExecutableListsNoTargets() async throws {
        let reader = SyntheticArchiveReader(
            entryTable: validPackageEntryTable().filter { $0.path?.rawValue != executablePath },
            contentByPath: [infoPlistPath: BinaryInspectionFixtures.propertyList(["CFBundleExecutable": "Example"])]
        )
        let (_, records, useCase) = try await makeUseCase(readers: [reader])

        let events = try await run(useCase, .libraryRecord(records[0].id))
        guard case .discovered(let overview) = events.first else {
            throw TestFailure.expected("discovered first, got \(String(describing: events.first))")
        }
        XCTAssertTrue(overview.targets.isEmpty, "A bundle without an executable file lists no target.")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(reader.closeCount, 1)
    }

    func testUnreadableExecutableIsReportedAndReaderClosed() async throws {
        let bytes = BinaryInspectionFixtures.binary(signedOptions())
        let reader = SyntheticArchiveReader(
            entryTable: validPackageEntryTable(),
            contentByPath: [
                infoPlistPath: BinaryInspectionFixtures.propertyList(["CFBundleExecutable": "Example"]),
                executablePath: bytes,
            ],
            failure: .contentUnreadable
        )
        let (_, records, useCase) = try await makeUseCase(readers: [reader])

        let limitation = try await limitation(run(useCase, .libraryRecord(records[0].id)))
        XCTAssertEqual(limitation, .unreadable)
        XCTAssertEqual(reader.closeCount, 1)
    }

    func testMissingArtifactThrowsATypedError() async throws {
        let recordsStore = InMemoryApplicationRecordStore()
        let artifacts = SyntheticLibraryArtifactStore()
        let library = ApplicationLibrary(records: recordsStore, artifacts: artifacts)
        let record = LibraryFixtures.record()
        try await recordsStore.insert(record)
        let useCase = IPABinaryInspection(
            library: library,
            readerProvider: RoutingReaderProvider(readers: [:]),
            makePackageReader: { _ in SyntheticArchiveReader(entryTable: [], failure: .entryTableUnreadable) },
            signedPackagesDirectory: nil,
            parser: ReadOnlyMachOParser(),
            decoder: ReadOnlyMachOLoadCommandDecoder(),
            verifier: BinarySignatureVerifier(
                digest: CryptoKitMessageDigest(),
                cmsVerifier: StubCodeSignatureCMSVerifier(),
                now: { BinaryInspectionTestSupport.fixedDate }
            ),
            digest: CryptoKitMessageDigest(),
            limits: .default,
            now: { BinaryInspectionTestSupport.fixedDate }
        )
        do {
            _ = try await run(useCase, .libraryRecord(record.id))
            XCTFail("Inspecting a record whose artifact is gone must throw.")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.category, .storageFailure)
            XCTAssertEqual(
                error.userMessage,
                "The package for this application is missing from ZynSign's library, so its contents cannot be shown."
            )
        }
    }

    // MARK: - Bundle content the signature binds

    func testBundleContentIsBoundAndSealVerifies() async throws {
        let infoPlist = BinaryInspectionFixtures.propertyList(["CFBundleExecutable": "Example"])
        let codeResources = seal(infoPlist: infoPlist)
        var options = signedOptions()
        options.infoPlist = infoPlist
        options.codeResources = codeResources
        options.cmsPayload = CodeSignatureCMSFixtures.codeSignatureShape
        let executable = BinaryInspectionFixtures.binary(options)
        let reader = packageReader(executable: executable, infoPlist: infoPlist, codeResources: codeResources)
        let (_, records, useCase) = try await makeUseCase(
            readers: [reader],
            cms: BinaryInspectionTestSupport.evaluated()
        )

        let report = try completedReport(await run(useCase, .libraryRecord(records[0].id)))

        XCTAssertEqual(report.verdict, .valid)
        XCTAssertEqual(report.integrity?.check(.specialSlots)?.status, .passed)
        XCTAssertEqual(report.integrity?.check(.specialSlots)?.summary, "4 of 4 bound slots match")
        guard case .sealedAndBound(let count) = report.integrity?.resourceIntegrity else {
            throw TestFailure.expected("the resource seal to be sealed and bound")
        }
        XCTAssertEqual(count, 1)

        let sealed = try await useCase.verifySealedResources(
            of: report.target,
            in: .libraryRecord(records[0].id)
        )
        XCTAssertEqual(sealed.checkedCount, 1)
        XCTAssertEqual(sealed.matchedCount, 1)
        XCTAssertEqual(sealed.status, .passed)
        XCTAssertEqual(sealed.summary, "1 of 1 sealed files match")
    }

    func testTamperedResourceSealFailsSpecialSlotsAndResourceIntegrity() async throws {
        let infoPlist = BinaryInspectionFixtures.propertyList(["CFBundleExecutable": "Example"])
        let codeResources = seal(infoPlist: infoPlist)
        var options = signedOptions()
        options.infoPlist = infoPlist
        options.codeResources = codeResources
        options.cmsPayload = CodeSignatureCMSFixtures.codeSignatureShape
        let executable = BinaryInspectionFixtures.binary(options)
        // The package now holds a seal whose bytes differ from what was signed.
        let changedSeal = BinaryInspectionFixtures.flipping(codeResources, at: 40)
        let reader = packageReader(executable: executable, infoPlist: infoPlist, codeResources: changedSeal)
        let (_, records, useCase) = try await makeUseCase(readers: [reader])

        let report = try completedReport(await run(useCase, .libraryRecord(records[0].id)))

        XCTAssertEqual(report.verdict, .failed)
        XCTAssertEqual(report.integrity?.check(.specialSlots)?.status, .failed)
        guard case .sealMismatch = report.integrity?.resourceIntegrity else {
            throw TestFailure.expected("the resource integrity to report the seal changed")
        }
    }

    func testSealedResourceMismatchIsListedOnDemand() async throws {
        let infoPlist = BinaryInspectionFixtures.propertyList(["CFBundleExecutable": "Example"])
        // The seal records a digest the Info.plist's bytes do not produce.
        let codeResources = seal(
            infoPlist: infoPlist,
            infoPlistHash: BinaryInspectionFixtures.sha256Data(
                BinaryInspectionFixtures.flipping(infoPlist, at: 10)
            )
        )
        var options = signedOptions()
        options.infoPlist = infoPlist
        options.codeResources = codeResources
        let executable = BinaryInspectionFixtures.binary(options)
        let reader = packageReader(executable: executable, infoPlist: infoPlist, codeResources: codeResources)
        let (_, records, useCase) = try await makeUseCase(readers: [reader])

        let sealed = try await useCase.verifySealedResources(
            of: BinaryInspectionTestSupport.mainTarget,
            in: .libraryRecord(records[0].id)
        )
        XCTAssertEqual(sealed.checkedCount, 1)
        XCTAssertEqual(sealed.matchedCount, 0)
        XCTAssertEqual(sealed.mismatchCount, 1)
        XCTAssertEqual(sealed.mismatchedPaths, ["Info.plist"])
        XCTAssertEqual(sealed.status, .failed)
        XCTAssertEqual(sealed.summary, "Sealed files: 1 changed")
    }

    // MARK: - Nested executables

    func testNestedFrameworkIsDiscoveredAndInspected() async throws {
        let main = BinaryInspectionFixtures.binary(signedOptions())
        let frameworkInfoPlist = BinaryInspectionFixtures.propertyList(["CFBundleExecutable": "Core"])
        var frameworkOptions = signedOptions()
        frameworkOptions.entitlements = nil
        frameworkOptions.identifier = "com.example.synthetic.core"
        frameworkOptions.cmsPayload = CodeSignatureCMSFixtures.codeSignatureShape
        // The signature binds the framework's own Info.plist, so the slot
        // verification passes.
        frameworkOptions.infoPlist = frameworkInfoPlist
        let framework = BinaryInspectionFixtures.binary(frameworkOptions)
        let reader = packageReader(
            executable: main,
            extraEntries: [
                makeEntry("Payload/Example.app/Frameworks", kind: .directory),
                makeEntry("Payload/Example.app/Frameworks/Core.framework", kind: .directory),
                makeEntry("Payload/Example.app/Frameworks/Core.framework/Info.plist", uncompressedSize: 96),
                makeEntry("Payload/Example.app/Frameworks/Core.framework/Core", uncompressedSize: 4096),
            ],
            extraContent: [
                "Payload/Example.app/Frameworks/Core.framework/Info.plist": frameworkInfoPlist,
                "Payload/Example.app/Frameworks/Core.framework/Core": framework,
            ]
        )
        let (_, records, useCase) = try await makeUseCase(
            readers: [reader],
            cms: BinaryInspectionTestSupport.evaluated()
        )

        let events = try await run(useCase, .libraryRecord(records[0].id))
        guard case .discovered(let overview) = events.first else {
            throw TestFailure.expected("discovered first")
        }
        XCTAssertEqual(overview.targets.map(\.name), ["Example", "Core"])
        XCTAssertEqual(overview.targets.last?.kind, .framework)
        XCTAssertEqual(overview.mainTarget?.name, "Example")

        let reports = events.compactMap { event -> BinaryInspectionReport? in
            if case .completed(let report) = event { return report }
            return nil
        }
        XCTAssertEqual(reports.count, 2, "Every target must finish with a completed report.")
        let frameworkReport = reports.first { $0.target.kind == .framework }
        XCTAssertEqual(frameworkReport?.verdict, .valid)
        XCTAssertEqual(frameworkReport?.signaturePresence, .present)
    }

    // MARK: - Comparison

    func testComparisonCandidatesListTheOtherLibraryRecord() async throws {
        let first = packageReader(executable: BinaryInspectionFixtures.binary(signedOptions()))
        let second = packageReader(executable: BinaryInspectionFixtures.binary(signedOptions()))
        let (_, records, useCase) = try await makeUseCase(readers: [first, second])

        let candidates = try await useCase.comparisonCandidates(
            excluding: .libraryRecord(records[0].id)
        )
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.kind, .libraryRecord)
        XCTAssertEqual(candidates.first?.name, "Example")
        XCTAssertEqual(candidates.first?.bundleIdentifier, "com.example.synthetic")
    }

    func testInspectTargetMatchingComparesTheSameLocation() async throws {
        // The clean side has to be a fully bound package — information file,
        // matching seal, CMS shape — or its verdict is a warning for the
        // missing seal instead of the valid this comparison needs.
        let infoPlist = BinaryInspectionFixtures.propertyList(["CFBundleExecutable": "Example"])
        let codeResources = seal(infoPlist: infoPlist)
        var options = signedOptions()
        options.infoPlist = infoPlist
        options.codeResources = codeResources
        options.cmsPayload = CodeSignatureCMSFixtures.codeSignatureShape
        let built = BinaryInspectionFixtures.build(options)
        let tampered = BinaryInspectionFixtures.flipping(built.bytes, at: built.layout.contentOffset + 100)
        let readerA = packageReader(executable: built.bytes, infoPlist: infoPlist, codeResources: codeResources)
        let readerB = packageReader(executable: tampered, infoPlist: infoPlist, codeResources: codeResources)
        let (_, records, useCase) = try await makeUseCase(
            readers: [readerA, readerB],
            cms: BinaryInspectionTestSupport.evaluated()
        )
        let events = try await run(useCase, .libraryRecord(records[0].id))
        guard case .discovered(let overview) = events.first else {
            throw TestFailure.expected("discovered first")
        }
        let before = try completedReport(events)
        XCTAssertEqual(before.verdict, .valid)

        switch try await useCase.inspectTarget(
            matching: overview.targets[0],
            in: .libraryRecord(records[1].id)
        ) {
        case .inspected(let after):
            XCTAssertEqual(after.verdict, .failed)
            let comparison = BinaryComparator.compare(before: before, after: after)
            XCTAssertTrue(
                comparison.differences(in: .verification).contains { $0.field == "Verdict" && $0.after == "Failed" },
                "The comparison must report the verification change."
            )
        case .unavailable, .notFound:
            XCTFail("The same location in the second package must be inspected.")
        }
    }

    func testSignedPackageOutsideTheDirectoryIsRefusedWithoutOpening() async throws {
        let directory = try LibraryFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outside = directory.appendingPathComponent("Elsewhere").appendingPathExtension("ipa")
        var opened = false
        let (_, records, useCase) = try await makeUseCase(
            readers: [packageReader(executable: BinaryInspectionFixtures.binary(signedOptions()))],
            signedPackagesDirectory: directory,
            packageReaderOpened: { opened = true }
        )
        do {
            _ = try await run(useCase, .signedPackage(outside))
            XCTFail("A package outside the signed directory must be refused.")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.category, .storageFailure)
            XCTAssertEqual(
                error.userMessage,
                "ZynSign could not find the selected package in its working storage."
            )
            XCTAssertFalse(opened, "A refused package must never be opened.")
        }
    }
}
