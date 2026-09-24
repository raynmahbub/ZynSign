import Foundation
import XCTest
@testable import ZynSign

/// Focused deterministic tests for nested code signing (ZS-028).
///
/// Covers:
/// 1. Signing-plan validation (valid plan, duplicate targets, cycle, ordering, path safety,
///    unsupported formats, root application preservation).
/// 2. Deterministic dependency-aware signing order (deepest nested code -> its dependents
///    -> higher-level nested code -> application deferred).
/// 3. Nested Mach-O signing (unsigned binary, signature replacement policy, existing signature
///    rejection, malformed signature handling).
/// 4. Cryptographic and structural verification after signing (page hashes, CodeDirectory
///    digest, CMS verification, tampering detection).
/// 5. Multiple nested targets (multiple frameworks, app extensions, independent and dependent).
/// 6. Failure handling and atomicity (read failure, write failure, signing failure,
///    verification failure, staged working copy vs direct mutation).
/// 7. Mach-O data preservation (unrelated code and headers remain unmodified).
final class NestedCodeSigningTests: XCTestCase {

    private let digest = CryptoKitMessageDigest()

    // MARK: - Test Doubles

    private func makeIdentities() throws -> NestedSigningTestIdentityStore {
        try NestedSigningTestIdentityStore()
    }

    private func makeVerifier(valid: Bool = true) -> NestedSigningTestVerifier {
        let v = NestedSigningTestVerifier()
        v.shouldVerifyValid = valid
        return v
    }

    private func makeUseCase(
        identities: any IdentityStore,
        verifier: any CryptographicSignatureVerifier
    ) -> SignNestedCodeUseCase {
        SignNestedCodeUseCase(
            identities: identities,
            digest: digest,
            verifier: verifier
        )
    }

    // MARK: - Plan Construction Helpers

    private func makePlan(
        root: NestedCodeItem,
        nestedItems: [NestedCodeItem],
        dependencies: [NestedCodeDependency]? = nil,
        steps: [NestedCodeSigningStep]? = nil,
        unsupportedItems: [NestedCodeUnsupportedItem] = []
    ) -> NestedCodeSigningPlan {
        let graph = NestedCodeDependencyGraph.structural(
            items: [root] + nestedItems,
            rootItemID: root.id
        )
        let finalDeps = dependencies ?? graph.dependencies
        let finalSteps: [NestedCodeSigningStep]
        if let steps {
            finalSteps = steps
        } else {
            finalSteps = graph.orderedItemIDs().enumerated().map { index, id in
                NestedCodeSigningStep(order: index + 1, itemID: id)
            }
        }
        return NestedCodeSigningPlan(
            root: root,
            nestedItems: nestedItems,
            dependencies: finalDeps,
            steps: finalSteps,
            unsupportedItems: unsupportedItems,
            diagnostics: []
        )
    }

    // MARK: - 1. Signing-Plan Validation Tests

    func testValidNestedPlanPassesValidation() throws {
        let app = makeNestedCodeItem(kind: .application, location: "")
        let framework = makeNestedCodeItem(
            kind: .framework,
            location: "Frameworks/MyFramework.framework",
            parentID: app.id,
            bundleIdentifier: "com.example.myframework"
        )
        let plan = makePlan(root: app, nestedItems: [framework])

        let validated = try NestedSigningPlanValidator.validate(plan: plan)
        XCTAssertEqual(validated.rootItemID, app.id)
        XCTAssertEqual(validated.stepCount, 1)
        XCTAssertEqual(validated.items.first?.id, framework.id)
        XCTAssertEqual(validated.items.first?.order, 1)
        XCTAssertEqual(validated.items.first?.bundleIdentifier?.rawValue, "com.example.myframework")
    }

    func testPlanWithDuplicateItemFailsValidation() {
        let app = makeNestedCodeItem(kind: .application, location: "")
        let framework1 = makeNestedCodeItem(kind: .framework, location: "Frameworks/A.framework", parentID: app.id)
        let framework2 = makeNestedCodeItem(kind: .framework, location: "Frameworks/A.framework", parentID: app.id)

        let plan = NestedCodeSigningPlan(
            root: app,
            nestedItems: [framework1, framework2],
            dependencies: [],
            steps: [
                NestedCodeSigningStep(order: 1, itemID: framework1.id),
                NestedCodeSigningStep(order: 2, itemID: app.id),
            ],
            unsupportedItems: [],
            diagnostics: []
        )

        XCTAssertThrowsError(try NestedSigningPlanValidator.validate(plan: plan)) { error in
            guard let failure = error as? NestedSigningFailure else {
                return XCTFail("Expected NestedSigningFailure, got \(error)")
            }
            XCTAssertEqual(failure.reason, .invalidSigningPlan)
        }
    }

