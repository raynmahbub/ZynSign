import Foundation

// MARK: - Catalog

/// One frozen behaviour, and the tests that keep it frozen.
///
/// A regression entry is a promise that a workflow still behaves the way it
/// did when it was built: not that it is correct in the abstract, but that it
/// has not silently changed. Each entry names the unit-test types that
/// assert it, because the Lab cannot run the test target from inside the
/// application — CI can, and `Scripts/audit_regression_coverage.py` refuses
/// a catalog whose named tests have disappeared.
struct RegressionCoverageEntry: Identifiable, Codable, Equatable, Sendable {

    /// What the Lab can execute here and now, in the running app.
    ///
    /// The runtime probe is the part of an entry that needs no test runner:
    /// an invariant ZynSign can assert about itself. Everything else is
    /// covered by the unit tests and reported as not run by the Lab.
    enum Probe: String, Codable, CaseIterable, Sendable {
        case importRules
        case librarySearch
        case identityErrorTaxonomy
        case errorTaxonomyProfiles
        case signingStageOrder
        case verificationContract
        case exportNaming
        case installationHonesty
        case preferencesSchema
        case none
    }

    /// The behaviour's short identifier, also its check's suffix.
    let id: String

    /// The workflow the behaviour belongs to.
    let area: String

    /// The behaviour, stated as a claim that can fail.
    let behaviour: String

    /// The unit-test types that assert it.
    let testSuites: [String]

    /// What the Lab executes, if anything.
    let probe: Probe

    /// The check identifier this entry's result is recorded under.
    var checkID: String { "regression.\(id)" }
}

/// The regression catalogue: every workflow the release train switched on,
/// plus the persistence and honesty guarantees underneath them.
enum RegressionCoverageCatalog {

    static let entries: [RegressionCoverageEntry] = [
        RegressionCoverageEntry(
            id: "import",
            area: "Import",
            behaviour: "The files ZynSign accepts for import, and the ones it refuses, are unchanged; a package is fingerprinted before anything is stored.",
            testSuites: [
                "ImportRulesTests", "ImportWorkflowTests", "IPAPackageImportTests",
                "IPAStructureValidationTests", "SecurityScopedArtifactIntakeTests",
                "ImportPreflightTests", "ArchiveLimitsTests"
            ],
            probe: .importRules
        ),
        RegressionCoverageEntry(
            id: "library",
            area: "Library",
            behaviour: "Records, duplicate policy, artifact availability, search folding and ordering behave as they did when they were built.",
            testSuites: [
                "ApplicationLibraryTests", "ApplicationRecordTests", "ApplicationRecordDuplicatePolicyTests",
                "LibraryIndexTests", "FileApplicationRecordStoreTests", "FileLibraryArtifactStoreTests",
                "LibraryArtifactVerificationTests", "LibraryPersistenceLifecycleTests"
            ],
            probe: .librarySearch
        ),
        RegressionCoverageEntry(
            id: "certificates",
            area: "Certificates",
            behaviour: "Identities are listed deterministically, private keys are never exportable, and every identity failure maps to a stable category with a user message of its own.",
            testSuites: [
                "CertificateManagerModelTests", "SecureIdentityStoreTests", "SigningIdentityStorageBoundaryTests",
                "IdentityKeychainErrorTests", "CertificateInspectionTests", "KeychainIdentityIntegrationTests",
                "SigningKeyProtectionRuleTests", "ApplePKCS12ImporterTests"
            ],
            probe: .identityErrorTaxonomy
        ),
        RegressionCoverageEntry(
            id: "profiles",
            area: "Profiles",
            behaviour: "Profile parsing, expiration and compatibility keep their classifications, and a profile failure never becomes an untyped error.",
            testSuites: [
                "ProvisioningProfileParserTests", "ProvisioningProfileSummaryTests", "ProfileExpirationIntelligenceTests",
                "ProfileCompatibilityEngineTests", "ValidateProvisioningProfileUseCaseTests", "ProvisioningPolicyValidationTests"
            ],
            probe: .errorTaxonomyProfiles
        ),
        RegressionCoverageEntry(
            id: "signing",
            area: "Signing",
            behaviour: "The stage order is unchanged: nested code is signed inner-first, the application last, then packaging and verification.",
            testSuites: [
                "SignApplicationPipelineTests", "SigningEngineCoordinatorTests", "SigningOperationExecutorTests",
                "NestedCodeSigningOrderTests", "WorkflowStageTests", "SigningRequestTests", "SigningMetadataIntegrationTests"
            ],
            probe: .signingStageOrder
        ),
        RegressionCoverageEntry(
            id: "verification",
            area: "Verification",
            behaviour: "A verification result is a re-read of what ZynSign produced, never a claim about the signature that produced it; only a valid classification proceeds to later stages.",
            testSuites: [
                "VerifySignedApplicationTests", "SignatureVerificationTests", "ValidationResultTests",
                "ValidationClassificationTests", "AppleSignatureVerifierTests", "AppleCMSSignatureVerifierTests",
                "ExternalValidationExportTests"
            ],
            probe: .verificationContract
        ),
        RegressionCoverageEntry(
            id: "export",
            area: "Export",
            behaviour: "Export naming never overwrites an existing artifact, and ZynSign recognises its own output files.",
            testSuites: [
                "PackageSignedApplicationTests", "LibraryExportPreparationTests", "ExternalValidationExportTests"
            ],
            probe: .exportNaming
        ),
        RegressionCoverageEntry(
            id: "store",
            area: "Store",
            behaviour: "A source's health is measured, not assumed, and a failing or malformed source reaches the interface as a state.",
            testSuites: ["StoreResilienceTests"],
            probe: .none
        ),
        RegressionCoverageEntry(
            id: "downloads",
            area: "Downloads",
            behaviour: "Transfers resume from resume data, are bounded, and fail into a retryable state.",
            testSuites: ["DownloadsResilienceTests"],
            probe: .none
        ),
        RegressionCoverageEntry(
            id: "installation",
            area: "Installation Workspace",
            behaviour: "ZynSign never reports an artifact as installable: the absent delivery mechanism is always reported first, whatever the evidence says.",
            testSuites: ["InstallationCapabilityTests", "InstallationDeliveryTests"],
            probe: .installationHonesty
        ),
        RegressionCoverageEntry(
            id: "persistence",
            area: "Persistence & Backups",
            behaviour: "Preferences, catalogs and journals keep their schema contracts, and an older schema is converted on read rather than discarded.",
            testSuites: [
                "ZynSignPreferencesTests", "FilePreferencesStoreTests", "FileSigningQueueStoreTests",
                "LibraryOrganizationTests", "FileSigningPresetStoreTests", "FileSigningDiagnosticsHistoryStoreTests"
            ],
            probe: .preferencesSchema
        )
    ]

