import XCTest
@testable import ZynSign

/// Integration tests for the Import Hub's per-item workflow, over the real
/// platform intake, ZIP reader, entry extractor, and library artifact store,
/// in a temporary directory the test owns.
///
/// Every package and archive is generated in memory by the fixture builder.
/// The tests check the guarantees the hub relies on: originals are only
/// read, archives are classified before anything is extracted, analysis
/// reads what the package holds, conflicts follow the rules, and only an
/// explicit admission changes the library.
final class ImportWorkflowTests: XCTestCase {

    private var root: URL!
    private var sources: URL!
    private var staging: URL!
    private var libraryDirectory: URL!
    private var records: InMemoryApplicationRecordStore!
    private var library: ApplicationLibrary!
    private var intake: SecurityScopedArtifactIntake!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZynSignWorkflowTests-\(UUID().uuidString)", isDirectory: true)
        sources = root.appendingPathComponent("Sources", isDirectory: true)
        staging = root.appendingPathComponent("Staging", isDirectory: true)
        libraryDirectory = root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        records = InMemoryApplicationRecordStore()
        library = ApplicationLibrary(
            records: records,
            artifacts: FileLibraryArtifactStore(stagingDirectory: staging, libraryDirectory: libraryDirectory)
        )
        intake = SecurityScopedArtifactIntake(directory: staging)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
        intake = nil
        library = nil
        records = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeWorkflow(capacity: Int? = nil) -> ImportWorkflow {
        ImportWorkflow(
            intake: intake,
            stagingArea: intake,
            readerProvider: DirectoryArtifactArchiveReaderProvider(directories: [libraryDirectory, staging]),
            library: library,
            storage: ImportStorageGuard(probe: capacity.map { FixedStorageCapacityProbe(capacity: $0) })
        )
    }

    private func writeSource(_ name: String, _ content: Data) -> URL {
        ImportFixtures.writeFile(named: name, content: content, in: sources)
    }

    private func stagedFiles() -> Set<String> {
        ImportFixtures.fileNames(in: staging)
    }

    private func prepare(
        _ source: URL,
        with workflow: ImportWorkflow? = nil
    ) async throws -> PreparedImport {
        let flow = workflow ?? makeWorkflow()
        let staged = try await flow.stage(.document(source), fileName: source.lastPathComponent, as: ArtifactIdentifier(), reporting: nil)
        guard case .package(let prepared) = try await flow.examine(staged, reporting: nil) else {
            XCTFail("Expected an application package.")
            throw CancellationError()
        }
        return prepared
    }

    private func importPackage(_ content: Data, named name: String) async throws -> ApplicationRecord {
        let workflow = makeWorkflow()
        let prepared = try await prepare(writeSource(name, content), with: workflow)
        let settlement = try await workflow.admit(prepared, resolution: prepared.conflict == nil ? nil : .keepBoth, reporting: nil)
        return try XCTUnwrap(settlement.record)
    }

    private func examineFailure(_ source: URL) async throws -> ImportFailure? {
        let workflow = makeWorkflow()
        let staged = try await workflow.stage(.document(source), fileName: source.lastPathComponent, as: ArtifactIdentifier(), reporting: nil)
        do {
            _ = try await workflow.examine(staged, reporting: nil)
            XCTFail("Expected the examination to refuse the file.")
            return nil
        } catch let failure as ImportFailure {
            return failure
        }
    }

