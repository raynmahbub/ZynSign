import XCTest
@testable import ZynSign

/// Tests for the nested-code discovery use case.
///
/// The use case is exercised over the real library with in-memory stores, a
/// synthetic container, and the real read-only Mach-O parser, so what the
/// tests assert is what the application layer actually produces: the plan a
/// recorded application yields, the entries the container is asked for, the
/// typed failure a rejected bundle becomes, and the fact that nothing on the
/// path reads a profile, writes a byte, or signs anything.
final class NestedCodeDiscoveryInspectionTests: XCTestCase {

    private let bundleName = "Example.app"
    private var records: InMemoryApplicationRecordStore!
    private var artifacts: SyntheticLibraryArtifactStore!
    private var library: ApplicationLibrary!

    private var bundleRoot: String { "\(IPALayout.payloadDirectoryName)/\(bundleName)" }

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

    // MARK: - Helpers

    /// The bytes of a minimal, structurally valid Mach-O image.
    private var machOBytes: Data { Data(MachOFixtures.thin()) }

    @discardableResult
    private func recordAvailableApplication(executableName: String? = "Example") async throws -> ApplicationRecord {
        let content = Data(repeating: 0x5A, count: 2_048)
        let artifactID = ArtifactIdentifier()
        artifacts.hold(content, as: artifactID)
        let record = LibraryFixtures.record(
            executableName: executableName,
            artifact: LibraryFixtures.reference(to: content, artifactID: artifactID)
        )
        try await records.insert(record)
        return record
    }

    private func inspection(reading reader: any ArchiveReader) -> NestedCodeDiscoveryInspection {
        NestedCodeDiscoveryInspection(
            library: library,
            readerProvider: SyntheticArchiveReaderProvider.providing(reader)
        )
    }

    private func inspection(with provider: any ArtifactArchiveReaderProvider) -> NestedCodeDiscoveryInspection {
        NestedCodeDiscoveryInspection(library: library, readerProvider: provider)
    }