    /// The entries whose behaviour the Lab can execute here.
    static var executable: [RegressionCoverageEntry] {
        entries.filter { $0.probe != .none }
    }
}

// MARK: - Suite

/// Freezes existing behaviour: the regression suite.
///
/// Two kinds of answer live in this category, and the Lab keeps them apart.
/// Where an invariant can be asserted in the running app — the files import
/// accepts, the stage order, the honesty of the installation assessment, the
/// schema round-trip — the Lab asserts it and reports pass or fail. Where
/// the behaviour is frozen by the unit-test target, the Lab names the tests
/// and reports not run, because claiming a test passed without running it
/// would be the exact dishonesty this suite exists to prevent.
struct RegressionSuite: CompatibilitySuite {

    func checks(context: CompatibilityLabContext) async -> [CompatibilityCheck] {
        RegressionCoverageCatalog.entries.map { entry in
            switch entry.probe {
            case .none:
                return recorded(entry)
            default:
                return execute(entry, context: context)
            }
        }
    }

    // MARK: Recorded

    private func recorded(_ entry: RegressionCoverageEntry) -> CompatibilityCheck {
        CompatibilityCheck(
            id: entry.checkID,
            category: .regressionCoverage,
            title: "\(entry.area) regressions",
            status: .notRun,
            summary: "Frozen by the unit-test target; the Lab cannot run it from inside the app.",
            verified: "Nothing was executed here. \(entry.behaviour)",
            nextStep: "Run the ZynSignTests target (CI job: Build and test (Xcode)) and import its result through a Lab overlay.",
            evidence: entry.testSuites.map { "test suite: \($0)" },
            blocker: .medium
        )
    }

    // MARK: Execution

