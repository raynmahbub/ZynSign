import Foundation

// MARK: - Scenarios

/// One package shape the signing pipeline must handle reproducibly.
///
/// The eight scenarios are the shapes a real device meets: a plain
/// application, one carrying frameworks, one carrying extensions, a
/// container that names two applications, an unsigned package, one that
/// already carries signature artifacts, a large package, and a coherent
/// package with an unusual layout. Each one is built from nothing by
/// `LabPackageFactory` and read back through the production archive
/// boundary, so a result is reproducible on any device and comparable
/// between releases.
enum SigningScenarioIdentifier: String, CaseIterable, Codable, Sendable, Identifiable {

    /// `Payload/App.app` with an information file, an executable and resources.
    case simpleApplication

    /// The same, plus a `.framework` and a standalone dynamic library.
    case applicationWithFrameworks

    /// The same, plus a `.appex` extension.
    case applicationWithExtensions

    /// Two application bundles in the payload: the shape discovery refuses.
    case multipleBundles

    /// A coherent package with no signature artifacts at all.
    case unsignedApplication

    /// A package carrying a signature region, a resource seal and an
    /// embedded profile — the shape ZynSign re-signs.
    case alreadySignedApplication

    /// One bundle with several hundred resources: measurement, not stress.
    case largePackage

    /// Deep nesting, non-ASCII names, a nested bundle, an archive artifact.
    case edgeCaseLayout

    var id: String { rawValue }

    /// The check identifier this scenario's result is recorded under.
    var checkID: String { "signing.scenario.\(rawValue)" }

    /// The name the Lab shows.
    var displayName: String {
        switch self {
        case .simpleApplication: return "Simple app"
        case .applicationWithFrameworks: return "App with frameworks"
        case .applicationWithExtensions: return "App with extensions"
        case .multipleBundles: return "Multiple bundles"
        case .unsignedApplication: return "Unsigned app"
        case .alreadySignedApplication: return "Already signed app"
        case .largePackage: return "Large IPA"
        case .edgeCaseLayout: return "Edge-case bundle layout"
        }
    }

    /// One sentence on what the scenario represents.
    var intent: String {
        switch self {
        case .simpleApplication:
            return "The ordinary case: one application bundle, one executable, no nested code."
        case .applicationWithFrameworks:
            return "Nested code inside Frameworks: a framework bundle and a standalone library."
        case .applicationWithExtensions:
            return "Nested code inside PlugIns: an application extension."
        case .multipleBundles:
            return "A container naming two applications, which ZynSign must refuse rather than choose between."
        case .unsignedApplication:
            return "A coherent package carrying no signature artifacts."
        case .alreadySignedApplication:
            return "A package that already carries a signature region, a resource seal and an embedded profile."
        case .largePackage:
            return "A package at the size an ordinary large application reaches, to measure rather than to stress."
        case .edgeCaseLayout:
            return "Unusual but coherent: deep nesting, non-ASCII names, a nested bundle, an archive artifact."
        }
    }

    // MARK: Expectations

    /// What the scenario must establish.
    ///
    /// Expectations are stated as claims the run can settle, and a claim the
    /// fixture cannot settle on its own is recorded rather than asserted: a
    /// count the production parser may legitimately decide differently is
    /// reported as a disagreement for a maintainer, not as a failure.
    struct Expectation: Equatable, Sendable {

        /// The structural classification the package must receive. `nil` when
        /// the scenario does not fix one.
        let classification: ValidationClassification?

        /// Whether nested-code discovery must produce a plan. `false` for the
        /// shapes discovery refuses.
        let producesPlan: Bool

        /// The nested items the fixture declares, when the count is one the
        /// fixture fixes. `nil` records the count without asserting it.
        let nestedItemCount: Int?

        /// Whether a produced plan must survive the nested-signing plan
        /// validator — the gate that runs before any mutation.
        let requiresPlanValidation: Bool

        /// The least number of entries the fixture writes.
        let minimumEntryCount: Int