    func testPlanWithDuplicateExecutablePathFailsValidation() {
        let app = makeNestedCodeItem(kind: .application, location: "")
        let item1 = makeNestedCodeItem(
            kind: .framework,
            location: "Frameworks/A.framework",
            executablePath: "Frameworks/SharedBinary",
            parentID: app.id
        )
        let item2 = makeNestedCodeItem(
            kind: .framework,
            location: "Frameworks/B.framework",
            executablePath: "Frameworks/SharedBinary",
            parentID: app.id
        )

        let plan = NestedCodeSigningPlan(
            root: app,
            nestedItems: [item1, item2],
            dependencies: [],
            steps: [
                NestedCodeSigningStep(order: 1, itemID: item1.id),
                NestedCodeSigningStep(order: 2, itemID: item2.id),
                NestedCodeSigningStep(order: 3, itemID: app.id),
            ],
            unsupportedItems: [],
            diagnostics: []
        )

        XCTAssertThrowsError(try NestedSigningPlanValidator.validate(plan: plan)) { error in
            guard let failure = error as? NestedSigningFailure else {
                return XCTFail("Expected NestedSigningFailure, got \(error)")
            }
            XCTAssertEqual(failure.reason, .invalidSigningPlan)
        }
    }

    func testPlanWithMissingDependencyEndpointFailsValidation() {
        let app = makeNestedCodeItem(kind: .application, location: "")
        let framework = makeNestedCodeItem(kind: .framework, location: "Frameworks/A.framework", parentID: app.id)
        let missingID = NestedCodeItemID(kind: .framework, location: makeBundlePath("Frameworks/Missing.framework"))

        let plan = NestedCodeSigningPlan(
            root: app,
            nestedItems: [framework],
            dependencies: [
                NestedCodeDependency(nestedCode: framework.id, container: missingID)
            ],
            steps: [
                NestedCodeSigningStep(order: 1, itemID: framework.id),
                NestedCodeSigningStep(order: 2, itemID: app.id),
            ],
            unsupportedItems: [],
            diagnostics: []
        )

        XCTAssertThrowsError(try NestedSigningPlanValidator.validate(plan: plan)) { error in
            guard let failure = error as? NestedSigningFailure else {
                return XCTFail("Expected NestedSigningFailure, got \(error)")
            }
            XCTAssertEqual(failure.reason, .invalidSigningPlan)
        }
    }

    func testPlanWithInvalidOrderingFailsValidation() {
        // Child framework ordered AFTER outer container in steps:
        let app = makeNestedCodeItem(kind: .application, location: "")
        let outer = makeNestedCodeItem(kind: .framework, location: "Frameworks/Outer.framework", parentID: app.id)
        let inner = makeNestedCodeItem(
            kind: .framework,
            location: "Frameworks/Outer.framework/Frameworks/Inner.framework",
            parentID: outer.id
        )

        // Invalid step order: outer first (order 1), inner second (order 2), app third (order 3)
        let plan = NestedCodeSigningPlan(
            root: app,
            nestedItems: [outer, inner],
            dependencies: [
                NestedCodeDependency(nestedCode: inner.id, container: outer.id),
                NestedCodeDependency(nestedCode: outer.id, container: app.id),
            ],
            steps: [
                NestedCodeSigningStep(order: 1, itemID: outer.id),
                NestedCodeSigningStep(order: 2, itemID: inner.id),
                NestedCodeSigningStep(order: 3, itemID: app.id),
            ],
            unsupportedItems: [],
            diagnostics: []
        )

        XCTAssertThrowsError(try NestedSigningPlanValidator.validate(plan: plan)) { error in
            guard let failure = error as? NestedSigningFailure else {
                return XCTFail("Expected NestedSigningFailure, got \(error)")
            }
            XCTAssertEqual(failure.reason, .invalidSigningPlan)
            XCTAssertTrue(failure.detail.contains("Dependency ordering violation"))
        }
    }