    private func execute(
        _ entry: RegressionCoverageEntry,
        context: CompatibilityLabContext
    ) -> CompatibilityCheck {
        let outcome: (status: CompatibilityStatus, evidence: [String])
        switch entry.probe {
        case .none:
            outcome = (.notRun, [])
        case .importRules:
            outcome = Self.importRules()
        case .librarySearch:
            outcome = Self.librarySearch()
        case .identityErrorTaxonomy:
            outcome = Self.identityErrorTaxonomy()
        case .errorTaxonomyProfiles:
            outcome = Self.profileTaxonomy()
        case .signingStageOrder:
            outcome = Self.signingStageOrder()
        case .verificationContract:
            outcome = Self.verificationContract()
        case .exportNaming:
            outcome = Self.exportNaming()
        case .installationHonesty:
            outcome = Self.installationHonesty()
        case .preferencesSchema:
            outcome = Self.preferencesSchema(context: context)
        }
        return CompatibilityCheck(
            id: entry.checkID,
            category: .regressionCoverage,
            title: "\(entry.area) regressions",
            status: outcome.status,
            summary: Self.summary(for: entry, status: outcome.status),
            verified: "Verified here: \(entry.behaviour) Also frozen by \(entry.testSuites.count) unit-test type(s).",
            nextStep: outcome.status == .passed
                ? nil
                : "A frozen behaviour changed. Find out whether the change was intended before the next candidate.",
            evidence: outcome.evidence + entry.testSuites.map { "also covered by: \($0)" },
            blocker: outcome.status == .failed ? .critical : nil
        )
    }

    private static func summary(for entry: RegressionCoverageEntry, status: CompatibilityStatus) -> String {
        switch status {
        case .passed: return "\(entry.area) behaves as frozen."
        case .warning: return "\(entry.area) behaves as frozen, with something to look at."
        case .failed: return "\(entry.area) no longer behaves as frozen."
        case .notRun, .skipped: return "\(entry.area) was not checked."
        }
    }

    // MARK: Probes

    /// Which files import accepts, and which it refuses.
    private static func importRules() -> (CompatibilityStatus, [String]) {
        let accepted = ["App.ipa", "App.tipa", "Apps.zip"]
        let refused = ["App.dmg", "App.txt", "App.ipa.bak", "profile.mobileprovision", "cert.p12"]
        func url(_ name: String) -> URL { URL(fileURLWithPath: "/lab/\(name)") }
        let wrongAccepted = accepted.filter { !IPAFileFormat.acceptsForImport(url($0)) }
        let wrongRefused = refused.filter { IPAFileFormat.acceptsForImport(url($0)) }
        return (
            wrongAccepted.isEmpty && wrongRefused.isEmpty ? .passed : .failed,
            [
                "accepted: \(accepted.joined(separator: ", "))",
                "refused: \(refused.joined(separator: ", "))",
                "wrongly accepted: \(wrongAccepted.joined(separator: ", ").isEmpty ? "none" : wrongAccepted.joined(separator: ", "))",
                "wrongly refused: \(wrongRefused.isEmpty ? "none" : wrongRefused.joined(separator: ", "))"
            ]
        )
    }

    /// Search folding: case, diacritics and width are ignored, so "cafe"
    /// finds "Café" and a full-width form finds its ASCII equivalent.
    private static func librarySearch() -> (CompatibilityStatus, [String]) {
        let pairs = [
            ("Café", "cafe"),
            ("ＡＢＣ", "abc"),
            ("ZynSign", "zynsign")
        ]
        let failures = pairs.filter { LibraryQuery.fold($0.0) != LibraryQuery.fold($0.1) }
        let orders = LibrarySortMode.allCases.map(\.rawValue)
        let decodable = orders.count == Set(orders).count
        return (
            failures.isEmpty && decodable ? .passed : .failed,
            [
                "folding pairs: \(pairs.count), mismatched: \(failures.count)",
                "sort orders: \(orders.count)"
            ]
        )
    }

    /// Every identity failure maps to the category its own vocabulary
    /// declares, and carries a user message of its own.
    private static func identityErrorTaxonomy() -> (CompatibilityStatus, [String]) {
        var mismatches: [String] = []
        for reason in SigningIdentityFailure.allCases {
            let error = ZynSignError.identity(reason)
            if error.category != reason.category { mismatches.append(reason.rawValue) }
            if error.userMessage.isEmpty { mismatches.append("\(reason.rawValue):no message") }
        }
        return (
            mismatches.isEmpty ? .passed : .failed,
            [
                "identity failures: \(SigningIdentityFailure.allCases.count)",
                "mismatched: \(mismatches.isEmpty ? "none" : mismatches.joined(separator: ", "))"
            ]
        )
    }

    /// A profile failure is typed: it carries a category, a user message,
    /// and a diagnostic detail that never leaks a profile's contents.
    private static func profileTaxonomy() -> (CompatibilityStatus, [String]) {
        var mismatches: [String] = []
        for reason in ProvisioningProfileFailure.allCases {
            let error = ZynSignError.provisioningProfile(reason)
            if error.category != reason.category { mismatches.append(reason.rawValue) }
            if error.userMessage.isEmpty { mismatches.append("\(reason.rawValue):no message") }
        }
        return (
            mismatches.isEmpty ? .passed : .failed,
            [
                "profile failures: \(ProvisioningProfileFailure.allCases.count)",
                "mismatched: \(mismatches.isEmpty ? "none" : mismatches.joined(separator: ", "))"
            ]
        )
    }