        static func expectation(
            classification: ValidationClassification? = .valid,
            producesPlan: Bool = true,
            nestedItemCount: Int? = 0,
            requiresPlanValidation: Bool = true,
            minimumEntryCount: Int = 3
        ) -> Expectation {
            Expectation(
                classification: classification,
                producesPlan: producesPlan,
                nestedItemCount: nestedItemCount,
                requiresPlanValidation: requiresPlanValidation,
                minimumEntryCount: minimumEntryCount
            )
        }
    }

    var expectation: Expectation {
        switch self {
        case .simpleApplication:
            return .expectation(nestedItemCount: 0, minimumEntryCount: 4)
        case .applicationWithFrameworks:
            // Two nested items: the framework bundle and the standalone library.
            return .expectation(nestedItemCount: 2, minimumEntryCount: 8)
        case .applicationWithExtensions:
            return .expectation(nestedItemCount: 1, minimumEntryCount: 7)
        case .multipleBundles:
            // Two applications in one payload: discovery must refuse.
            return .expectation(
                classification: .ambiguous,
                producesPlan: false,
                nestedItemCount: nil,
                requiresPlanValidation: false,
                minimumEntryCount: 5
            )
        case .unsignedApplication:
            return .expectation(nestedItemCount: 0, minimumEntryCount: 3)
        case .alreadySignedApplication:
            return .expectation(nestedItemCount: 0, minimumEntryCount: 5)
        case .largePackage:
            return .expectation(nestedItemCount: 0, minimumEntryCount: 380)
        case .edgeCaseLayout:
            // A nested bundle outside Frameworks and PlugIns is refused as
            // unsupported rather than planned: discovery reports it by
            // rejecting the bundle, so the count is recorded, not asserted,
            // and no plan exists to validate.
            return .expectation(
                producesPlan: false,
                nestedItemCount: nil,
                requiresPlanValidation: false,
                minimumEntryCount: 7
            )
        }
    }
}

// MARK: - Outcome

/// What one scenario run established.
///
/// The outcome is the reproducible result: two runs of one scenario on one
/// build must produce equal outcomes apart from their durations, and the Lab
/// asserts exactly that. It carries no path, no absolute location, and no
/// content — counts, classifications and a digest prefix, which is what a
/// comparison between two releases needs.
struct SigningScenarioOutcome: Equatable, Sendable {

    let scenario: SigningScenarioIdentifier
    /// The first sixteen hexadecimal characters of the container's SHA-256.
    let containerFingerprint: String
    let containerByteCount: Int
    let entryCount: Int
    let classification: ValidationClassification
    /// The structural finding codes, in examination order.
    let findingCodes: [String]
    let metadataWasRead: Bool
    let planWasProduced: Bool
    let nestedItemCount: Int
    let unsupportedItemCount: Int
    let diagnosticCount: Int
    /// The reason a produced plan was refused, when it was.
    let planValidationReason: String?
    /// How long the run took, in milliseconds.
    let durationMilliseconds: Int

    /// The outcome without its duration: what must match between two runs.
    var reproducible: SigningScenarioOutcome {
        SigningScenarioOutcome(
            scenario: scenario,
            containerFingerprint: containerFingerprint,
            containerByteCount: containerByteCount,
            entryCount: entryCount,
            classification: classification,
            findingCodes: findingCodes,
            metadataWasRead: metadataWasRead,
            planWasProduced: planWasProduced,
            nestedItemCount: nestedItemCount,
            unsupportedItemCount: unsupportedItemCount,
            diagnosticCount: diagnosticCount,
            planValidationReason: planValidationReason,
            durationMilliseconds: 0
        )
    }
}

// MARK: - Runner

/// Runs the signing scenario lab.
///
/// Every scenario is built, serialized with the production writer, written to
/// the Lab's own scratch directory, read back through the production reader,
/// and taken through the stages a real signing run takes before it touches
/// signing material: structural examination, metadata, nested-code discovery
/// and plan validation. Nothing is signed, because signing needs an identity
/// and a profile only the user has — and the Lab reports that honestly rather
/// than staging a fake one.
///
/// The runner removes every file it created, whatever the outcome.
struct SigningScenarioLab: CompatibilitySuite {