    private func capturedError(
        _ operation: () async throws -> NestedCodeSigningPlan,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> any Error {
        do {
            _ = try await operation()
        } catch {
            return error
        }
        XCTFail("Expected discovery to fail.", file: file, line: line)
        throw NoErrorCaptured()
    }

    private struct NoErrorCaptured: Error {}

    /// The entry table of a package holding an application with its
    /// information file, an embedded profile, its executable, and one
    /// framework.
    private func applicationTable() -> [ArchiveEntry] {
        NestedCodeFixtures.packageTable(
            bundleName: bundleName,
            entries: [
                makeEntry("\(bundleRoot)/Info.plist", uncompressedSize: 640),
                makeEntry("\(bundleRoot)/embedded.mobileprovision", uncompressedSize: 8_000),
                makeEntry("\(bundleRoot)/Example", uncompressedSize: machOBytes.count),
                makeEntry("\(bundleRoot)/Frameworks", kind: .directory),
                makeEntry("\(bundleRoot)/Frameworks/Frame.framework", kind: .directory),
                makeEntry("\(bundleRoot)/Frameworks/Frame.framework/Info.plist", uncompressedSize: 512),
                makeEntry("\(bundleRoot)/Frameworks/Frame.framework/Frame", uncompressedSize: machOBytes.count),
            ]
        )
    }

    /// The content of the entries whose content discovery may ask for, plus a
    /// profile it must never ask for.
    ///
    /// The framework declares an identifier of its own, because a nested
    /// component that declared the application's identifier would contradict
    /// the application's own identity and is refused as such.
    private func applicationContent() -> [String: Data] {
        [
            "\(bundleRoot)/Info.plist": Data(ZipFixtureBuilder.syntheticPlist),
            "\(bundleRoot)/embedded.mobileprovision": Data(repeating: 0x11, count: 8_000),
            "\(bundleRoot)/Example": machOBytes,
            "\(bundleRoot)/Frameworks/Frame.framework/Info.plist": plist(
                bundleIdentifier: "com.example.synthetic.frame",
                executable: "Frame"
            ),
            "\(bundleRoot)/Frameworks/Frame.framework/Frame": machOBytes,
        ]
    }

    /// The bytes of a synthetic information file declaring the supplied values.
    private func plist(bundleIdentifier: String, executable: String? = nil) -> Data {
        var body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
          <key>CFBundleIdentifier</key><string>\(bundleIdentifier)</string>

        """
        if let executable {
            body += "  <key>CFBundleExecutable</key><string>\(executable)</string>\n"
        }
        body += "</dict></plist>\n"
        return Data(body.utf8)
    }

    // MARK: - Success

    func testDiscoversTheNestedCodeOfAnAvailableRecord() async throws {
        let record = try await recordAvailableApplication()
        let reader = SyntheticArchiveReader(
            entryTable: applicationTable(),
            contentByPath: applicationContent()
        )

        let plan = try await inspection(reading: reader).discoverNestedCode(recordWithID: record.id)

        XCTAssertEqual(plan.root.id.location, makeBundlePath(""))
        XCTAssertEqual(plan.mainExecutablePath, makeBundlePath("Example"))
        XCTAssertEqual(plan.root.status, .established)
        XCTAssertEqual(plan.nestedItems.map(\.kind), [.framework])
        XCTAssertEqual(
            plan.orderedItemIDs.map(\.description),
            ["framework:Frameworks/Frame.framework", "application"]
        )
        XCTAssertEqual(plan.steps.map(\.order), [1, 2])
        XCTAssertTrue(plan.isComplete)
        XCTAssertEqual(plan.root.identity?.bundleIdentifier?.rawValue, record.bundleIdentifier.rawValue)
        XCTAssertEqual(reader.closeCount, 1)
    }

    /// The container is asked for the candidates and nothing else: not the
    /// application's information file, not the embedded profile, and not any
    /// entry that is not a code location.
    func testReadsOnlyTheCandidateLocations() async throws {
        let record = try await recordAvailableApplication()
        let reader = SyntheticArchiveReader(
            entryTable: applicationTable(),
            contentByPath: applicationContent()
        )

        _ = try await inspection(reading: reader).discoverNestedCode(recordWithID: record.id)

        XCTAssertEqual(
            reader.requestedPaths,
            [
                makePath("\(bundleRoot)/Example"),
                makePath("\(bundleRoot)/Frameworks/Frame.framework/Info.plist"),
                makePath("\(bundleRoot)/Frameworks/Frame.framework/Frame"),
            ]
        )
        XCTAssertFalse(
            reader.requestedPaths.contains(makePath("\(bundleRoot)/embedded.mobileprovision")),
            "A provisioning profile must never be used to discover nested code."
        )
        XCTAssertFalse(reader.requestedPaths.contains(makePath("\(bundleRoot)/Info.plist")))
    }

    /// Discovery reads and describes; it does not modify the artifact, and it
    /// cannot sign anything: no signing use case is reachable from here.
    func testTheArtifactIsUnchangedByDiscovery() async throws {
        let content = Data(repeating: 0x5A, count: 2_048)
        let artifactID = ArtifactIdentifier()
        artifacts.hold(content, as: artifactID)
        let record = LibraryFixtures.record(
            executableName: "Example",
            artifact: LibraryFixtures.reference(to: content, artifactID: artifactID)
        )
        try await records.insert(record)
        let reader = SyntheticArchiveReader(
            entryTable: applicationTable(),
            contentByPath: applicationContent()
        )

        _ = try await inspection(reading: reader).discoverNestedCode(recordWithID: record.id)

        XCTAssertEqual(artifacts.heldContent(for: artifactID), content)
        XCTAssertEqual(artifacts.adopted, [], "Discovery must not adopt, stage, or move an artifact.")
        XCTAssertEqual(artifacts.removed, [])
    }

    // MARK: - Rejections carry their reason

    func testARejectedBundleBecomesATypedErrorWithItsReason() async throws {
        let record = try await recordAvailableApplication()
        var table = applicationTable()
        // A link where an executable belongs: discovery refuses rather than
        // following it.
        table.removeAll { $0.path == makePath("\(bundleRoot)/Frameworks/Frame.framework/Frame") }
        table.append(makeEntry("\(bundleRoot)/Frameworks/Frame.framework/Frame", kind: .symbolicLink))
        let reader = SyntheticArchiveReader(entryTable: table, contentByPath: applicationContent())

        let error = try await capturedError {
            try await self.inspection(reading: reader).discoverNestedCode(recordWithID: record.id)
        }

        let typed = try XCTUnwrap(error as? ZynSignError)
        XCTAssertEqual(typed.nestedCodeFailure, .pathSafetyViolation)
        XCTAssertEqual(typed.category, .invalidInput)
        XCTAssertEqual(typed.userMessage, NestedCodeFailure.pathSafetyViolation.userMessage)
        XCTAssertTrue(typed.diagnosticDetail?.contains("Frameworks/Frame.framework/Frame") == true)
        XCTAssertNil(typed.underlyingError)
        XCTAssertEqual(reader.closeCount, 1)
    }

    func testUnsupportedNestedCodeBecomesTheMatchingReason() async throws {
        let record = try await recordAvailableApplication()
        var table = applicationTable()
        table.append(makeEntry("\(bundleRoot)/PlugIns", kind: .directory))
        table.append(makeEntry("\(bundleRoot)/PlugIns/Nested.app", kind: .directory))
        let reader = SyntheticArchiveReader(entryTable: table, contentByPath: applicationContent())

        let error = try await capturedError {
            try await self.inspection(reading: reader).discoverNestedCode(recordWithID: record.id)
        }

        let typed = try XCTUnwrap(error as? ZynSignError)
        XCTAssertEqual(typed.nestedCodeFailure, .unsupportedNestedCode)
        XCTAssertEqual(typed.category, .unsupportedInput)
    }

    // MARK: - Library and container failures

    func testAMissingRecordFailsWithTheLibraryReason() async throws {
        let reader = SyntheticArchiveReader(entryTable: applicationTable())

        let error = try await capturedError {
            try await self.inspection(reading: reader).discoverNestedCode(recordWithID: ApplicationRecordIdentifier())
        }

        let typed = try XCTUnwrap(error as? ZynSignError)
        XCTAssertEqual(typed.userMessage, ZynSignError.libraryRecordNotFound().userMessage)
        XCTAssertTrue(reader.requestedPaths.isEmpty)
    }

    func testAMissingArtifactFailsWithTheArtifactReason() async throws {
        let content = Data(repeating: 0x5A, count: 2_048)
        let artifactID = ArtifactIdentifier()
        artifacts.hold(content, as: artifactID)
        let record = LibraryFixtures.record(
            executableName: "Example",
            artifact: LibraryFixtures.reference(to: content, artifactID: artifactID)
        )
        try await records.insert(record)
        artifacts.drop(artifactID)
        let reader = SyntheticArchiveReader(entryTable: applicationTable())

        let error = try await capturedError {
            try await self.inspection(reading: reader).discoverNestedCode(recordWithID: record.id)
        }

        let typed = try XCTUnwrap(error as? ZynSignError)
        XCTAssertEqual(typed.userMessage, ZynSignError.bundleArtifactMissing().userMessage)
        XCTAssertTrue(reader.requestedPaths.isEmpty)
    }

    func testAnInconsistentArtifactFailsWithTheArtifactReason() async throws {
        let content = Data(repeating: 0x5A, count: 2_048)
        let artifactID = ArtifactIdentifier()
        artifacts.hold(content, as: artifactID)
        let record = LibraryFixtures.record(
            executableName: "Example",
            artifact: LibraryFixtures.reference(to: content, artifactID: artifactID)
        )
        try await records.insert(record)
        artifacts.truncate(artifactID, to: 16)
        let reader = SyntheticArchiveReader(entryTable: applicationTable())

        let error = try await capturedError {
            try await self.inspection(reading: reader).discoverNestedCode(recordWithID: record.id)
        }

        let typed = try XCTUnwrap(error as? ZynSignError)
        XCTAssertEqual(typed.userMessage, ZynSignError.bundleArtifactInconsistent().userMessage)
    }

    func testAPackageWithoutAnApplicationBundleFails() async throws {
        let record = try await recordAvailableApplication()
        let reader = SyntheticArchiveReader(entryTable: [makeEntry("Payload", kind: .directory)])

        let error = try await capturedError {
            try await self.inspection(reading: reader).discoverNestedCode(recordWithID: record.id)
        }

        let typed = try XCTUnwrap(error as? ZynSignError)
        XCTAssertEqual(typed.userMessage, ZynSignError.missingApplicationBundle().userMessage)
    }

    func testAPackageWithSeveralApplicationBundlesFails() async throws {
        let record = try await recordAvailableApplication()
        let reader = SyntheticArchiveReader(entryTable: [
            makeEntry("Payload", kind: .directory),
            makeEntry("Payload/First.app", kind: .directory),
            makeEntry("Payload/Second.app", kind: .directory),
        ])

        let error = try await capturedError {
            try await self.inspection(reading: reader).discoverNestedCode(recordWithID: record.id)
        }

        let typed = try XCTUnwrap(error as? ZynSignError)
        XCTAssertEqual(typed.userMessage, ZynSignError.ambiguousArtifact().userMessage)
    }

    func testAnUnreadableContainerIsNormalisedIntoOneTypedFailure() async throws {
        let record = try await recordAvailableApplication()
        let reader = SyntheticArchiveReader(entryTable: applicationTable(), failure: .entryTableUnreadable)

        let error = try await capturedError {
            try await self.inspection(reading: reader).discoverNestedCode(recordWithID: record.id)
        }

        let typed = try XCTUnwrap(error as? ZynSignError)
        XCTAssertEqual(typed.userMessage, ZynSignError.unreadableArtifact().userMessage)
        XCTAssertNil(typed.underlyingError, "A container the archive boundary already classified stays as it is.")
        XCTAssertEqual(reader.closeCount, 1)
    }

    func testAProviderFailureIsNormalisedIntoOneTypedFailure() async throws {
        let record = try await recordAvailableApplication()
        let provider = SyntheticArchiveReaderProvider.failing(
            with: NSError(domain: "synthetic", code: 1)
        )

        let error = try await capturedError {
            try await self.inspection(with: provider).discoverNestedCode(recordWithID: record.id)
        }

        let typed = try XCTUnwrap(error as? ZynSignError)
        XCTAssertEqual(typed.userMessage, ZynSignError.bundleInspectionFailure().userMessage)
        XCTAssertNotNil(typed.underlyingError)
    }

    // MARK: - The plan is descriptive data

    /// A plan says what it observed and never more: an unsigned binary is
    /// recorded as carrying no signature, and no state anywhere claims the
    /// application is signed, trusted, authorized, or installable.
    func testAnUnsignedExecutableIsRecordedAsAbsentRatherThanRejected() async throws {
        let record = try await recordAvailableApplication()
        let reader = SyntheticArchiveReader(
            entryTable: applicationTable(),
            contentByPath: applicationContent()
        )

        let plan = try await inspection(reading: reader).discoverNestedCode(recordWithID: record.id)

        XCTAssertEqual(plan.root.existingSignature, .absent)
        XCTAssertEqual(plan.nestedItems.first?.existingSignature, .absent)
        XCTAssertTrue(plan.isComplete)
    }
}
