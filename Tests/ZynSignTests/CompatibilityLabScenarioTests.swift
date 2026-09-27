import XCTest
@testable import ZynSign

/// The signing scenario lab: that every package shape is read reproducibly,
/// and that a run leaves nothing behind.
final class CompatibilityLabScenarioTests: XCTestCase {

    private var scratchRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZynSignTests-Lab-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratchRoot { try? FileManager.default.removeItem(at: scratchRoot) }
        try super.tearDownWithError()
    }

    private func context() -> CompatibilityLabContext {
        CompatibilityLabContext(scratchRoot: scratchRoot)
    }

    // MARK: - Scenarios

    func testEveryScenarioRunsTwiceWithTheSameResult() throws {
        let lab = SigningScenarioLab()
        for scenario in SigningScenarioIdentifier.allCases {
            let first = try lab.run(scenario, context: context())
            let second = try lab.run(scenario, context: context())
            XCTAssertEqual(
                first.reproducible,
                second.reproducible,
                "\(scenario.rawValue) is not reproducible: two runs disagreed"
            )
        }
    }

    func testEveryScenarioMeetsItsExpectation() throws {
        let lab = SigningScenarioLab()
        for scenario in SigningScenarioIdentifier.allCases {
            let outcome = try lab.run(scenario, context: context())
            let expectation = scenario.expectation
            XCTAssertGreaterThanOrEqual(
                outcome.entryCount,
                expectation.minimumEntryCount,
                "\(scenario.rawValue) wrote fewer entries than it declares"
            )
            if let expected = expectation.classification {
                XCTAssertEqual(
                    outcome.classification,
                    expected,
                    "\(scenario.rawValue) was classified unexpectedly"
                )
            }
            XCTAssertEqual(
                outcome.planWasProduced,
                expectation.producesPlan,
                "\(scenario.rawValue) produced a plan \(outcome.planWasProduced), expected \(expectation.producesPlan)"
            )
            if expectation.requiresPlanValidation {
                XCTAssertNil(
                    outcome.planValidationReason,
                    "\(scenario.rawValue) plan was refused: \(outcome.planValidationReason ?? "")"
                )
            }
        }
    }

    func testEveryScenarioProducesACheckThatAnswersThreeQuestions() {
        let lab = SigningScenarioLab()
        for scenario in SigningScenarioIdentifier.allCases {
            let check = lab.check(for: scenario, context: context())
            XCTAssertEqual(check.id, scenario.checkID)
            XCTAssertEqual(check.category, .signingPipeline)
            XCTAssertFalse(check.summary.isEmpty, "\(scenario.rawValue) says nothing about what happened")
            XCTAssertFalse(check.verified.isEmpty, "\(scenario.rawValue) says nothing about what was verified")
            XCTAssertFalse(check.evidence.isEmpty, "\(scenario.rawValue) carries no evidence")
            if check.status != .passed {
                XCTAssertNotNil(check.nextStep, "\(scenario.rawValue) is not a pass and says nothing to do next")
            }
        }
    }

    func testAScenarioRunLeavesNoFilesBehind() throws {
        let lab = SigningScenarioLab()
        for scenario in SigningScenarioIdentifier.allCases {
            _ = try lab.run(scenario, context: context())
        }
        let contents = try FileManager.default.contentsOfDirectory(
            at: scratchRoot,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(
            contents.isEmpty,
            "The scenario lab left files behind: \(contents.map(\.lastPathComponent))"
        )
    }

    // MARK: - Fixtures

    func testSyntheticPackagesUseOnlyLabIdentifiers() throws {
        // A Lab artifact must be unmistakable in a log and must never carry
        // a real bundle identifier, team prefix, or device reference.
        for scenario in SigningScenarioIdentifier.allCases {
            let package = try LabPackageFactory.package(for: scenario)
            XCTAssertTrue(
                package.bundleIdentifier.hasPrefix(LabPackageFactory.identifierRoot),
                "\(scenario.rawValue) declares \(package.bundleIdentifier)"
            )
            for entry in package.entries {
                XCTAssertNotNil(
                    ArchivePath(rawValue: entry.path.rawValue),
                    "\(scenario.rawValue) names a path ZynSign's own rules refuse"
                )
            }
        }
    }

    func testTheSyntheticImageIsThinArm64AndParsesAsMachO() throws {
        // The production parser is the judge: if it refuses the Lab's image,
        // every nested-code scenario is measuring the wrong thing.
        let image = LabMachOImage.thinARM64(fileType: LabMachOImage.executeFileType)
        let parsed = try ReadOnlyMachOParser().parse(image)
        guard case .thin(let slice) = parsed.container else {
            return XCTFail("The Lab image should be a thin image")
        }
        XCTAssertEqual(slice.header.cpu, .arm64)
        XCTAssertNil(slice.embeddedSignature, "An unsigned Lab image carries no signature command")
    }

    func testTheSyntheticImageWithASignatureRegionParsesAsSigned() throws {
        let image = LabMachOImage.thinARM64(
            fileType: LabMachOImage.executeFileType,
            signature: LabMachOImage.emptyEmbeddedSignature
        )
        let parsed = try ReadOnlyMachOParser().parse(image)
        guard case .thin(let slice) = parsed.container else {
            return XCTFail("The Lab image should be a thin image")
        }
        // The Lab never claims the signature is valid; it only requires that
        // the region the fixture declares is the region the parser finds.
        XCTAssertNotNil(slice.embeddedSignature?.command)
    }
}