    private let digest: any MessageDigest
    private let limits: ArchiveLimits

    init(digest: any MessageDigest = CryptoKitMessageDigest(), limits: ArchiveLimits = .default) {
        self.digest = digest
        self.limits = limits
    }

    /// Runs one scenario twice and reports what it established.
    ///
    /// The second run is what makes the result a result: a scenario that
    /// disagrees with itself is a defect in the pipeline or in the fixture,
    /// and the check fails with both runs in its evidence.
    func check(for scenario: SigningScenarioIdentifier, context: CompatibilityLabContext) -> CompatibilityCheck {
        let started = context.now()
        do {
            let first = try run(scenario, context: context)
            let second = try run(scenario, context: context)
            let elapsed = Int(context.now().timeIntervalSince(started) * 1_000)
            return evaluate(scenario, first: first, second: second, totalMilliseconds: elapsed)
        } catch let error as ZynSignError {
            return CompatibilityCheck(
                id: scenario.checkID,
                category: .signingPipeline,
                title: scenario.displayName,
                status: .failed,
                summary: "The scenario could not be run: \(error.userMessage)",
                verified: "The Lab builds its own package and reads it back; a failure here is in the Lab or in the pipeline it exercises.",
                nextStep: "Read the diagnostic detail in the report, then run the scenario again on a device with free storage.",
                evidence: ["category: \(error.category)", error.diagnosticDetail ?? "no diagnostic detail"],
                durationMilliseconds: Int(context.now().timeIntervalSince(started) * 1_000),
                blocker: .high
            )
        } catch {
            return CompatibilityCheck(
                id: scenario.checkID,
                category: .signingPipeline,
                title: scenario.displayName,
                status: .failed,
                summary: "The scenario could not be run.",
                verified: "The failure was not one of ZynSign's typed errors, so only its type is recorded.",
                nextStep: "Give the failure a typed cause in the code path it came from, then run the Lab again.",
                evidence: ["cause type: \(String(describing: type(of: error)))"],
                durationMilliseconds: Int(context.now().timeIntervalSince(started) * 1_000),
                blocker: .high
            )
        }
    }

    /// Runs every scenario, in declaration order.
    func checks(context: CompatibilityLabContext) async -> [CompatibilityCheck] {
        SigningScenarioIdentifier.allCases.map { check(for: $0, context: context) }
    }

    // MARK: - Execution