    private static let iconBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 0x01, count: 32))

    private static let richPackageExtras: [ZipFixtureBuilder.Entry] = [
        ZipFixtureBuilder.Entry(name: "Payload/Example.app/_CodeSignature/CodeResources", content: Array("seal".utf8)),
        ZipFixtureBuilder.Entry(name: "Payload/Example.app/embedded.mobileprovision", content: Array("profile".utf8)),
        ZipFixtureBuilder.Entry(name: "Payload/Example.app/Frameworks/Alpha.framework/Alpha", content: [0x01, 0x02]),
        ZipFixtureBuilder.Entry(name: "Payload/Example.app/Frameworks/Beta.framework/Info.plist", content: [0x03]),
        ZipFixtureBuilder.Entry(name: "Payload/Example.app/PlugIns/Widget.appex/Info.plist", content: [0x04]),
        ZipFixtureBuilder.Entry(name: "Payload/Example.app/AppIcon60x60@2x.png", content: Array(iconBytes)),
    ]

    // MARK: - Packages

    func testAPackageIsValidatedAndAnalyzedWithoutTouchingTheOriginalOrTheLibrary() async throws {
        let content = ImportHubFixtures.package(version: "1.2", build: "34", extraBundleEntries: Self.richPackageExtras)
        let source = writeSource("Example.ipa", content)
        let before = try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date

        let prepared = try await prepare(source)

        XCTAssertEqual(prepared.identity.bundleIdentifier.rawValue, "com.example.synthetic")
        XCTAssertEqual(prepared.identity.displayName, "Example")
        XCTAssertEqual(prepared.identity.shortVersionString, "1.2")
        XCTAssertEqual(prepared.identity.buildVersion, "34")
        XCTAssertEqual(prepared.byteCount, content.count)
        XCTAssertEqual(prepared.analysis.signingState, .signaturePresent)
        XCTAssertTrue(prepared.analysis.includesProvisioningProfile)
        XCTAssertEqual(prepared.analysis.frameworkCount, 2)
        XCTAssertEqual(prepared.analysis.extensionCount, 1)
        XCTAssertEqual(prepared.iconData, Self.iconBytes)
        XCTAssertNil(prepared.conflict)

        // The original is byte-identical and untouched; the library is empty.
        XCTAssertEqual(try Data(contentsOf: source), content)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date, before)
        let stored = try await records.allRecords()
        XCTAssertTrue(stored.isEmpty)
        XCTAssertEqual(stagedFiles(), ["\(prepared.artifactID.rawValue).ipa"])
    }

    func testAnUnsignedPackageIsReportedAsUnsigned() async throws {
        let prepared = try await prepare(writeSource("Plain.ipa", ImportHubFixtures.package()))
        XCTAssertEqual(prepared.analysis.signingState, .unsigned)
        XCTAssertFalse(prepared.analysis.includesProvisioningProfile)
        XCTAssertEqual(prepared.analysis.frameworkCount, 0)
        XCTAssertNil(prepared.iconData)
    }

    func testAdmittingStoresThePackageAndConsumesTheWorkingCopy() async throws {
        let workflow = makeWorkflow()
        let prepared = try await prepare(writeSource("Example.ipa", ImportHubFixtures.package()), with: workflow)

        let settlement = try await workflow.admit(prepared, resolution: nil, reporting: nil)

        XCTAssertEqual(settlement.kind, .imported)
        XCTAssertEqual(settlement.record?.identity.bundleIdentifier.rawValue, "com.example.synthetic")
        let record = try XCTUnwrap(settlement.record)
        let stored = try await records.allRecords()
        XCTAssertEqual(stored.map(\.id), [record.id])
        XCTAssertTrue(stagedFiles().isEmpty, "The working copy moved into the library.")
    }

    func testAFileThatIsNotAnArchiveIsRefusedBeforeCopying() async throws {
        let source = writeSource("Fake.ipa", Data(ZipFixtureBuilder.notAnArchive()))
        do {
            _ = try await makeWorkflow().stage(.document(source), fileName: "Fake.ipa", as: ArtifactIdentifier(), reporting: nil)
            XCTFail("Expected the file to be refused.")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.category, .invalidInput)
        }
        XCTAssertTrue(stagedFiles().isEmpty)
    }

    func testACorruptedArchiveIsRejected() async throws {
        let source = writeSource("Damaged.ipa", Data(ZipFixtureBuilder.corruptCentralDirectory(ZipFixtureBuilder.validPackage())))
        let failure = try await examineFailure(source)
        XCTAssertEqual(failure, ImportFailure.corruptedArchive())
    }

    // MARK: - Archives

    func testAZipOfPackagesIsOfferedAndEachExtractsIntoItsOwnWorkingCopy() async throws {
        let one = ImportHubFixtures.package(identifier: "com.example.one", displayName: "One")
        let two = ImportHubFixtures.package(identifier: "com.example.two", displayName: "Two")
        let archive = Data(ZipFixtureBuilder.archive([
            .directory("Apps"),
            ZipFixtureBuilder.Entry(name: "Apps/One.ipa", content: Array(one), deflate: true),
            ZipFixtureBuilder.Entry(name: "Two.ipa", content: Array(two)),
            ZipFixtureBuilder.Entry(name: "__MACOSX/._One.ipa", content: [0x00, 0x05]),
            ZipFixtureBuilder.Entry(name: "ReadMe.txt", content: Array("hello".utf8)),
        ]))
        let workflow = makeWorkflow()
        let source = writeSource("Bundle.zip", archive)
        let container = try await workflow.stage(.document(source), fileName: "Bundle.zip", as: ArtifactIdentifier(), reporting: nil)

        guard case .archive(let candidates) = try await workflow.examine(container, reporting: nil) else {
            return XCTFail("Expected the archive's packages to be offered.")
        }
        XCTAssertEqual(candidates.map(\.path.rawValue), ["Apps/One.ipa", "Two.ipa"], "Resource forks and other files are never offered.")
        XCTAssertEqual(candidates.first?.byteCount, one.count)

        let childID = ArtifactIdentifier()
        let child = try await workflow.stage(
            .archiveEntry(container: container.artifactID, candidate: candidates[0]),
            fileName: candidates[0].fileName,
            as: childID,
            reporting: nil
        )
        XCTAssertEqual(child.artifactID, childID)
        XCTAssertEqual(try Data(contentsOf: staging.appendingPathComponent("\(childID.rawValue).ipa")), one, "The package is extracted byte for byte.")

        guard case .package(let prepared) = try await workflow.examine(child, reporting: nil) else {
            return XCTFail("Expected the extracted package to be analyzed.")
        }
        XCTAssertEqual(prepared.identity.bundleIdentifier.rawValue, "com.example.one")
        XCTAssertEqual(prepared.artifact.sourceFileName, "One.ipa")
        XCTAssertEqual(try Data(contentsOf: source), archive, "The archive is only read.")
        XCTAssertEqual(stagedFiles(), ["\(container.artifactID.rawValue).ipa", "\(childID.rawValue).ipa"])
    }

    func testAZipWithoutPackagesIsRefusedWithAnExplanation() async throws {
        let source = writeSource("Photos.zip", Data(ZipFixtureBuilder.archive([
            ZipFixtureBuilder.Entry(name: "Photo.jpg", content: [0xFF, 0xD8]),
        ])))
        let failure = try await examineFailure(source)
        XCTAssertEqual(failure, ImportFailure.archiveHasNoPackages())
    }

    func testAnArchiveWithAnUnsafeEntryIsRefusedWhole() async throws {
        let source = writeSource("Evil.zip", Data(ZipFixtureBuilder.archive([
            ZipFixtureBuilder.Entry(name: "Good.ipa", content: Array(ImportHubFixtures.package())),
            ZipFixtureBuilder.Entry(name: "../../escape.ipa", content: [0x01]),
        ])))
        let failure = try await examineFailure(source)
        XCTAssertEqual(failure?.title, "Archive Refused")
        XCTAssertEqual(failure?.primaryCode, .unsafePath)
    }

    func testAnArchiveWithDuplicateEntriesIsRefused() async throws {
        let package = Array(ImportHubFixtures.package())
        let source = writeSource("Twice.zip", Data(ZipFixtureBuilder.archive([
            ZipFixtureBuilder.Entry(name: "App.ipa", content: package),
            ZipFixtureBuilder.Entry(name: "App.ipa", content: [0x00]),
        ])))
        let failure = try await examineFailure(source)
        XCTAssertEqual(failure?.primaryCode, .conflictingPaths)
    }

    func testAnXcodeArchiveIsExplainedAsUnsupported() async throws {
        let source = writeSource("Build.zip", Data(ZipFixtureBuilder.archive([
            ZipFixtureBuilder.Entry(name: "MyApp.xcarchive/Info.plist", content: [0x01]),
            ZipFixtureBuilder.Entry(name: "MyApp.xcarchive/Products/Applications/MyApp.app/Info.plist", content: [0x02]),
        ])))
        let failure = try await examineFailure(source)
        XCTAssertEqual(failure, ImportFailure.unsupportedLayout(.xcodeArchive))
    }

    func testAnArchiveOfCertificateMaterialExplainsWhereCertificatesGo() async throws {
        // The certificate bundle people actually receive: a .p12 and a
        // .mobileprovision zipped together. The hub refuses it — it imports
        // packages — but the refusal names Certificates & Profiles instead
        // of claiming the archive holds nothing.
        let source = writeSource("Certs.zip", Data(ZipFixtureBuilder.archive([
            ZipFixtureBuilder.Entry(name: "Signer.p12", content: [0x30]),
            ZipFixtureBuilder.Entry(name: "Profile.mobileprovision", content: [0x30]),
        ])))
        let failure = try await examineFailure(source)
        XCTAssertEqual(failure, ImportFailure.unsupportedLayout(.certificateMaterial))
        XCTAssertEqual(failure?.title, "Certificates, Not Packages")
        XCTAssertEqual(failure?.recovery, .chooseAnotherFile)
    }

    func testAnArchiveEntryAboveTheCeilingIsRefusedBeforeExtraction() async throws {
        let oversized = NestedPackageCandidate(
            path: makePath("Huge.ipa"),
            byteCount: ImportPreflight.maximumCandidateByteCount + 1,
            compressedByteCount: 10
        )
        do {
            _ = try await makeWorkflow().stage(
                .archiveEntry(container: ArtifactIdentifier(), candidate: oversized),
                fileName: "Huge.ipa",
                as: ArtifactIdentifier(),
                reporting: nil
            )
            XCTFail("Expected the entry to be refused.")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.category, .unsupportedInput)
        }
        XCTAssertTrue(stagedFiles().isEmpty)
    }

    // MARK: - Storage

    func testInsufficientStorageRefusesBeforeAnythingIsCopied() async throws {
        let source = writeSource("Example.ipa", ImportHubFixtures.package())
        do {
            _ = try await makeWorkflow(capacity: 1_000).stage(.document(source), fileName: "Example.ipa", as: ArtifactIdentifier(), reporting: nil)
            XCTFail("Expected the copy to be refused.")
        } catch let failure as ImportFailure {
            XCTAssertEqual(failure.recovery, .freeStorage)
            XCTAssertTrue(failure.isRetryable)
        }
        XCTAssertTrue(stagedFiles().isEmpty)
    }

    // MARK: - Conflicts and admission

    func testANewerVersionSuggestsReplacingAndReplacingRemovesOnlyTheEntriesShown() async throws {
        let original = try await importPackage(ImportHubFixtures.package(version: "1.2", build: "34"), named: "v12.ipa")

        let workflow = makeWorkflow()
        let prepared = try await prepare(writeSource("v13.ipa", ImportHubFixtures.package(version: "1.3", build: "40")), with: workflow)
        let conflict = try XCTUnwrap(prepared.conflict)
        XCTAssertEqual(conflict.relation, .newerVersion)
        XCTAssertEqual(conflict.suggestion, .replaceExisting)
        XCTAssertEqual(conflict.existingRecords.map(\.id), [original.id])
        XCTAssertEqual(conflict.comparedRecord.id, original.id)

        // An entry added after the user reviewed the conflict is not part of
        // what they agreed to replace.
        let later = try await importPackage(ImportHubFixtures.package(version: "1.1", build: "20"), named: "v11.ipa")

        let settlement = try await workflow.admit(prepared, resolution: .replaceExisting, reporting: nil)

        XCTAssertEqual(settlement.kind, .replaced)
        XCTAssertEqual(settlement.replacedRecords.map(\.id), [original.id])
        XCTAssertTrue(settlement.retainedRecords.isEmpty)
        let newRecord = try XCTUnwrap(settlement.record)
        let all = try await records.allRecords()
        XCTAssertEqual(Set(all.map(\.id)), [later.id, newRecord.id])
    }

    func testIdenticalContentIsSuggestedToBeSkipped() async throws {
        let content = ImportHubFixtures.package()
        _ = try await importPackage(content, named: "First.ipa")

        let prepared = try await prepare(writeSource("Again.ipa", content))

        XCTAssertEqual(prepared.conflict?.relation, .identicalContent)
        XCTAssertEqual(prepared.conflict?.suggestion, .skip)
    }

    func testKeepingBothStoresASecondEntry() async throws {
        let content = ImportHubFixtures.package()
        let first = try await importPackage(content, named: "First.ipa")
        let workflow = makeWorkflow()
        let prepared = try await prepare(writeSource("Again.ipa", content), with: workflow)

        let settlement = try await workflow.admit(prepared, resolution: .keepBoth, reporting: nil)

        XCTAssertEqual(settlement.kind, .keptBoth)
        let stored = try await records.allRecords()
        XCTAssertEqual(stored.count, 2)
        XCTAssertTrue(stored.contains { $0.id == first.id })
    }

    func testSkippingStoresNothingAndDiscardsTheWorkingCopy() async throws {
        _ = try await importPackage(ImportHubFixtures.package(version: "1.0"), named: "Old.ipa")
        let workflow = makeWorkflow()
        let prepared = try await prepare(writeSource("New.ipa", ImportHubFixtures.package(version: "2.0")), with: workflow)

        let settlement = try await workflow.admit(prepared, resolution: .skip, reporting: nil)

        XCTAssertEqual(settlement.kind, .skipped)
        let stored = try await records.allRecords()
        XCTAssertEqual(stored.count, 1)
        XCTAssertTrue(stagedFiles().isEmpty)
    }

    func testAnUnresolvedConflictIsNeverStored() async throws {
        _ = try await importPackage(ImportHubFixtures.package(version: "1.0", build: "1"), named: "Existing.ipa")
        let workflow = makeWorkflow()
        let prepared = try await prepare(writeSource("Rebuild.ipa", ImportHubFixtures.package(version: "1.0", build: "1", extraBundleEntries: [
            ZipFixtureBuilder.Entry(name: "Payload/Example.app/Extra", content: [0x07]),
        ])), with: workflow)
        XCTAssertEqual(prepared.conflict?.relation, .sameVersion)

        do {
            _ = try await workflow.admit(prepared, resolution: nil, reporting: nil)
            XCTFail("An unresolved conflict must not be stored.")
        } catch {
            // Expected.
        }
        let stored = try await records.allRecords()
        XCTAssertEqual(stored.count, 1)
        XCTAssertTrue(stagedFiles().isEmpty)
    }
}