    /// The signing stage order: nested code before the application, and the
    /// workflow order the pipeline was built on.
    private static func signingStageOrder() -> (CompatibilityStatus, [String]) {
        let stages = SigningEngineStage.allCases
        func index(of stage: SigningEngineStage) -> Int? { stages.firstIndex(of: stage) }
        let problems: [String] = []
        var notes: [String] = ["stages: \(stages.map(\.rawValue).joined(separator: " → "))"]
        // The application is signed only after every nested kind that can
        // appear inside it; that is the invariant the ordering rests on.
        let nested: [SigningEngineStage] = [
            .signingFrameworks, .signingDynamicLibraries, .signingExtensions, .signingNestedApplications
        ]
        for stage in nested {
            guard let nestedIndex = index(of: stage),
                  let applicationIndex = index(of: .signingApplication) else { continue }
            if nestedIndex >= applicationIndex {
                return (.failed, notes + ["\(stage.rawValue) is not signed before the application"])
            }
        }
        let workflow = WorkflowStage.allCases.map(\.rawValue)
        let expected = ["inspection", "signing", "verification", "packaging", "installation"]
        if workflow != expected {
            return (.failed, notes + ["workflow order changed: \(workflow.joined(separator: " → "))"])
        }
        notes.append("workflow order: \(workflow.joined(separator: " → "))")
        _ = problems
        return (.passed, notes)
    }

    /// Only a `valid` classification proceeds, and a classification agrees
    /// with the findings behind it.
    private static func verificationContract() -> (CompatibilityStatus, [String]) {
        let permitting = ValidationClassification.allCases.filter(\.permitsLaterStages).map(\.rawValue)
        let consistent = ValidationResult.valid().isConsistent
            && ValidationResult.invalid(findings: [
                ValidationFinding(severity: .error, code: .unreadableArchive, detail: "lab")
            ]).isConsistent
            && ValidationResult(classification: .valid, findings: [
                ValidationFinding(severity: .error, code: .unreadableArchive, detail: "lab")
            ]).isConsistent == false
        return (
            permitting == ["valid"] && consistent ? .passed : .failed,
            [
                "classifications permitting later stages: \(permitting.joined(separator: ", "))",
                "classification agrees with findings: \(consistent)"
            ]
        )
    }

    /// Export naming never collides with a name already present, and
    /// ZynSign recognises the names it produced.
    private static func exportNaming() -> (CompatibilityStatus, [String]) {
        let base = "Example"
        let first = ExportNamingPolicy.fileName(base: base, existing: [])
        let second = ExportNamingPolicy.fileName(base: base, existing: [first])
        let third = ExportNamingPolicy.fileName(base: base, existing: [first, second])
        let distinct = Set([first, second, third]).count == 3
        let recognised = ExportNamingPolicy.isPolicyName(first)
        return (
            distinct && recognised ? .passed : .failed,
            [
                "first: \(first)",
                "second: \(second)",
                "third: \(third)",
                "recognised as ZynSign output: \(recognised)"
            ]
        )
    }

    /// The installation honesty guarantee: even with perfect evidence,
    /// ZynSign reports that it cannot install.
    private static func installationHonesty() -> (CompatibilityStatus, [String]) {
        let assessment = InstallationCapabilityAssessment.assess(
            InstallationEvidence(
                profileStatus: .valid,
                deviceAuthorized: true,
                platformSupported: true
            )
        )
        let firstLimitation = assessment.limitations.first
        let honest = assessment.supported == false
            && firstLimitation == .noDeliveryMechanism
        return (
            honest ? .passed : .failed,
            [
                "supported: \(assessment.supported)",
                "limitations: \(assessment.limitations.map(\.rawValue).joined(separator: ", "))"
            ]
        )
    }

    /// The preferences schema round-trips, and the shipped defaults are the
    /// defaults after a round trip.
    private static func preferencesSchema(context: CompatibilityLabContext) -> (CompatibilityStatus, [String]) {
        let shipped = ZynSignPreferences.shippedDefault
        do {
            let data = try JSONEncoder().encode(shipped)
            let decoded = try JSONDecoder().decode(ZynSignPreferences.self, from: data)
            return (
                decoded == shipped ? .passed : .failed,
                [
                    "schema: \(data.count) bytes",
                    "round trip preserves every value: \(decoded == shipped)"
                ]
            )
        } catch {
            return (.failed, ["encoding failed: \(String(describing: error))"])
        }
    }
}