    /// Builds, writes, reads and examines one scenario once.
    func run(_ scenario: SigningScenarioIdentifier, context: CompatibilityLabContext) throws -> SigningScenarioOutcome {
        let package = try LabPackageFactory.package(for: scenario)
        let container = try ZipArchiveWriter().serializedArchive(entries: package.entries, policy: .default)
        let fingerprint = try digest.digest(container, algorithm: .sha256)

        let directory = context.scratchRoot
            .appendingPathComponent("SigningScenarios", isDirectory: true)
        try context.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let location = directory
            .appendingPathComponent("\(scenario.rawValue)-\(UUID().uuidString)", isDirectory: false)
            .appendingPathExtension("ipa")
        // Whatever happens, the Lab leaves nothing behind: the package
        // file goes, and the directory this run created goes with it once
        // it holds nothing more (a concurrent run may still be using it).
        defer {
            try? context.fileManager.removeItem(at: location)
            if let contents = try? context.fileManager.contentsOfDirectory(atPath: directory.path),
               contents.isEmpty {
                try? context.fileManager.removeItem(at: directory)
            }
        }
        try container.write(to: location)

        let reader = ZipArchiveReader(location: location, limits: limits)
        defer { reader.close() }

        let entryTable = try reader.readEntryTable()
        let inspection = IPAStructureValidator(limits: limits).validate(entryTable: entryTable)
        let metadata = try readMetadata(
            from: reader,
            bundlePath: inspection.bundle?.bundlePath
        )

        var planWasProduced = false
        var nestedItemCount = 0
        var unsupportedItemCount = 0
        var diagnosticCount = 0
        var planValidationReason: String?

        if let bundlePath = inspection.bundle?.bundlePath, let metadata {
            let source = ArchiveNestedCodeInspectionSource(reader: reader, limits: limits)
            let request = NestedCodeDiscoveryRequest(
                bundlePath: bundlePath,
                applicationIdentity: NestedCodeBundleIdentity(metadata: metadata)
            )
            let outcome = NestedCodeDiscovery.discover(
                entryTable: entryTable,
                request: request,
                limits: .default,
                source: source
            )
            switch outcome {
            case .plan(let plan):
                planWasProduced = true
                nestedItemCount = plan.nestedItems.count
                unsupportedItemCount = plan.unsupportedItems.count
                diagnosticCount = plan.diagnostics.count
                do {
                    _ = try NestedSigningPlanValidator.validate(plan: plan)
                } catch let failure as NestedSigningFailure {
                    // The reason names the rule family; the detail names the
                    // rule — a run nobody can reproduce must still say which
                    // constraint refused the plan.
                    planValidationReason = "\(failure.reason.rawValue) (\(failure.category)): \(failure.detail)"
                } catch {
                    planValidationReason = "untyped failure"
                }
            case .rejected(let failure):
                planWasProduced = false
                planValidationReason = "discovery rejected: \(Self.reasonText(of: failure))"
            }
        }

        return SigningScenarioOutcome(
            scenario: scenario,
            containerFingerprint: String(fingerprint.hexString.prefix(16)),
            containerByteCount: container.count,
            entryCount: entryTable.count,
            classification: inspection.validation.classification,
            findingCodes: inspection.validation.findings.map(\.code.rawValue),
            metadataWasRead: metadata != nil,
            planWasProduced: planWasProduced,
            nestedItemCount: nestedItemCount,
            unsupportedItemCount: unsupportedItemCount,
            diagnosticCount: diagnosticCount,
            planValidationReason: planValidationReason,
            durationMilliseconds: 0
        )
    }

    /// Reads the information file of the bundle structural examination
    /// established, through the same bound the application uses.
    private func readMetadata(
        from reader: any ArchiveReader,
        bundlePath: ArchivePath?
    ) throws -> ApplicationMetadata? {
        guard let bundlePath else { return nil }
        guard let informationPath = IPALayout.bundleInformationPath(within: bundlePath) else { return nil }
        let data = try reader.readEntryData(
            at: informationPath,
            maximumBytes: limits.maximumInspectionReadBytes
        )
        return ApplicationMetadataReader.read(from: data).metadata
    }

    private static func reasonText(of failure: NestedCodeDiscoveryError) -> String {
        failure.reason.rawValue
    }

    // MARK: - Evaluation