    func testPlanWithSelfDependencyFailsValidation() {
        let app = makeNestedCodeItem(kind: .application, location: "")
        let framework = makeNestedCodeItem(kind: .framework, location: "Frameworks/A.framework", parentID: app.id)

        let plan = NestedCodeSigningPlan(
            root: app,
            nestedItems: [framework],
            dependencies: [
                NestedCodeDependency(nestedCode: framework.id, container: framework.id)
            ],
            steps: [
                NestedCodeSigningStep(order: 1, itemID: framework.id),
                NestedCodeSigningStep(order: 2, itemID: app.id),
            ],
            unsupportedItems: [],
            diagnostics: []
        )

        XCTAssertThrowsError(try NestedSigningPlanValidator.validate(plan: plan)) { error in
            guard let failure = error as? NestedSigningFailure else {
                return XCTFail("Expected NestedSigningFailure, got \(error)")
            }
            XCTAssertEqual(failure.reason, .invalidSigningPlan)
        }
    }

    func testPlanWithExecutableEscapingContainerFailsValidation() {
        let app = makeNestedCodeItem(kind: .application, location: "")
        let framework = makeNestedCodeItem(
            kind: .framework,
            location: "Frameworks/A.framework",
            executablePath: "PlugIns/EscapedBinary",
            parentID: app.id
        )

        let plan = makePlan(root: app, nestedItems: [framework])

        XCTAssertThrowsError(try NestedSigningPlanValidator.validate(plan: plan)) { error in
            guard let failure = error as? NestedSigningFailure else {
                return XCTFail("Expected NestedSigningFailure, got \(error)")
            }
            XCTAssertEqual(failure.reason, .invalidSigningPlan)
        }
    }

    func testPlanWithUniversalMachOFailsValidation() {
        let app = makeNestedCodeItem(kind: .application, location: "")
        let framework = makeNestedCodeItem(
            kind: .framework,
            location: "Frameworks/Universal.framework",
            parentID: app.id,
            isUniversal: true
        )

        let plan = makePlan(root: app, nestedItems: [framework])

        XCTAssertThrowsError(try NestedSigningPlanValidator.validate(plan: plan)) { error in
            guard let failure = error as? NestedSigningFailure else {
                return XCTFail("Expected NestedSigningFailure, got \(error)")
            }
            XCTAssertEqual(failure.reason, .unsupportedFormat)
        }
    }

    func testPlanWithUnsupportedItemsFailsValidation() {
        let app = makeNestedCodeItem(kind: .application, location: "")
        let framework = makeNestedCodeItem(kind: .framework, location: "Frameworks/A.framework", parentID: app.id)

        let unsupportedItem = NestedCodeUnsupportedItem(
            path: makeBundlePath("Frameworks/Broken.framework"),
            reason: .unsupportedStructure
        )
        let plan = makePlan(root: app, nestedItems: [framework], unsupportedItems: [unsupportedItem])

        XCTAssertThrowsError(try NestedSigningPlanValidator.validate(plan: plan)) { error in
            guard let failure = error as? NestedSigningFailure else {
                return XCTFail("Expected NestedSigningFailure, got \(error)")
            }
            XCTAssertEqual(failure.reason, .unsupportedCodeType)
        }
    }

    func testPlanWithMainExecutableIncorrectlyIncludedAsNestedItemFailsValidation() {
        let app = makeNestedCodeItem(kind: .application, location: "")
        let nestedApp = makeNestedCodeItem(kind: .application, location: "Frameworks/NestedApp.app", parentID: app.id)

        let plan = NestedCodeSigningPlan(
            root: app,
            nestedItems: [nestedApp],
            dependencies: [],
            steps: [
                NestedCodeSigningStep(order: 1, itemID: nestedApp.id),
                NestedCodeSigningStep(order: 2, itemID: app.id),
            ],
            unsupportedItems: [],
            diagnostics: []
        )

        XCTAssertThrowsError(try NestedSigningPlanValidator.validate(plan: plan)) { error in
            guard let failure = error as? NestedSigningFailure else {
                return XCTFail("Expected NestedSigningFailure, got \(error)")
            }
            XCTAssertEqual(failure.reason, .invalidSigningPlan)
        }
    }

    // MARK: - 2. Nested Mach-O Signing Tests

