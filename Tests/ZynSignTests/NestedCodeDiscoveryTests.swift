import XCTest
@testable import ZynSign

/// Tests for nested-code discovery.
///
/// Discovery is a pure rule over an entry table plus one bounded inspection
/// per candidate, so every case here states a bundle structure literally and
/// the observations a content source would produce for it, then asserts what
/// the rule concluded: which locations are code, which are not, which cannot
/// be established, and in which order the established ones would have to be
/// finalized.
///
/// Three properties are asserted repeatedly, because they are the ones a
/// mistake would quietly break: nothing is read that discovery did not name as
/// a candidate, nothing is classified as code without Mach-O structure, and
/// anything ambiguous is reported rather than resolved.
final class NestedCodeDiscoveryTests: XCTestCase {

    private let bundleName = "Example.app"

    private var bundleRoot: String { "\(IPALayout.payloadDirectoryName)/\(bundleName)" }

    // MARK: - Helpers

    /// One entry inside the application bundle.
    private func entry(
        _ name: String,
        kind: ArchiveEntryKind = .regularFile,
        size: Int = 0,
        bundle: String? = nil
    ) -> ArchiveEntry {
        makeEntry(
            "\(IPALayout.payloadDirectoryName)/\(bundle ?? bundleName)/\(name)",
            kind: kind,
            uncompressedSize: size
        )
    }

    /// The package location of one entry inside the application bundle.
    private func archivePath(_ name: String) -> ArchivePath {
        makePath("\(bundleRoot)/\(name)")
    }

    /// The package location of one entry inside a nested container.
    private func archivePath(_ name: String, in container: String) -> ArchivePath {
        makePath("\(bundleRoot)/\(container)/\(name)")
    }

    private func limits(
        items: Int = 512,
        binaryReads: Int = 512,
        informationReads: Int = 512,
        binaryBytes: Int = 32 * 1_024 * 1_024,
        informationBytes: Int = 1_024 * 1_024,
        containerDepth: Int = 4,
        observationDepth: Int = 2,
        visitedDirectories: Int = 4_096,
        unsupportedItems: Int = 256,
        ambiguityCandidates: Int = 8
    ) -> NestedCodeDiscoveryLimits {
        NestedCodeDiscoveryLimits(
            maximumItems: items,
            maximumBinaryReads: binaryReads,
            maximumBundleInformationReads: informationReads,
            maximumBinaryBytes: binaryBytes,
            maximumBundleInformationBytes: informationBytes,
            maximumContainerDepth: containerDepth,
            maximumDirectoryObservationDepth: observationDepth,
            maximumVisitedDirectories: visitedDirectories,
            maximumUnsupportedItems: unsupportedItems,
            maximumAmbiguityCandidates: ambiguityCandidates
        )
    }

    private func discover(
        _ entryTable: [ArchiveEntry],
        request: NestedCodeDiscoveryRequest? = nil,
        limits: NestedCodeDiscoveryLimits = .default,
        source: SyntheticNestedCodeInspectionSource
    ) -> NestedCodeDiscoveryOutcome {
        NestedCodeDiscovery.discover(
            entryTable: entryTable,
            request: request ?? NestedCodeFixtures.request(bundleName: bundleName),
            limits: limits,
            source: source
        )
    }