    private func evaluate(
        _ scenario: SigningScenarioIdentifier,
        first: SigningScenarioOutcome,
        second: SigningScenarioOutcome,
        totalMilliseconds: Int
    ) -> CompatibilityCheck {
        let expectation = scenario.expectation
        var status: CompatibilityStatus = .passed
        var evidence: [String] = []
        var nextStep: String?

        func fail(_ reason: String, _ action: String) {
            if status != .failed {
                status = .failed
                nextStep = action
            }
            evidence.append("refused: \(reason)")
        }

        func warn(_ reason: String, _ action: String) {
            if status == .passed {
                status = .warning
                nextStep = action
            }
            evidence.append("noted: \(reason)")
        }

        evidence.append("container: \(first.containerByteCount) bytes, \(first.entryCount) entries, sha256 \(first.containerFingerprint)…")
        evidence.append("structure: \(first.classification.displayName)\(first.findingCodes.isEmpty ? "" : " (" + first.findingCodes.joined(separator: ", ") + ")")")
        evidence.append("metadata: \(first.metadataWasRead ? "read" : "not read")")
        evidence.append("nested code: \(first.planWasProduced ? "plan with \(first.nestedItemCount) nested item(s)" : "no plan"), \(first.unsupportedItemCount) unsupported, \(first.diagnosticCount) observation(s)")
        if let reason = first.planValidationReason {
            evidence.append("plan validation: \(reason)")
        }

        if first.reproducible != second.reproducible {
            fail(
                "two runs of the same scenario disagreed",
                "Treat this as a determinism defect: the same package must produce the same result twice."
            )
        }
        if first.entryCount < expectation.minimumEntryCount {
            fail(
                "the fixture wrote \(first.entryCount) entries, fewer than the \(expectation.minimumEntryCount) it declares",
                "The fixture and its expectation disagree; fix the fixture before reading the result."
            )
        }
        if let expected = expectation.classification, first.classification != expected {
            fail(
                "structure was classified \(first.classification.displayName), expected \(expected.displayName)",
                "Compare the findings with the scenario expectations before changing either the rule or the expectation."
            )
        }
        if expectation.producesPlan && !first.planWasProduced {
            fail(
                "discovery produced no plan: \(first.planValidationReason ?? "no reason recorded")",
                "Discovery refusing an ordinary package blocks signing; read the reason and fix the pipeline."
            )
        }
        if !expectation.producesPlan && first.planWasProduced {
            fail(
                "discovery produced a plan where it must refuse",
                "A shape ZynSign must not sign is being planned; the refusal rule has changed."
            )
        }
        if expectation.requiresPlanValidation, let reason = first.planValidationReason {
            fail(
                "the nested-signing plan validator refused the plan: \(reason)",
                "A refused plan means signing cannot start; fix the plan or the validator rule that refuses it."
            )
        }
        if first.unsupportedItemCount > 0 {
            warn(
                "\(first.unsupportedItemCount) located item(s) could not be established as signable code",
                "Read the unsupported reasons: an ordinary package shape is not being recognised."
            )
        }
        if let expectedCount = expectation.nestedItemCount, first.nestedItemCount != expectedCount {
            warn(
                "discovery located \(first.nestedItemCount) nested item(s) where the fixture declares \(expectedCount)",
                "The fixture's declaration and discovery disagree; settle which is right before the release, and record the discrepancy in the release record."
            )
        }

        let summary: String
        switch status {
        case .passed:
            summary = "\(scenario.displayName) behaved as declared, reproducibly, in \(totalMilliseconds) ms."
        case .warning:
            summary = "\(scenario.displayName) behaved as declared with something to look at."
        case .failed:
            summary = "\(scenario.displayName) did not meet its expectation."
        case .notRun, .skipped:
            summary = "\(scenario.displayName) did not run."
        }

        return CompatibilityCheck(
            id: scenario.checkID,
            category: .signingPipeline,
            title: scenario.displayName,
            status: status,
            summary: summary,
            verified: Self.verifiedStatement(for: scenario),
            nextStep: nextStep,
            evidence: evidence,
            measurements: [
                CompatibilityMeasurement(
                    name: "preparation",
                    value: Double(totalMilliseconds),
                    unit: "ms",
                    threshold: Double(PerformanceThresholds.signingPreparationMilliseconds),
                    comparison: .lowerIsBetter
                ),
                CompatibilityMeasurement(
                    name: "container size",
                    value: Double(first.containerByteCount),
                    unit: "bytes",
                    comparison: .informational
                )
            ],
            durationMilliseconds: totalMilliseconds,
            blocker: .high
        )
    }

    /// What a passing scenario actually establishes — and what it does not.
    ///
    /// A scenario verifies preparation, not signature quality: it says the
    /// package was understood and a signing order was justified. It does not
    /// say the result would be accepted by iOS, and the Lab never lets a
    /// reader take it for more.
    private static func verifiedStatement(for scenario: SigningScenarioIdentifier) -> String {
        "Verified that ZynSign reads \(scenario.displayName.lowercased()) deterministically through the production archive boundary — structure, metadata, nested-code discovery and plan validation — twice, with equal results. Not verified: an actual signature, which needs an identity and a profile only the user has."
    }
}