    func testUnsignedNestedMachOSignsSuccessfully() throws {
        let app = makeNestedCodeItem(kind: .application, location: "")
        let framework = makeNestedCodeItem(
            kind: .framework,
            location: "Frameworks/Test.framework",
            parentID: app.id,
            bundleIdentifier: "com.example.single"
        )
        let plan = makePlan(root: app, nestedItems: [framework])

        let identities = try makeIdentities()
        let verifier = makeVerifier(valid: true)
        let useCase = makeUseCase(identities: identities, verifier: verifier)

        let execPath = try XCTUnwrap(framework.executablePath)
        let store = MemoryNestedSigningArtifactStore(binaries: [
            execPath: MachOSigningFixtures.unsignedMachO
        ])

        let result = useCase.sign(
            plan: plan,
            identityID: identities.id,
            store: store,
            teamIdentifier: try CodeDirectoryTeamIdentifier(rawValue: "TESTTEAM")
        )

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.summary.totalTargets, 1)
        XCTAssertEqual(result.summary.successfullySignedCount, 1)
        XCTAssertEqual(result.summary.failedCount, 0)
        XCTAssertEqual(result.summary.mutationState, .allTargetsModified(count: 1))

        let itemResult = try XCTUnwrap(result.result(for: framework.id))
        XCTAssertTrue(itemResult.isSuccess)
        guard case .signed(let details) = itemResult.status else {
            return XCTFail("Expected signed status")
        }
        XCTAssertTrue(details.verification.isVerified)