    private func plan(
        _ entryTable: [ArchiveEntry],
        request: NestedCodeDiscoveryRequest? = nil,
        limits: NestedCodeDiscoveryLimits = .default,
        source: SyntheticNestedCodeInspectionSource,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> NestedCodeSigningPlan {
        switch discover(entryTable, request: request, limits: limits, source: source) {
        case .plan(let plan):
            return plan
        case .rejected(let error):
            XCTFail("Expected a plan, got \(error.description).", file: file, line: line)
            throw NoPlanProduced()
        }
    }

    private func rejection(
        _ entryTable: [ArchiveEntry],
        request: NestedCodeDiscoveryRequest? = nil,
        limits: NestedCodeDiscoveryLimits = .default,
        source: SyntheticNestedCodeInspectionSource,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> NestedCodeDiscoveryError {
        switch discover(entryTable, request: request, limits: limits, source: source) {
        case .rejected(let error):
            return error
        case .plan(let plan):
            XCTFail("Expected a rejection, got a plan with \(plan.items.count) items.", file: file, line: line)
            throw NoPlanProduced()
        }
    }

    private struct NoPlanProduced: Error {}

    /// A table for `Example.app` holding its information file and main
    /// executable, plus the supplied entries.
    private func basicTable(_ entries: [ArchiveEntry] = []) -> [ArchiveEntry] {
        NestedCodeFixtures.packageTable(
            bundleName: bundleName,
            entries: [entry("Info.plist", size: 640), entry("Example", size: 8_192)] + entries
        )
    }

    // MARK: - The basic application

    func testAnApplicationWithOnlyItsMainExecutableProducesOneStep() throws {
        let source = SyntheticNestedCodeInspectionSource(binaries: [
            archivePath("Example").rawValue: NestedCodeFixtures.unsignedMachO(),
        ])

        let plan = try plan(basicTable(), source: source)

        XCTAssertEqual(plan.items.count, 1)
        XCTAssertEqual(plan.nestedItems.count, 0)
        XCTAssertEqual(plan.root.status, .established)
        XCTAssertEqual(plan.mainExecutablePath, makeBundlePath("Example"))
        XCTAssertEqual(plan.root.executableProvenance, .declared)
        XCTAssertEqual(plan.root.identity?.bundleIdentifier?.rawValue, "com.example.synthetic")
        XCTAssertEqual(plan.root.bundleInformation.identity?.shortVersionString, "1.2")
        XCTAssertEqual(plan.steps, [NestedCodeSigningStep(order: 1, itemID: plan.rootItemID)])
        XCTAssertNil(plan.root.parentID)
        XCTAssertTrue(plan.isComplete)
        XCTAssertTrue(plan.unsupportedItems.isEmpty)
        XCTAssertTrue(plan.diagnostics.isEmpty)
    }

    /// The application's own information file is not read again: the metadata
    /// stage already read it, and the record carries what it declared.
    func testTheApplicationsOwnInformationFileIsNotReadAgain() throws {
        let source = SyntheticNestedCodeInspectionSource(binaries: [
            archivePath("Example").rawValue: NestedCodeFixtures.unsignedMachO(),
        ])

        _ = try plan(basicTable(), source: source)

        XCTAssertTrue(source.requestedInformationPaths.isEmpty)
        XCTAssertEqual(source.requestedBinaryPaths, [archivePath("Example")])
    }

    func testTheApplicationExecutableConventionIsRecordedAsInferredWhenNothingDeclaresIt() throws {
        let source = SyntheticNestedCodeInspectionSource(binaries: [
            archivePath("Example").rawValue: NestedCodeFixtures.unsignedMachO(),
        ])

        let plan = try plan(
            basicTable(),
            request: NestedCodeFixtures.request(bundleName: bundleName, executableName: nil),
            source: source
        )

        XCTAssertEqual(plan.root.executableProvenance, .bundleNameConvention)
        XCTAssertEqual(plan.mainExecutablePath, makeBundlePath("Example"))
        let codes = plan.diagnostics.map(\.code)
        XCTAssertTrue(codes.contains(.executableNameInferred))
    }

    // MARK: - Frameworks, extensions, and loose libraries

    func testOneFrameworkIsSignedBeforeTheApplication() throws {
        let source = SyntheticNestedCodeInspectionSource(
            binaries: [
                archivePath("Example").rawValue: NestedCodeFixtures.unsignedMachO(),
                archivePath("Frame", in: "Frameworks/Frame.framework").rawValue: NestedCodeFixtures.signedMachO(),
            ],
            information: [
                archivePath("Frameworks/Frame.framework").rawValue: .read(
                    NestedCodeFixtures.identity(
                        bundleIdentifier: "com.example.synthetic.frame",
                        executableName: "Frame"
                    )
                ),
            ]
        )
        let table = basicTable([
            entry("Frameworks", kind: .directory),
            entry("Frameworks/Frame.framework", kind: .directory),
            entry("Frameworks/Frame.framework/Info.plist", size: 512),
            entry("Frameworks/Frame.framework/Frame", size: 4_096),
        ])

        let plan = try plan(table, source: source)

        XCTAssertEqual(plan.nestedItems.count, 1)
        let framework = try XCTUnwrap(plan.nestedItems.first)
        XCTAssertEqual(framework.kind, .framework)
        XCTAssertEqual(framework.id.location, makeBundlePath("Frameworks/Frame.framework"))
        XCTAssertEqual(framework.status, .established)
        XCTAssertEqual(framework.existingSignature, .structurallyParsed(signedSliceCount: 1))
        XCTAssertEqual(framework.parentID, plan.rootItemID)
        XCTAssertEqual(framework.identity?.bundleIdentifier?.rawValue, "com.example.synthetic.frame")
        XCTAssertEqual(plan.orderedItemIDs, [framework.id, plan.rootItemID])
        XCTAssertEqual(plan.steps.map(\.order), [1, 2])
        XCTAssertEqual(
            plan.dependencies,
            [NestedCodeDependency(nestedCode: framework.id, container: plan.rootItemID)]
        )
        XCTAssertTrue(plan.isComplete)
        XCTAssertEqual(source.requestedInformationPaths, [archivePath("Frameworks/Frame.framework")])
    }

    func testSeveralFrameworksOrderByTheirBundleRelativeLocations() throws {
        let first = archivePath("Frameworks/First.framework/First")
        let second = archivePath("Frameworks/Second.framework/Second")
        let source = SyntheticNestedCodeInspectionSource(
            binaries: [
                archivePath("Example").rawValue: NestedCodeFixtures.unsignedMachO(),
                first.rawValue: NestedCodeFixtures.unsignedMachO(),
                second.rawValue: NestedCodeFixtures.unsignedMachO(),
            ],
            information: [
                archivePath("Frameworks/First.framework").rawValue: .read(
                    NestedCodeFixtures.identity(bundleIdentifier: "com.example.synthetic.first", executableName: "First")
                ),
                archivePath("Frameworks/Second.framework").rawValue: .read(
                    NestedCodeFixtures.identity(bundleIdentifier: "com.example.synthetic.second", executableName: "Second")
                ),
            ]
        )
        let table = basicTable([
            entry("Frameworks", kind: .directory),
            entry("Frameworks/First.framework", kind: .directory),
            entry("Frameworks/First.framework/Info.plist"),
            entry("Frameworks/First.framework/First"),
            entry("Frameworks/Second.framework", kind: .directory),
            entry("Frameworks/Second.framework/Info.plist"),
            entry("Frameworks/Second.framework/Second"),
        ])

        let plan = try plan(table, source: source)

        XCTAssertEqual(
            plan.orderedItemIDs.map(\.description),
            [
                "framework:Frameworks/First.framework",
                "framework:Frameworks/Second.framework",
                "application",
            ]
        )
        XCTAssertEqual(plan.orderedItemIDs.last, plan.rootItemID)
    }

    func testAnApplicationExtensionIsSignedBeforeTheApplication() throws {
        let source = SyntheticNestedCodeInspectionSource(
            binaries: [
                archivePath("Example").rawValue: NestedCodeFixtures.unsignedMachO(),
                archivePath("Widget", in: "PlugIns/Widget.appex").rawValue: NestedCodeFixtures.unsignedMachO(),
            ],
            information: [
                archivePath("PlugIns/Widget.appex").rawValue: .read(
                    NestedCodeFixtures.identity(
                        bundleIdentifier: "com.example.synthetic.widget",
                        executableName: "Widget"
                    )
                ),
            ]
        )
        let table = basicTable([
            entry("PlugIns", kind: .directory),
            entry("PlugIns/Widget.appex", kind: .directory),
            entry("PlugIns/Widget.appex/Info.plist"),
            entry("PlugIns/Widget.appex/Widget"),
        ])

        let plan = try plan(table, source: source)

        let widget = try XCTUnwrap(plan.nestedItems.first)
        XCTAssertEqual(widget.kind, .applicationExtension)
        XCTAssertEqual(plan.orderedItemIDs, [widget.id, plan.rootItemID])
    }

    func testAnExtensionInTheExtensionsDirectoryIsSignedBeforeTheApplication() throws {
        let source = SyntheticNestedCodeInspectionSource(
            binaries: [
                archivePath("Example").rawValue: NestedCodeFixtures.unsignedMachO(),
                archivePath("Widget", in: "Extensions/Widget.appex").rawValue: NestedCodeFixtures.unsignedMachO(),
            ],
            information: [
                archivePath("Extensions/Widget.appex").rawValue: .read(
                    NestedCodeFixtures.identity(
                        bundleIdentifier: "com.example.synthetic.widget",
                        executableName: "Widget"
                    )
                ),
            ]
        )
        let table = basicTable([
            entry("Extensions", kind: .directory),
            entry("Extensions/Widget.appex", kind: .directory),
            entry("Extensions/Widget.appex/Info.plist"),
            entry("Extensions/Widget.appex/Widget"),
        ])

        let plan = try plan(table, source: source)

        let widget = try XCTUnwrap(plan.nestedItems.first)
        XCTAssertEqual(widget.kind, .applicationExtension)
        XCTAssertEqual(plan.orderedItemIDs, [widget.id, plan.rootItemID])
    }

    func testALooseMachOFileInFrameworksIsCodeAndIsSignedFirst() throws {
        let library = archivePath("Frameworks/Loose.dylib")
        let source = SyntheticNestedCodeInspectionSource(binaries: [
            archivePath("Example").rawValue: NestedCodeFixtures.unsignedMachO(),
            library.rawValue: NestedCodeFixtures.unsignedMachO(),
        ])
        let table = basicTable([
            entry("Frameworks", kind: .directory),
            entry("Frameworks/Loose.dylib"),
        ])

        let plan = try plan(table, source: source)

        let item = try XCTUnwrap(plan.nestedItems.first)
        XCTAssertEqual(item.kind, .dynamicLibrary)
        XCTAssertEqual(item.executablePath, makeBundlePath("Frameworks/Loose.dylib"))
        XCTAssertEqual(item.bundleInformation, .notPresent)
        XCTAssertEqual(plan.orderedItemIDs, [item.id, plan.rootItemID])
        XCTAssertTrue(plan.isComplete)
    }

    /// A regular file directly inside `Frameworks` is a candidate, and its
    /// bytes decide: a file named like code that is not Mach-O is not code,
    /// and a file named like a resource that is Mach-O is.
    func testTheBytesAtACodeLocationDecideWhetherAFileIsCode() throws {
        let source = SyntheticNestedCodeInspectionSource(binaries: [
            archivePath("Example").rawValue: NestedCodeFixtures.unsignedMachO(),
            archivePath("Frameworks/Unnamed.bin").rawValue: NestedCodeFixtures.notMachO,
            archivePath("Frameworks/Data.bin").rawValue: NestedCodeFixtures.unsignedMachO(),
        ])
        let table = basicTable([
            entry("Frameworks", kind: .directory),
            entry("Frameworks/Unnamed.bin"),
            entry("Frameworks/Data.bin"),
        ])

        let plan = try plan(table, source: source)

        XCTAssertEqual(plan.nestedItems.map(\.id.location.rawValue), ["Frameworks/Data.bin"])
        XCTAssertTrue(plan.diagnostics.contains {
            $0.code == .unclassifiedEntryInCodeLocation && $0.path == makeBundlePath("Frameworks/Unnamed.bin")
        })
        XCTAssertEqual(
            Set(source.requestedBinaryPaths),
            [archivePath("Example"), archivePath("Frameworks/Unnamed.bin"), archivePath("Frameworks/Data.bin")]
        )
    }

    // MARK: - Nested containers

    func testANestedFrameworkOrdersBeforeItsHostFramework() throws {
        let innerPath = "Frameworks/Outer.framework/Frameworks/Inner.framework"
        let source = SyntheticNestedCodeInspectionSource(
            binaries: [
                archivePath("Example").rawValue: NestedCodeFixtures.unsignedMachO(),
                archivePath("Outer", in: "Frameworks/Outer.framework").rawValue: NestedCodeFixtures.unsignedMachO(),
                archivePath("Inner", in: innerPath).rawValue: NestedCodeFixtures.unsignedMachO(),
            ],
            information: [
                archivePath("Frameworks/Outer.framework").rawValue: .read(
                    NestedCodeFixtures.identity(bundleIdentifier: "com.example.synthetic.outer", executableName: "Outer")
                ),
                archivePath(innerPath).rawValue: .read(
                    NestedCodeFixtures.identity(bundleIdentifier: "com.example.synthetic.inner", executableName: "Inner")
                ),
            ]
        )
        let table = basicTable([
            entry("Frameworks", kind: .directory),
            entry("Frameworks/Outer.framework", kind: .directory),
            entry("Frameworks/Outer.framework/Info.plist"),
            entry("Frameworks/Outer.framework/Outer"),
            entry("Frameworks/Outer.framework/Frameworks", kind: .directory),
            entry("\(innerPath)", kind: .directory),
            entry("\(innerPath)/Info.plist"),
            entry("\(innerPath)/Inner"),
        ])

        let plan = try plan(table, source: source)

        XCTAssertEqual(
            plan.orderedItemIDs.map(\.description),
            ["framework:\(innerPath)", "framework:Frameworks/Outer.framework", "application"]
        )
        XCTAssertEqual(plan.nestedItems.count, 2)
    }

    func testAContainerWithoutInformationFileUsesTheBundleNameConvention() throws {
        let source = SyntheticNestedCodeInspectionSource(binaries: [
            archivePath("Example").rawValue: NestedCodeFixtures.unsignedMachO(),
            archivePath("Frame", in: "Frameworks/Frame.framework").rawValue: NestedCodeFixtures.unsignedMachO(),
        ])
        let table = basicTable([
            entry("Frameworks", kind: .directory),
            entry("Frameworks/Frame.framework", kind: .directory),
            entry("Frameworks/Frame.framework/Frame"),
        ])

        let plan = try plan(table, source: source)

        let framework = try XCTUnwrap(plan.nestedItems.first)
        XCTAssertEqual(framework.status, .established)
        XCTAssertEqual(framework.executableProvenance, .bundleNameConvention)
        XCTAssertEqual(framework.bundleInformation, .notPresent)
    }

    // MARK: - Ambiguity is reported, never resolved

    func testAFrameworkWithTwoPossibleExecutablesIsNotEstablished() throws {
        let container = "Frameworks/Frame.framework"
        let source = SyntheticNestedCodeInspectionSource(binaries: [
            archivePath("Example").rawValue: NestedCodeFixtures.unsignedMachO(),
        ])
        let table = basicTable([
            entry("Frameworks", kind: .directory),
            entry(container, kind: .directory),
            entry("\(container)/Alpha"),
            entry("\(container)/Beta"),
        ])

        let plan = try plan(table, source: source)

        let framework = try XCTUnwrap(plan.nestedItems.first)
        XCTAssertEqual(framework.status, .notEstablished(.ambiguousExecutable(["Alpha", "Beta"])))
        XCTAssertEqual(framework.executablePath, nil)
        XCTAssertFalse(plan.isComplete)
        XCTAssertTrue(plan.unsupportedItems.contains(
            NestedCodeUnsupportedItem(path: makeBundlePath(container), reason: .ambiguousExecutable)
        ))
        XCTAssertTrue(plan.diagnostics.contains {
            $0.code == .ambiguousExecutable && $0.severity == .warning
        })
        XCTAssertTrue(source.requestedBinaryPaths.isEmpty == false)
    }

    func testAnAmbiguousApplicationExecutableRejectsTheBundle() throws {
        let source = SyntheticNestedCodeInspectionSource()
        let table = NestedCodeFixtures.packageTable(
            bundleName: bundleName,
            entries: [entry("Info.plist"), entry("Alpha"), entry("Beta")]
        )

        let error = try rejection(
            table,
            request: NestedCodeFixtures.request(bundleName: bundleName, executableName: nil),
            source: source
        )

        XCTAssertEqual(error.reason, .ambiguousExecutable)
        XCTAssertEqual(error.reason.category, .ambiguousInput)
        XCTAssertTrue(error.detail.contains("Alpha"))
        XCTAssertTrue(source.requestedBinaryPaths.isEmpty, "Nothing is read to resolve an ambiguity.")
    }

    func testAnApplicationWithoutAnExecutableRejectsTheBundle() throws {
        let source = SyntheticNestedCodeInspectionSource()
        let table = NestedCodeFixtures.packageTable(bundleName: bundleName, entries: [entry("Info.plist")])

        let error = try rejection(table, source: source)

        XCTAssertEqual(error.reason, .invalidApplicationBundle)
        XCTAssertTrue(source.requestedBinaryPaths.isEmpty)
    }

    // MARK: - Detection

    func testANonMachOMainExecutableRejectsTheBundle() throws {
        let source = SyntheticNestedCodeInspectionSource(binaries: [
            archivePath("Example").rawValue: NestedCodeFixtures.notMachO,
        ])

        let error = try rejection(basicTable(), source: source)

        XCTAssertEqual(error.reason, .notMachO)
        XCTAssertEqual(error.reason.category, .invalidInput)
        XCTAssertEqual(error.path, makeBundlePath("Example"))
    }

    func testAMalformedMainExecutableRejectsTheBundle() throws {
        let source = SyntheticNestedCodeInspectionSource(binaries: [
            archivePath("Example").rawValue: NestedCodeFixtures.malformedMachO(),
        ])

        let error = try rejection(basicTable(), source: source)

        XCTAssertEqual(error.reason, .malformedMachO)
        XCTAssertTrue(error.detail.contains("malformedHeader"))
    }

    func testAnUnsupportedMainExecutableRejectsTheBundleAsUnsupportedInput() throws {
        let source = SyntheticNestedCodeInspectionSource(binaries: [
            archivePath("Example").rawValue: NestedCodeFixtures.unsupportedMachO(),
        ])

        let error = try rejection(basicTable(), source: source)

        XCTAssertEqual(error.reason, .unsupportedMachO)
        XCTAssertEqual(error.reason.category, .unsupportedInput)
    }

    func testAnUnreadableCandidateLeavesTheItemUnestablishedRatherThanCode() throws {
        let source = SyntheticNestedCodeInspectionSource(
            binaries: [
                archivePath("Example").rawValue: NestedCodeFixtures.unsignedMachO(),
                archivePath("Frame", in: "Frameworks/Frame.framework").rawValue: NestedCodeFixtures.unreadableBinary,
            ],
            information: [
                archivePath("Frameworks/Frame.framework").rawValue: .read(
                    NestedCodeFixtures.identity(bundleIdentifier: "com.example.synthetic.frame", executableName: "Frame")
                ),
            ]
        )
        let table = basicTable([
            entry("Frameworks", kind: .directory),
            entry("Frameworks/Frame.framework", kind: .directory),
            entry("Frameworks/Frame.framework/Info.plist"),
            entry("Frameworks/Frame.framework/Frame"),
        ])

        let plan = try plan(table, source: source)

        let framework = try XCTUnwrap(plan.nestedItems.first)
        XCTAssertEqual(framework.status, .notEstablished(.binaryUnreadable))
        XCTAssertEqual(framework.existingSignature, .notEvaluated)
        XCTAssertFalse(plan.isComplete)
        XCTAssertTrue(plan.unsupportedItems.contains(
            NestedCodeUnsupportedItem(path: makeBundlePath("Frameworks/Frame.framework"), reason: .binaryUnreadable)
        ))
    }

    /// A universal container is described as one item with one slice per
    /// architecture, and its signature state covers every slice.
    func testAUniversalCandidateKeepsItsContainerFormAndSliceCount() throws {
        let source = SyntheticNestedCodeInspectionSource(
            binaries: [
                archivePath("Example").rawValue: NestedCodeFixtures.unsignedMachO(),
                archivePath("Frame", in: "Frameworks/Frame.framework").rawValue: NestedCodeFixtures.signedMachO(isUniversal: true),
            ],
            information: [
                archivePath("Frameworks/Frame.framework").rawValue: .read(
                    NestedCodeFixtures.identity(bundleIdentifier: "com.example.synthetic.frame", executableName: "Frame")
                ),
            ]
        )
        let table = basicTable([
            entry("Frameworks", kind: .directory),
            entry("Frameworks/Frame.framework", kind: .directory),
            entry("Frameworks/Frame.framework/Info.plist"),
            entry("Frameworks/Frame.framework/Frame"),
        ])

        let plan = try plan(table, source: source)

        guard case .machO(let summary) = try XCTUnwrap(plan.nestedItems.first).binary else {
            return XCTFail("Expected an established Mach-O observation.")
        }
        XCTAssertEqual(summary?.container, .universal)
        XCTAssertEqual(summary?.architectureCount, 2)
        XCTAssertEqual(plan.nestedItems.first?.existingSignature, .structurallyParsed(signedSliceCount: 2))
    }

    // MARK: - Existing signatures

    func testExistingSignatureStatesAreRecordedWithoutBeingTrusted() throws {
        let container = "Frameworks/Frame.framework"
        let malformedState = MachOExistingCodeSignatureState.malformedCommand(
            MachOParsingError(.invalidLoadCommand, at: .codeSignatureCommand)
        )
        let unsupportedState = MachOExistingCodeSignatureState.malformedRegion(
            MachOParsingError(.unsupportedCodeDirectoryVersion, at: .codeDirectory, version: 0x30000)
        )
        let source = SyntheticNestedCodeInspectionSource(
            binaries: [
                archivePath("Example").rawValue: NestedCodeBinaryInspection(
                    observation: .machO(summary: NestedCodeFixtures.thinSummary()),
                    existingSignature: .failure(malformedState)
                ),
                archivePath("Frame", in: container).rawValue: NestedCodeBinaryInspection(
                    observation: .machO(summary: NestedCodeFixtures.thinSummary()),
                    existingSignature: .failure(unsupportedState)
                ),
            ],
            information: [
                archivePath(container).rawValue: .read(
                    NestedCodeFixtures.identity(bundleIdentifier: "com.example.synthetic.frame", executableName: "Frame")
                ),
            ]
        )
        let table = basicTable([
            entry("Frameworks", kind: .directory),
            entry(container, kind: .directory),
            entry("\(container)/Info.plist"),
            entry("\(container)/Frame"),
        ])

        let plan = try plan(table, source: source)

        XCTAssertEqual(plan.root.existingSignature, .malformed(malformedState))
        XCTAssertEqual(plan.nestedItems.first?.existingSignature, .unsupported(unsupportedState))
        // Malformed or unsupported signature data does not change what the
        // location is: the item is still established Mach-O code.
        XCTAssertEqual(plan.root.status, .established)
        XCTAssertEqual(plan.nestedItems.first?.status, .established)
        XCTAssertTrue(plan.isComplete)
    }

    // MARK: - Structure discovery refuses to traverse

    func testANestedApplicationBundleRejectsTheBundle() throws {
        let source = SyntheticNestedCodeInspectionSource()
        let table = basicTable([
            entry("PlugIns", kind: .directory),
            entry("PlugIns/Other.app", kind: .directory),
            entry("PlugIns/Other.app/Other"),
        ])

        let error = try rejection(table, source: source)

        XCTAssertEqual(error.reason, .unsupportedNestedCode)
        XCTAssertEqual(error.path, makeBundlePath("PlugIns/Other.app"))
    }

    func testACodeBundleOutsideItsSupportedLocationRejectsTheBundle() throws {
        let source = SyntheticNestedCodeInspectionSource()
        let table = basicTable([
            entry("PlugIns", kind: .directory),
            entry("PlugIns/Frame.framework", kind: .directory),
            entry("PlugIns/Frame.framework/Frame"),
        ])

        let error = try rejection(table, source: source)

        XCTAssertEqual(error.reason, .unsupportedNestedCode)
        XCTAssertEqual(error.path, makeBundlePath("PlugIns/Frame.framework"))
    }

    func testAnUnestablishedCodeBundleFormIsReportedAsUnsupported() throws {
        let source = SyntheticNestedCodeInspectionSource()
        let table = basicTable([
            entry("PlugIns", kind: .directory),
            entry("PlugIns/Service.xpc", kind: .directory),
            entry("PlugIns/Service.xpc/Service"),
        ])

        let error = try rejection(table, source: source)

        XCTAssertEqual(error.reason, .unsupportedNestedCode)
    }

    /// A loadable bundle and a resource bundle share a suffix, and only the
    /// content tells them apart. Discovery does not read one to find out, so
    /// the object is reported and the plan stays incomplete rather than
    /// claiming it either way.
    func testABundleOfAmbiguousRoleLeavesThePlanIncomplete() throws {
        let source = SyntheticNestedCodeInspectionSource(binaries: [
            archivePath("Example").rawValue: NestedCodeFixtures.unsignedMachO(),
        ])
        let table = basicTable([
            entry("Frameworks", kind: .directory),
            entry("Frameworks/Resources.bundle", kind: .directory),
            entry("Frameworks/Resources.bundle/Some.bin"),
        ])

        let plan = try plan(table, source: source)

        XCTAssertEqual(plan.nestedItems.count, 0)
        XCTAssertFalse(plan.isComplete)
        XCTAssertEqual(
            plan.unsupportedItems,
            [NestedCodeUnsupportedItem(path: makeBundlePath("Frameworks/Resources.bundle"), reason: .unsupportedStructure)]
        )
        XCTAssertTrue(plan.diagnostics.contains { $0.code == .structureNotTraversed })
        XCTAssertEqual(source.requestedBinaryPaths, [archivePath("Example")])
    }

    func testACodeShapedFileOutsideTheTraversedLocationsIsReported() throws {
        let source = SyntheticNestedCodeInspectionSource(binaries: [
            archivePath("Example").rawValue: NestedCodeFixtures.unsignedMachO(),
        ])
        let table = basicTable([
            entry("Resources", kind: .directory),
            entry("Resources/Extra.dylib"),
            entry("Resources/Notes.txt"),
        ])

        let plan = try plan(table, source: source)

        XCTAssertEqual(
            plan.unsupportedItems,
            [NestedCodeUnsupportedItem(path: makeBundlePath("Resources/Extra.dylib"), reason: .unsupportedStructure)]
        )
        XCTAssertTrue(plan.diagnostics.contains {
            $0.code == .unsupportedCodeLocation && $0.path == makeBundlePath("Resources/Extra.dylib")
        })
        XCTAssertFalse(plan.isComplete)
        // Nothing outside a code location is read, whatever it is named.
        XCTAssertEqual(source.requestedBinaryPaths, [archivePath("Example")])
        XCTAssertFalse(plan.diagnostics.contains { $0.path == makeBundlePath("Resources/Notes.txt") })
    }

    // MARK: - Path safety

    func testASymbolicLinkAtAnExecutableLocationRejectsTheBundle() throws {
        let source = SyntheticNestedCodeInspectionSource()
        let table = basicTable([
            entry("Frameworks", kind: .directory),
            entry("Frameworks/Frame.framework", kind: .directory),
            entry("Frameworks/Frame.framework/Frame", kind: .symbolicLink),
        ])

        let error = try rejection(table, source: source)

        XCTAssertEqual(error.reason, .pathSafetyViolation)
        XCTAssertEqual(error.path, makeBundlePath("Frameworks/Frame.framework/Frame"))
        XCTAssertTrue(source.requestedBinaryPaths.isEmpty, "A link is never followed, so its target is never read.")
    }

    func testASymbolicLinkInsideACodeDirectoryRejectsTheBundle() throws {
        let source = SyntheticNestedCodeInspectionSource()
        let table = basicTable([
            entry("Frameworks", kind: .directory),
            entry("Frameworks/Linked.dylib", kind: .symbolicLink),
        ])

        let error = try rejection(table, source: source)

        XCTAssertEqual(error.reason, .pathSafetyViolation)
        XCTAssertEqual(error.path, makeBundlePath("Frameworks/Linked.dylib"))
    }

    func testASymbolicLinkNamedLikeCodeOutsideACodeLocationIsReportedWithoutBeingRead() throws {
        let source = SyntheticNestedCodeInspectionSource(binaries: [
            archivePath("Example").rawValue: NestedCodeFixtures.unsignedMachO(),
        ])
        let table = basicTable([
            entry("Resources", kind: .directory),
            entry("Resources/Extra.dylib", kind: .symbolicLink),
        ])

        let plan = try plan(table, source: source)

        XCTAssertTrue(plan.diagnostics.contains {
            $0.code == .unsafeEntryInCodeLocation && $0.path == makeBundlePath("Resources/Extra.dylib")
        })
        XCTAssertEqual(
            plan.unsupportedItems,
            [NestedCodeUnsupportedItem(path: makeBundlePath("Resources/Extra.dylib"), reason: .unsupportedStructure)]
        )
        XCTAssertEqual(source.requestedBinaryPaths, [archivePath("Example")])
    }

    /// Names ZynSign refuses cannot be attributed to a location, so they are
    /// reported once and are never interpreted as structure.
    func testAnEntryWhoseNameFailsTheSafetyRulesIsReportedOnce() throws {
        let source = SyntheticNestedCodeInspectionSource(binaries: [
            archivePath("Example").rawValue: NestedCodeFixtures.unsignedMachO(),
        ])
        var table = basicTable()
        table.append(makeRejectedEntry("Payload/Example.app/../Escape.dylib"))
        table.append(makeRejectedEntry("/Payload/Example.app/../Escape.dylib"))

        let plan = try plan(table, source: source)

        let matching = plan.diagnostics.filter { $0.code == .unattributableEntryName }
        XCTAssertEqual(matching.count, 1)
        XCTAssertTrue(matching.first?.detail.contains("2 entries") == true)
        XCTAssertEqual(plan.unsupportedItems.count, 0)
        XCTAssertEqual(source.requestedBinaryPaths, [archivePath("Example")])
    }

    /// A location recorded with two different kinds is a contradiction in the
    /// entry table. Discovery keeps the first recorded kind, reports the
    /// contradiction, and does not choose between the recorded forms.
    func testALocationRecordedWithTwoKindsIsReported() throws {
        let source = SyntheticNestedCodeInspectionSource(binaries: [
            archivePath("Example").rawValue: NestedCodeFixtures.unsignedMachO(),
        ])
        var table = basicTable()
        table.append(entry("Frameworks", kind: .directory))
        table.append(entry("Frameworks", kind: .regularFile))

        let plan = try plan(table, source: source)

        XCTAssertTrue(plan.diagnostics.contains { $0.code == .conflictingEntryKind })
    }

    // MARK: - Determinism

    func testTheSameStructureProducesTheSamePlanWhateverOrderTheTableUses() throws {
        let table = basicTable([
            entry("Frameworks", kind: .directory),
            entry("Frameworks/First.framework", kind: .directory),
            entry("Frameworks/First.framework/Info.plist"),
            entry("Frameworks/First.framework/First"),
            entry("Frameworks/Second.framework", kind: .directory),
            entry("Frameworks/Second.framework/Info.plist"),
            entry("Frameworks/Second.framework/Second"),
            entry("PlugIns", kind: .directory),
            entry("PlugIns/Widget.appex", kind: .directory),
            entry("PlugIns/Widget.appex/Info.plist"),
            entry("PlugIns/Widget.appex/Widget"),
        ])
        func source() -> SyntheticNestedCodeInspectionSource {
            SyntheticNestedCodeInspectionSource(
                binaries: [
                    archivePath("Example").rawValue: NestedCodeFixtures.unsignedMachO(),
                    archivePath("First", in: "Frameworks/First.framework").rawValue: NestedCodeFixtures.unsignedMachO(),
                    archivePath("Second", in: "Frameworks/Second.framework").rawValue: NestedCodeFixtures.unsignedMachO(),
                    archivePath("Widget", in: "PlugIns/Widget.appex").rawValue: NestedCodeFixtures.unsignedMachO(),
                ],
                information: [
                    archivePath("Frameworks/First.framework").rawValue: .read(
                        NestedCodeFixtures.identity(bundleIdentifier: "com.example.synthetic.first", executableName: "First")
                    ),
                    archivePath("Frameworks/Second.framework").rawValue: .read(
                        NestedCodeFixtures.identity(bundleIdentifier: "com.example.synthetic.second", executableName: "Second")
                    ),
                    archivePath("PlugIns/Widget.appex").rawValue: .read(
                        NestedCodeFixtures.identity(bundleIdentifier: "com.example.synthetic.widget", executableName: "Widget")
                    ),
                ]
            )
        }

        let forward = try plan(table, source: source())
        let reversed = try plan(Array(table.reversed()), source: source())

        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(
            forward.orderedItemIDs.map(\.description),
            [
                "framework:Frameworks/First.framework",
                "framework:Frameworks/Second.framework",
                "applicationExtension:PlugIns/Widget.appex",
                "application",
            ]
        )
    }

    // MARK: - Resource policy

    func testTheDefaultPolicyIsBoundedAndDocumented() {
        XCTAssertEqual(NestedCodeDiscoveryLimits.default.maximumItems, 512)
        XCTAssertEqual(NestedCodeDiscoveryLimits.default.maximumBinaryBytes, 32 * 1_024 * 1_024)
        XCTAssertEqual(NestedCodeDiscoveryLimits.default.maximumContainerDepth, 4)
        XCTAssertEqual(NestedCodeDiscoveryLimits.default.maximumAmbiguityCandidates, 8)
    }

    func testTooManyItemsEndsDiscoveryWithTheResourceLimitReason() throws {
        let source = SyntheticNestedCodeInspectionSource(
            binaries: [
                archivePath("Example").rawValue: NestedCodeFixtures.unsignedMachO(),
                archivePath("Frame", in: "Frameworks/Frame.framework").rawValue: NestedCodeFixtures.unsignedMachO(),
            ],
            information: [
                archivePath("Frameworks/Frame.framework").rawValue: .read(
                    NestedCodeFixtures.identity(bundleIdentifier: "com.example.synthetic.frame", executableName: "Frame")
                ),
            ]
        )
        let table = basicTable([
            entry("Frameworks", kind: .directory),
            entry("Frameworks/Frame.framework", kind: .directory),
            entry("Frameworks/Frame.framework/Info.plist"),
            entry("Frameworks/Frame.framework/Frame"),
        ])

        let error = try rejection(table, limits: limits(items: 1), source: source)

        XCTAssertEqual(error.reason, .resourceLimitExceeded)
        XCTAssertEqual(error.reason.category, .unsupportedInput)
    }

    func testTooManyBinaryReadsEndsDiscoveryWithTheResourceLimitReason() throws {
        let source = SyntheticNestedCodeInspectionSource(
            binaries: [
                archivePath("Example").rawValue: NestedCodeFixtures.unsignedMachO(),
                archivePath("Frame", in: "Frameworks/Frame.framework").rawValue: NestedCodeFixtures.unsignedMachO(),
            ],
            information: [
                archivePath("Frameworks/Frame.framework").rawValue: .read(
                    NestedCodeFixtures.identity(bundleIdentifier: "com.example.synthetic.frame", executableName: "Frame")
                ),
            ]
        )
        let table = basicTable([
            entry("Frameworks", kind: .directory),
            entry("Frameworks/Frame.framework", kind: .directory),
            entry("Frameworks/Frame.framework/Info.plist"),
            entry("Frameworks/Frame.framework/Frame"),
        ])

        let error = try rejection(table, limits: limits(binaryReads: 1), source: source)

        XCTAssertEqual(error.reason, .resourceLimitExceeded)
        XCTAssertEqual(source.requestedBinaryPaths.count, 1)
    }

    func testTooManyInformationReadsEndsDiscoveryWithTheResourceLimitReason() throws {
        let source = SyntheticNestedCodeInspectionSource(
            binaries: [
                archivePath("Example").rawValue: NestedCodeFixtures.unsignedMachO(),
                archivePath("Frame", in: "Frameworks/Frame.framework").rawValue: NestedCodeFixtures.unsignedMachO(),
            ],
            information: [
                archivePath("Frameworks/Frame.framework").rawValue: .read(
                    NestedCodeFixtures.identity(bundleIdentifier: "com.example.synthetic.frame", executableName: "Frame")
                ),
            ]
        )
        let table = basicTable([
            entry("Frameworks", kind: .directory),
            entry("Frameworks/Frame.framework", kind: .directory),
            entry("Frameworks/Frame.framework/Info.plist"),
            entry("Frameworks/Frame.framework/Frame"),
        ])

        let error = try rejection(table, limits: limits(informationReads: 0), source: source)

        XCTAssertEqual(error.reason, .resourceLimitExceeded)
    }

    func testTooDeepContainerNestingEndsDiscoveryWithTheResourceLimitReason() throws {
        let source = SyntheticNestedCodeInspectionSource()
        let table = basicTable([
            entry("Frameworks", kind: .directory),
            entry("Frameworks/Frame.framework", kind: .directory),
            entry("Frameworks/Frame.framework/Frame"),
        ])

        let error = try rejection(table, limits: limits(containerDepth: 0), source: source)

        XCTAssertEqual(error.reason, .resourceLimitExceeded)
        XCTAssertEqual(error.path, makeBundlePath("Frameworks/Frame.framework"))
    }

    func testTooManyVisitedDirectoriesEndsDiscoveryWithTheResourceLimitReason() throws {
        let source = SyntheticNestedCodeInspectionSource(binaries: [
            archivePath("Example").rawValue: NestedCodeFixtures.unsignedMachO(),
        ])
        let table = basicTable([entry("Frameworks", kind: .directory)])

        let error = try rejection(table, limits: limits(visitedDirectories: 0), source: source)

        XCTAssertEqual(error.reason, .resourceLimitExceeded)
    }

    func testTooManyUnsupportedItemsEndsDiscoveryWithTheResourceLimitReason() throws {
        let source = SyntheticNestedCodeInspectionSource(binaries: [
            archivePath("Example").rawValue: NestedCodeFixtures.unsignedMachO(),
        ])
        let table = basicTable([
            entry("Resources", kind: .directory),
            entry("Resources/Extra.dylib"),
        ])

        let error = try rejection(table, limits: limits(unsupportedItems: 0), source: source)

        XCTAssertEqual(error.reason, .resourceLimitExceeded)
    }

    func testACandidateBeyondTheInspectionBoundIsNotRead() throws {
        let source = SyntheticNestedCodeInspectionSource(binaries: [
            archivePath("Example").rawValue: NestedCodeFixtures.unsignedMachO(),
            archivePath("Frame", in: "Frameworks/Frame.framework").rawValue: NestedCodeFixtures.unsignedMachO(),
        ])
        // The main executable is deliberately small: only the framework
        // candidate exceeds the inspection bound under test. (basicTable's
        // 8 KiB executable would exceed the 1 KiB bound too, and a main
        // executable beyond the bound refuses the bundle — see
        // testAMainExecutableBeyondTheInspectionBoundRejectsTheBundleAsOverItsPolicy.)
        let table = NestedCodeFixtures.packageTable(
            bundleName: bundleName,
            entries: [
                entry("Info.plist"),
                entry("Example", size: 512),
                entry("Frameworks", kind: .directory),
                entry("Frameworks/Frame.framework", kind: .directory),
                entry("Frameworks/Frame.framework/Info.plist"),
                entry("Frameworks/Frame.framework/Frame", size: 64 * 1_024 * 1_024),
            ]
        )

        let plan = try plan(table, limits: limits(binaryBytes: 1_024), source: source)

        let framework = try XCTUnwrap(plan.nestedItems.first)
        XCTAssertEqual(framework.binary, .beyondInspectionBound(declaredByteCount: 64 * 1_024 * 1_024))
        XCTAssertEqual(framework.status, .notEstablished(.binaryBeyondInspectionBound(declaredByteCount: 64 * 1_024 * 1_024)))
        XCTAssertFalse(source.requestedBinaryPaths.contains(archivePath("Frame", in: "Frameworks/Frame.framework")))
        XCTAssertFalse(plan.isComplete)
    }

    func testAMainExecutableBeyondTheInspectionBoundRejectsTheBundleAsOverItsPolicy() throws {
        let source = SyntheticNestedCodeInspectionSource()
        let table = NestedCodeFixtures.packageTable(
            bundleName: bundleName,
            entries: [entry("Info.plist"), entry("Example", size: 64 * 1_024 * 1_024)]
        )

        let error = try rejection(table, limits: limits(binaryBytes: 1_024), source: source)

        XCTAssertEqual(error.reason, .resourceLimitExceeded)
        XCTAssertTrue(source.requestedBinaryPaths.isEmpty)
    }

    func testAnUnreadableInformationFileLeavesTheItemIncompleteWithoutGuessing() throws {
        let source = SyntheticNestedCodeInspectionSource(
            binaries: [
                archivePath("Example").rawValue: NestedCodeFixtures.unsignedMachO(),
                archivePath("Frame", in: "Frameworks/Frame.framework").rawValue: NestedCodeFixtures.unsignedMachO(),
            ],
            information: [
                archivePath("Frameworks/Frame.framework").rawValue: .unreadable,
            ]
        )
        let table = basicTable([
            entry("Frameworks", kind: .directory),
            entry("Frameworks/Frame.framework", kind: .directory),
            entry("Frameworks/Frame.framework/Info.plist"),
            entry("Frameworks/Frame.framework/Frame"),
        ])

        let plan = try plan(table, source: source)

        let framework = try XCTUnwrap(plan.nestedItems.first)
        XCTAssertEqual(framework.bundleInformation, .unreadable)
        XCTAssertEqual(framework.status, .established, "The executable is still established from its bytes.")
        XCTAssertFalse(plan.isComplete)
        XCTAssertTrue(plan.unsupportedItems.contains(
            NestedCodeUnsupportedItem(
                path: makeBundlePath("Frameworks/Frame.framework/Info.plist"),
                reason: .unreadableBundleInformation
            )
        ))
        XCTAssertTrue(plan.diagnostics.contains { $0.code == .bundleInformationUnavailable })
    }

    func testAMalformedInformationFileIsReportedAndLeavesThePlanIncomplete() throws {
        let source = SyntheticNestedCodeInspectionSource(
            binaries: [
                archivePath("Example").rawValue: NestedCodeFixtures.unsignedMachO(),
                archivePath("Frame", in: "Frameworks/Frame.framework").rawValue: NestedCodeFixtures.unsignedMachO(),
            ],
            information: [
                archivePath("Frameworks/Frame.framework").rawValue: .malformed,
            ]
        )
        let table = basicTable([
            entry("Frameworks", kind: .directory),
            entry("Frameworks/Frame.framework", kind: .directory),
            entry("Frameworks/Frame.framework/Info.plist"),
            entry("Frameworks/Frame.framework/Frame"),
        ])

        let plan = try plan(table, source: source)

        XCTAssertEqual(plan.nestedItems.first?.bundleInformation, .malformed)
        XCTAssertTrue(plan.unsupportedItems.contains(
            NestedCodeUnsupportedItem(
                path: makeBundlePath("Frameworks/Frame.framework/Info.plist"),
                reason: .malformedBundleInformation
            )
        ))
    }

    /// A source that answers a code location with no structure cannot make an
    /// item established, whatever it reports.
    func testAnUninspectedCandidateIsNeverEstablished() throws {
        let source = SyntheticNestedCodeInspectionSource(
            information: [
                archivePath("Frameworks/Frame.framework").rawValue: .read(
                    NestedCodeFixtures.identity(bundleIdentifier: "com.example.synthetic.frame", executableName: "Frame")
                ),
            ]
        )
        let table = basicTable([
            entry("Frameworks", kind: .directory),
            entry("Frameworks/Frame.framework", kind: .directory),
            entry("Frameworks/Frame.framework/Info.plist"),
            entry("Frameworks/Frame.framework/Frame"),
        ])

        let plan = try plan(table, source: source)

        let framework = try XCTUnwrap(plan.nestedItems.first)
        XCTAssertEqual(framework.status, .notEstablished(.binaryNotInspected))
        XCTAssertEqual(framework.binary, .notRequested)
        XCTAssertFalse(plan.isComplete)
    }

    // MARK: - Diagnostics are bounded

    func testDiagnosticsAreBoundedPerCode() throws {
        var entries: [ArchiveEntry] = [entry("Resources", kind: .directory)]
        for index in 0..<(NestedCodeDiscovery.maximumDiagnosticsPerCode + 4) {
            entries.append(entry("Resources/Extra\(index).dylib"))
        }
        let source = SyntheticNestedCodeInspectionSource(binaries: [
            archivePath("Example").rawValue: NestedCodeFixtures.unsignedMachO(),
        ])

        let plan = try plan(basicTable(entries), source: source)

        let coded = plan.diagnostics.filter { $0.code == .unsupportedCodeLocation }
        XCTAssertEqual(coded.count, NestedCodeDiscovery.maximumDiagnosticsPerCode)
        XCTAssertEqual(
            plan.unsupportedItems.count,
            NestedCodeDiscovery.maximumDiagnosticsPerCode + 4,
            "Bounding the report must not stop discovery from recording what it found."
        )
    }
}