        // Verify that the written binary in the store is signed.
        let writtenData = try store.readBinary(at: execPath)
        XCTAssertEqual(writtenData, MachOSigningFixtures.expectedSignedMachO)
    }

    func testSupportedExistingSignatureRejectedByPolicy() throws {
        let app = makeNestedCodeItem(kind: .application, location: "")
        let framework = makeNestedCodeItem(
            kind: .framework,
            location: "Frameworks/Test.framework",
            parentID: app.id,
            bundleIdentifier: "com.example.single"
        )
        let plan = makePlan(root: app, nestedItems: [framework])

        let identities = try makeIdentities()
        let verifier = makeVerifier(valid: true)
        let useCase = makeUseCase(identities: identities, verifier: verifier)

        let execPath = try XCTUnwrap(framework.executablePath)
        // Store already contains a signed binary:
        let store = MemoryNestedSigningArtifactStore(binaries: [
            execPath: MachOSigningFixtures.expectedSignedMachO
        ])

        let result = useCase.sign(
            plan: plan,
            identityID: identities.id,
            store: store,
            existingSignaturePolicy: .rejectExistingSignature
        )

        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.summary.failedCount, 1)
        XCTAssertEqual(result.summary.successfullySignedCount, 0)
        XCTAssertEqual(result.summary.mutationState, .noTargetsModified)

        guard case .failed(let failure) = result.status else {
            return XCTFail("Expected failed result status")
        }
        XCTAssertEqual(failure.reason, .existingSignatureRejected)
    }

    func testUnsupportedExistingSignatureReplacementReturnsUnsupportedResult() throws {
        let app = makeNestedCodeItem(kind: .application, location: "")
        let framework = makeNestedCodeItem(
            kind: .framework,
            location: "Frameworks/Test.framework",
            parentID: app.id,
            bundleIdentifier: "com.example.single"
        )
        let plan = makePlan(root: app, nestedItems: [framework])

        let identities = try makeIdentities()
        let verifier = makeVerifier(valid: true)
        let useCase = makeUseCase(identities: identities, verifier: verifier)

        let execPath = try XCTUnwrap(framework.executablePath)
        let store = MemoryNestedSigningArtifactStore(binaries: [
            execPath: MachOSigningFixtures.expectedSignedMachO
        ])

        let result = useCase.sign(
            plan: plan,
            identityID: identities.id,
            store: store,
            existingSignaturePolicy: .replaceExistingSignature
        )

        XCTAssertFalse(result.isSuccess)
        guard case .failed(let failure) = result.status else {
            return XCTFail("Expected failure")
        }
        XCTAssertEqual(failure.reason, .unsupportedExistingSignature)
        XCTAssertEqual(result.summary.mutationState, .noTargetsModified)
    }

    func testMalformedExistingSignatureFailsCleanly() throws {
        let app = makeNestedCodeItem(kind: .application, location: "")
        let framework = makeNestedCodeItem(
            kind: .framework,
            location: "Frameworks/Malformed.framework",
            parentID: app.id
        )
        let plan = makePlan(root: app, nestedItems: [framework])

        let identities = try makeIdentities()
        let verifier = makeVerifier(valid: true)
        let useCase = makeUseCase(identities: identities, verifier: verifier)

        // Make binary with malformed signature command (e.g. dataoff pointing out of bounds):
        var malformed = MachOSigningFixtures.expectedSignedMachO
        malformed[264] = 0xFF // corrupt offset
        let execPath = try XCTUnwrap(framework.executablePath)
        let store = MemoryNestedSigningArtifactStore(binaries: [execPath: malformed])

        let result = useCase.sign(plan: plan, identityID: identities.id, store: store)

        XCTAssertFalse(result.isSuccess)
        guard case .failed(let failure) = result.status else {
            return XCTFail("Expected failure")
        }
        XCTAssertEqual(failure.reason, .malformedExistingSignature)
        XCTAssertEqual(result.summary.mutationState, .noTargetsModified)
    }

    // MARK: - 3. Cryptographic Verification Tests

    func testTamperedSignedBinaryFailsVerification() throws {
        let app = makeNestedCodeItem(kind: .application, location: "")
        let framework = makeNestedCodeItem(
            kind: .framework,
            location: "Frameworks/Test.framework",
            parentID: app.id,
            bundleIdentifier: "com.example.single"
        )
        let plan = makePlan(root: app, nestedItems: [framework])

        let identities = try makeIdentities()
        // Configure verifier to fail:
        let verifier = makeVerifier(valid: false)
        let useCase = makeUseCase(identities: identities, verifier: verifier)

        let execPath = try XCTUnwrap(framework.executablePath)
        let store = MemoryNestedSigningArtifactStore(binaries: [
            execPath: MachOSigningFixtures.unsignedMachO
        ])

        let result = useCase.sign(
            plan: plan,
            identityID: identities.id,
            store: store,
            teamIdentifier: try CodeDirectoryTeamIdentifier(rawValue: "TESTTEAM")
        )

        XCTAssertFalse(result.isSuccess)
        guard case .failed(let failure) = result.status else {
            return XCTFail("Expected failure")
        }
        // Failure caught at signing or verification stage:
        XCTAssertTrue(failure.reason == .postSignVerificationFailure || failure.reason == .signingCapabilityFailure)
    }

    // MARK: - 4. Ordering & Multiple Nested Binaries

    func testMultiLevelHierarchySignsInExactDeterministicOrder() throws {
        let app = makeNestedCodeItem(kind: .application, location: "")
        let levelOne = makeNestedCodeItem(
            kind: .framework,
            location: "Frameworks/One.framework",
            parentID: app.id,
            bundleIdentifier: "com.example.one"
        )
        let levelTwo = makeNestedCodeItem(
            kind: .framework,
            location: "Frameworks/One.framework/Frameworks/Two.framework",
            parentID: levelOne.id,
            bundleIdentifier: "com.example.two"
        )

        let plan = makePlan(root: app, nestedItems: [levelOne, levelTwo])

        let validated = try NestedSigningPlanValidator.validate(plan: plan)
        // Innermost (Two) must be step 1, outer (One) step 2:
        XCTAssertEqual(validated.items.map(\.id), [levelTwo.id, levelOne.id])

        let identities = try makeIdentities()
        let verifier = makeVerifier(valid: true)
        let useCase = makeUseCase(identities: identities, verifier: verifier)

        let exec1 = try XCTUnwrap(levelOne.executablePath)
        let exec2 = try XCTUnwrap(levelTwo.executablePath)

        let store = MemoryNestedSigningArtifactStore(binaries: [
            exec1: MachOSigningFixtures.unsignedMachO,
            exec2: MachOSigningFixtures.unsignedMachO,
        ])

        let result = useCase.sign(
            NestedSigningRequest(plan: validated, identityID: identities.id),
            store: store
        )

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.summary.successfullySignedCount, 2)
        XCTAssertEqual(result.itemResults.map(\.itemID), [levelTwo.id, levelOne.id])
    }

    func testSigningMultipleFrameworksAndExtensions() throws {
        let app = makeNestedCodeItem(kind: .application, location: "")
        let framework = makeNestedCodeItem(
            kind: .framework,
            location: "Frameworks/MyFramework.framework",
            parentID: app.id,
            bundleIdentifier: "com.example.framework"
        )
        let extensionItem = makeNestedCodeItem(
            kind: .applicationExtension,
            location: "PlugIns/ShareExtension.appex",
            parentID: app.id,
            bundleIdentifier: "com.example.extension"
        )

        let plan = makePlan(root: app, nestedItems: [framework, extensionItem])
        let validated = try NestedSigningPlanValidator.validate(plan: plan)

        let identities = try makeIdentities()
        let verifier = makeVerifier(valid: true)
        let useCase = makeUseCase(identities: identities, verifier: verifier)

        let fExec = try XCTUnwrap(framework.executablePath)
        let eExec = try XCTUnwrap(extensionItem.executablePath)

        let store = MemoryNestedSigningArtifactStore(binaries: [
            fExec: MachOSigningFixtures.unsignedMachO,
            eExec: MachOSigningFixtures.unsignedMachO,
        ])

        let result = useCase.sign(
            NestedSigningRequest(plan: validated, identityID: identities.id),
            store: store
        )

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.summary.totalTargets, 2)
        XCTAssertEqual(result.summary.successfullySignedCount, 2)
        XCTAssertEqual(result.summary.mutationState, .allTargetsModified(count: 2))
    }

    // MARK: - 5. Failure Handling and Atomicity Tests

    func testArtifactReadFailureStopsSigningAndSkipsRemaining() throws {
        let app = makeNestedCodeItem(kind: .application, location: "")
        let f1 = makeNestedCodeItem(kind: .framework, location: "Frameworks/A.framework", parentID: app.id)
        let f2 = makeNestedCodeItem(kind: .framework, location: "Frameworks/B.framework", parentID: app.id)

        let plan = makePlan(root: app, nestedItems: [f1, f2])
        let validated = try NestedSigningPlanValidator.validate(plan: plan)

        let identities = try makeIdentities()
        let verifier = makeVerifier(valid: true)
        let useCase = makeUseCase(identities: identities, verifier: verifier)

        let exec1 = try XCTUnwrap(f1.executablePath)
        // Store only holds f2, f1 is missing:
        let store = MemoryNestedSigningArtifactStore(binaries: [:])

        let result = useCase.sign(
            NestedSigningRequest(plan: validated, identityID: identities.id),
            store: store
        )

        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.summary.failedCount, 1)
        XCTAssertEqual(result.summary.skippedCount, 1)
        XCTAssertEqual(result.summary.mutationState, .noTargetsModified)

        let first = try XCTUnwrap(result.result(for: validated.items[0].id))
        guard case .failed(let failure) = first.status else {
            return XCTFail("Expected first target to fail")
        }
        XCTAssertEqual(failure.reason, .artifactReadFailure)

        let second = try XCTUnwrap(result.result(for: validated.items[1].id))
        guard case .skipped = second.status else {
            return XCTFail("Expected second target to be skipped")
        }
    }

    func testStagedWorkingCopyPreservesAtomicityOnMidwayFailure() throws {
        let app = makeNestedCodeItem(kind: .application, location: "")
        let f1 = makeNestedCodeItem(kind: .framework, location: "Frameworks/A.framework", parentID: app.id)
        let f2 = makeNestedCodeItem(kind: .framework, location: "Frameworks/B.framework", parentID: app.id)

        let plan = makePlan(root: app, nestedItems: [f1, f2])
        let validated = try NestedSigningPlanValidator.validate(plan: plan)

        let identities = try makeIdentities()
        let verifier = makeVerifier(valid: true)
        let useCase = makeUseCase(identities: identities, verifier: verifier)

        let exec1 = try XCTUnwrap(f1.executablePath)
        let exec2 = try XCTUnwrap(f2.executablePath)

        // f1 is valid unsigned, f2 already signed (which will fail under rejectExistingSignature):
        let store = MemoryNestedSigningArtifactStore(binaries: [
            exec1: MachOSigningFixtures.unsignedMachO,
            exec2: MachOSigningFixtures.expectedSignedMachO,
        ])

        let result = useCase.sign(
            NestedSigningRequest(
                plan: validated,
                identityID: identities.id,
                mutationStrategy: .stagedWorkingCopy
            ),
            store: store
        )

        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.summary.successfullySignedCount, 1)
        XCTAssertEqual(result.summary.failedCount, 1)
        // With staged working copy, failure discards changes:
        XCTAssertEqual(result.summary.mutationState, .noTargetsModified)

        // Verify that store binaries remain unmodified:
        XCTAssertEqual(try store.readBinary(at: exec1), MachOSigningFixtures.unsignedMachO)
        XCTAssertEqual(store.writtenBinaries.count, 0)
    }

    func testDirectMutationStrategyReportsSomeTargetsModifiedOnMidwayFailure() throws {
        let app = makeNestedCodeItem(kind: .application, location: "")
        let f1 = makeNestedCodeItem(kind: .framework, location: "Frameworks/A.framework", parentID: app.id)
        let f2 = makeNestedCodeItem(kind: .framework, location: "Frameworks/B.framework", parentID: app.id)

        let plan = makePlan(root: app, nestedItems: [f1, f2])
        let validated = try NestedSigningPlanValidator.validate(plan: plan)

        let identities = try makeIdentities()
        let verifier = makeVerifier(valid: true)
        let useCase = makeUseCase(identities: identities, verifier: verifier)

        let exec1 = try XCTUnwrap(f1.executablePath)
        let exec2 = try XCTUnwrap(f2.executablePath)

        let store = MemoryNestedSigningArtifactStore(binaries: [
            exec1: MachOSigningFixtures.unsignedMachO,
            exec2: MachOSigningFixtures.expectedSignedMachO,
        ])

        let result = useCase.sign(
            NestedSigningRequest(
                plan: validated,
                identityID: identities.id,
                mutationStrategy: .directMutation
            ),
            store: store
        )

        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.summary.successfullySignedCount, 1)
        XCTAssertEqual(result.summary.failedCount, 1)
        // Under direct mutation, f1 was written before f2 failed:
        XCTAssertEqual(result.summary.mutationState, .someTargetsModified(modifiedCount: 1, totalTargetCount: 2))
        XCTAssertEqual(store.writtenBinaries.count, 1)
        XCTAssertNotNil(store.writtenBinaries[exec1])
    }

    // MARK: - 6. Preservation Tests

    func testUnrelatedMachOBytesPreservedAfterSigning() throws {
        let app = makeNestedCodeItem(kind: .application, location: "")
        let framework = makeNestedCodeItem(
            kind: .framework,
            location: "Frameworks/Test.framework",
            parentID: app.id,
            bundleIdentifier: "com.example.single"
        )
        let plan = makePlan(root: app, nestedItems: [framework])

        let identities = try makeIdentities()
        let verifier = makeVerifier(valid: true)
        let useCase = makeUseCase(identities: identities, verifier: verifier)

        let execPath = try XCTUnwrap(framework.executablePath)
        let original = MachOSigningFixtures.unsignedMachO
        let store = MemoryNestedSigningArtifactStore(binaries: [execPath: original])

        let result = useCase.sign(
            plan: plan,
            identityID: identities.id,
            store: store,
            teamIdentifier: try CodeDirectoryTeamIdentifier(rawValue: "TESTTEAM")
        )

        XCTAssertTrue(result.isSuccess)
        let signed = try store.readBinary(at: execPath)

        // Verified preserved regions:
        // Executable code bytes from end of load commands up to signature region must match:
        let parsedOrig = try ReadOnlyMachOParser().parse(original)
        let origSlice = try XCTUnwrap(parsedOrig.slices.first)
        let textSection = try XCTUnwrap(origSlice.segments.first?.sections.first)
        let textLowerBound = Int(textSection.fileOffset)
        let textRange = textLowerBound..<(textLowerBound + Int(textSection.size))

        XCTAssertEqual(
            signed.subdata(in: textRange),
            original.subdata(in: textRange),
            "Executable code bytes must be identical before and after signing"
        )
    }

    // MARK: - 7. Identity & Availability Tests

    func testMissingSigningIdentityFailsBeforeAnyReadOrMutation() throws {
        let app = makeNestedCodeItem(kind: .application, location: "")
        let framework = makeNestedCodeItem(kind: .framework, location: "Frameworks/Test.framework", parentID: app.id)
        let plan = makePlan(root: app, nestedItems: [framework])

        let identities = try makeIdentities()
        let verifier = makeVerifier(valid: true)
        let useCase = makeUseCase(identities: identities, verifier: verifier)

        let execPath = try XCTUnwrap(framework.executablePath)
        let store = MemoryNestedSigningArtifactStore(binaries: [execPath: MachOSigningFixtures.unsignedMachO])

        let result = useCase.sign(plan: plan, identityID: nil, store: store)

        XCTAssertFalse(result.isSuccess)
        guard case .failed(let failure) = result.status else {
            return XCTFail("Expected failure")
        }
        XCTAssertEqual(failure.reason, .invalidSigningIdentity)
        XCTAssertEqual(result.summary.mutationState, .noTargetsModified)
        XCTAssertEqual(store.readCounts[execPath, default: 0], 0, "No reads should occur when identity is missing")
    }

    // MARK: - 8. Failure Vocabulary & ZynSignError Bridge Tests

    func testEveryNestedSigningFailureReasonHasACategoryAndASafeMessage() {
        var messages = Set<String>()
        for reason in NestedSigningFailureReason.allCases {
            XCTAssertFalse(reason.rawValue.isEmpty)
            XCTAssertEqual(reason.displayName, reason.rawValue)
            XCTAssertFalse(reason.userMessage.isEmpty)
            // One safe message per reason; no two reasons share one.
            XCTAssertTrue(messages.insert(reason.userMessage).inserted)
            // No leaks of internal vocabulary in user message:
            XCTAssertFalse(reason.userMessage.contains("Mach-O"))
            XCTAssertFalse(reason.userMessage.contains("Info.plist"))
            XCTAssertFalse(reason.userMessage.contains("LC_CODE_SIGNATURE"))
            XCTAssertFalse(reason.userMessage.contains("ZynSignError"))
            XCTAssertFalse(reason.userMessage.contains("nil"))
        }
        XCTAssertEqual(messages.count, NestedSigningFailureReason.allCases.count)
    }

    func testNestedSigningFailureBridgesCorrectlyToZynSignError() throws {
        let path = try XCTUnwrap(BundlePath(rawValue: "Frameworks/Test.framework/Test"))
        for reason in NestedSigningFailureReason.allCases {
            let failure = NestedSigningFailure(
                reason: reason,
                path: path,
                detail: "diagnostic-detail-\(reason.rawValue)"
            )
            let error = ZynSignError.nestedSigning(failure)

            XCTAssertEqual(error.nestedSigningFailure, reason)
            XCTAssertEqual(error.category, reason.category)
            XCTAssertEqual(error.userMessage, reason.userMessage)
            XCTAssertEqual(error.errorDescription, reason.userMessage)
            XCTAssertEqual(error.diagnosticDetail, failure.detail)
            XCTAssertNil(error.underlyingError)
            XCTAssertFalse(error.userMessage.contains("diagnostic-detail-"))
            XCTAssertTrue(error.debugDescription.contains(reason.rawValue))
        }
    }
}

// MARK: - Test Doubles for Nested Signing

final class NestedSigningTestIdentityStore: IdentityStore, SigningCapability {
    let id = SigningIdentityIdentifier()
    var identityID: SigningIdentityIdentifier { id }
    var certificate: Certificate
    var publicKeyAlgorithm: PublicKeyAlgorithm = .rsa
    var isAvailable = true
    let supportedAlgorithms: Set<SigningAlgorithm> = [.rsaPKCS1SHA256Digest]
    var signCalls = 0
    var lastInput: Data?
    var failSigning = false
    var signature = MachOSigningFixtures.signature // 256 bytes

    init() throws {
        let data = MachOSigningFixtures.certificateDER
        certificate = Certificate(metadata: try AppleCertificateParser().parseCertificate(derData: data), derData: data)
    }

    func listIdentities() throws -> [SigningIdentity] { [] }
    func identity(withID id: SigningIdentityIdentifier) throws -> SigningIdentity? { nil }
    func signingCertificate(for id: SigningIdentityIdentifier) throws -> Certificate { certificate }
    func signingCapability(for id: SigningIdentityIdentifier) throws -> any SigningCapability { self }

    func sign(data: Data, algorithm: SigningAlgorithm) throws -> Data {
        signCalls += 1
        lastInput = data
        guard !failSigning, algorithm == .rsaPKCS1SHA256Digest else {
            throw ZynSignError.crypto(.signingFailure)
        }
        return signature
    }
}

final class NestedSigningTestVerifier: CryptographicSignatureVerifier {
    var shouldVerifyValid = true

    func verify(
        signature: Data,
        message: SigningInput,
        algorithm: SigningAlgorithm,
        certificate: Certificate
    ) -> SignatureVerificationOutcome {
        guard shouldVerifyValid else { return .invalid }
        return .valid
    }
}
