import XCTest
@testable import ZynSign

/// Matching, confirmation, history, and the queue. These tests use synthetic
/// fingerprints and bundle identifiers. They do not sign, and they do not
/// touch the Keychain.
final class SigningPresetIntelligenceTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 750_000_000)
    private let fingerprintHex = String(repeating: "ab", count: 32)
    private let otherFingerprintHex = String(repeating: "cd", count: 32)

    func testCompleteMatchScoresTheDocumentedWeightsAndIsRecommended() {
        let app = PresetAppContext(bundleIdentifier: "com.example.app", displayName: "Example")
        let profileID = ProvisioningProfileIdentifier(rawValue: "profile-1")
        let preset = makePreset(name: "Personal", profileID: profileID)
        let inventory = inventory(profiles: [makeProfile(id: profileID)])
        let ranking = SigningPresetMatcher.rank(presets: [preset], for: app, inventory: inventory)
        let match = try! XCTUnwrap(ranking.recommendation)
        XCTAssertEqual(match.preset.id, preset.id)
        XCTAssertTrue(match.isRecommended)
        XCTAssertTrue(match.report.passesPreflight)
        XCTAssertTrue(match.report.isUsable)
        XCTAssertEqual(match.report.overall, .ready)
        XCTAssertEqual(match.score, 95)
        XCTAssertEqual(match.report.certificate.status, .passing)
        XCTAssertEqual(match.report.profile.status, .passing)
        XCTAssertEqual(match.report.expiration.status, .passing)
        XCTAssertEqual(match.report.team.status, .passing)
        XCTAssertEqual(match.report.bundle?.status, .passing)
        XCTAssertTrue(match.report.spokenSummary.contains("Certificate"))
        XCTAssertTrue(match.report.spokenSummary.contains("Profile"))
        XCTAssertTrue(match.report.spokenSummary.contains("Expiration"))
        XCTAssertTrue(match.report.spokenSummary.contains("Team"))
    }

    func testDefaultDoesNotOutrankABundleMismatch() {
        let app = PresetAppContext(bundleIdentifier: "com.example.app", displayName: "Example")
        let covered = ProvisioningProfileIdentifier(rawValue: "covered")
        let other = ProvisioningProfileIdentifier(rawValue: "other")
        let matching = makePreset(name: "Matching", profileID: covered)
        let preferred = makePreset(name: "Default", profileID: other, isDefault: true)
        let inventory = inventory(profiles: [
            makeProfile(id: covered, patterns: ["com.example.*"]),
            makeProfile(id: other, name: "Other", patterns: ["com.other.*"])
        ])
        let ranking = SigningPresetMatcher.rank(presets: [preferred, matching], for: app, inventory: inventory)
        XCTAssertEqual(ranking.matches.first?.preset.id, matching.id)
        XCTAssertEqual(ranking.recommendation?.preset.id, matching.id)
        XCTAssertEqual(ranking.matches.first?.score, 95)
        XCTAssertEqual(ranking.matches.last?.score, 30)
        XCTAssertFalse(ranking.matches.contains { $0.preset.id == preferred.id && $0.isRecommended })
    }

    func testPreviousSuccessOutranksADefaultWithTheSameCompatibility() {
        let app = PresetAppContext(bundleIdentifier: "com.example.app", displayName: "Example")
        let profileID = ProvisioningProfileIdentifier(rawValue: "profile-1")
        var used = makePreset(name: "Used", profileID: profileID)
        used.usage = PresetUsage(
            lastUsedAt: now,
            successfulUses: 1,
            lastSuccessfulBundleIdentifier: app.bundleIdentifier,
            lastSuccessfulDisplayName: "Example"
        )
        let preferred = makePreset(name: "Default", profileID: profileID, isDefault: true)
        let inventory = inventory(profiles: [makeProfile(id: profileID)])
        let ranking = SigningPresetMatcher.rank(presets: [preferred, used], for: app, inventory: inventory)
        XCTAssertEqual(ranking.recommendation?.preset.id, used.id)
        XCTAssertEqual(ranking.matches.first?.score, 117)
        XCTAssertEqual(ranking.matches.last?.score, 100)
    }

    func testExpiredOrMissingCertificateIsNotRecommended() {
        let app = PresetAppContext(bundleIdentifier: "com.example.app", displayName: "Example")
        let profileID = ProvisioningProfileIdentifier(rawValue: "profile-1")
        let expiredProfile = makeProfile(id: profileID, expiration: now.addingTimeInterval(-86_400))
        let expired = makePreset(name: "Expired", profileID: profileID)
        let missing = makePreset(name: "Missing", fingerprint: nil, profileID: profileID)
        let inventory = inventory(profiles: [expiredProfile])
        let ranking = SigningPresetMatcher.rank(presets: [expired, missing], for: app, inventory: inventory)
        XCTAssertNil(ranking.recommendation)
        XCTAssertFalse(ranking.matches.contains { $0.report.passesPreflight })
        XCTAssertEqual(ranking.matches.first { $0.preset.id == expired.id }?.report.expiration.status, .failing)
    }

    func testNoAppMeansNoRecommendationEvenWhenThePresetIsUsable() {
        let profileID = ProvisioningProfileIdentifier(rawValue: "profile-1")
        let preset = makePreset(name: "Personal", profileID: profileID, isDefault: true)
        let ranking = SigningPresetMatcher.rank(
            presets: [preset],
            for: nil,
            inventory: inventory(profiles: [makeProfile(id: profileID)])
        )
        XCTAssertNil(ranking.recommendation)
        XCTAssertFalse(ranking.matches[0].report.passesPreflight)
        XCTAssertTrue(ranking.matches[0].report.isUsable)
    }

    func testSuggestionsStayInsideObservedFacts() {
        let app = PresetAppContext(bundleIdentifier: "com.example.app", displayName: "Example")
        let currentID = ProvisioningProfileIdentifier(rawValue: "current")
        let newerID = ProvisioningProfileIdentifier(rawValue: "newer")
        let otherTeamID = ProvisioningProfileIdentifier(rawValue: "other-team")
        let current = makeProfile(
            id: currentID,
            expiration: now.addingTimeInterval(10 * 86_400)
        )
        let newer = makeProfile(
            id: newerID,
            name: "Newer Profile",
            expiration: now.addingTimeInterval(200 * 86_400)
        )
        let otherTeam = makeProfile(
            id: otherTeamID,
            name: "Other Team",
            team: "ZZZZZ99999",
            expiration: now.addingTimeInterval(400 * 86_400)
        )
        let weaker = makePreset(
            name: "Weaker",
            profileID: currentID,
            verification: .recommended
        )
        var stronger = makePreset(name: "Stronger", profileID: newerID)
        stronger.usage = PresetUsage(
            lastUsedAt: now,
            successfulUses: 3,
            lastSuccessfulBundleIdentifier: app.bundleIdentifier,
            lastSuccessfulDisplayName: app.displayName
        )
        let inventory = inventory(profiles: [current, newer, otherTeam])
        let ranking = SigningPresetMatcher.rank(presets: [weaker, stronger], for: app, inventory: inventory)
        let suggestions = SigningPresetMatcher.suggestions(
            for: weaker,
            inventory: inventory,
            ranking: ranking,
            app: app
        )
        XCTAssertTrue(suggestions.contains { suggestion in
            if case .expiresSoon(let days) = suggestion.kind { return days == 10 }
            return false
        })
        XCTAssertTrue(suggestions.contains { suggestion in
            if case .newerCompatibleProfile(let name) = suggestion.kind { return name == "Newer Profile" }
            return false
        })
        XCTAssertFalse(suggestions.contains { suggestion in
            if case .newerCompatibleProfile(let name) = suggestion.kind { return name == "Other Team" }
            return false
        })
        XCTAssertTrue(suggestions.contains { suggestion in
            if case .betterMatch(let name, _) = suggestion.kind { return name == "Stronger" }
            return false
        })
        XCTAssertTrue(suggestions.contains { $0.kind == .verificationRecommended })
    }

    func testBulkPlanKeepsIncompatibleAppsOutOfTheQueue() {
        let profileID = ProvisioningProfileIdentifier(rawValue: "profile-1")
        let preset = makePreset(name: "Personal", profileID: profileID)
        let covered = PresetBulkSubject(
            id: "covered",
            bundleIdentifier: "com.example.app",
            displayName: "Covered",
            artifactAvailable: true
        )
        let uncovered = PresetBulkSubject(
            id: "uncovered",
            bundleIdentifier: "com.other.app",
            displayName: "Other",
            artifactAvailable: true
        )
        let missing = PresetBulkSubject(
            id: "missing",
            bundleIdentifier: "com.example.gone",
            displayName: "Missing",
            artifactAvailable: false
        )
        let plan = SigningPresetMatcher.bulkPlan(
            preset: preset,
            subjects: [covered, uncovered, missing],
            inventory: inventory(profiles: [makeProfile(id: profileID)])
        )
        XCTAssertEqual(plan.compatible.map(\.id), ["covered"])
        XCTAssertEqual(Set(plan.needsAttention.map(\.id)), ["uncovered", "missing"])
        XCTAssertFalse(plan.queuesIncompatibleApps)
        XCTAssertFalse(plan.needsAttention.flatMap(\.reasons).isEmpty)
    }

    func testImportOfferRequiresAPassingPresetAndDoesNotInventATitleForAMiss() {
        let app = PresetAppContext(bundleIdentifier: "com.example.app", displayName: "Example")
        let profileID = ProvisioningProfileIdentifier(rawValue: "profile-1")
        let ready = SigningPresetMatcher.importReadiness(
            app: app,
            presets: [makePreset(name: "Personal", profileID: profileID)],
            inventory: inventory(profiles: [makeProfile(id: profileID)])
        )
        XCTAssertTrue(ready.isReadyToSign)
        XCTAssertEqual(ready.title, "Ready to Sign")
        XCTAssertTrue(ready.detail.contains("confirmation"))
        let blocked = SigningPresetMatcher.importReadiness(
            app: PresetAppContext(bundleIdentifier: "com.other.app", displayName: "Other"),
            presets: [makePreset(name: "Personal", profileID: profileID)],
            inventory: inventory(profiles: [makeProfile(id: profileID)])
        )
        XCTAssertFalse(blocked.isReadyToSign)
        XCTAssertNil(blocked.recommendation)
    }

    func testConfirmationGateRefusesAnUnacknowledgedOrFailingPreset() {
        let unacked = PresetSignConfirmation(
            presetID: PresetIdentifier(),
            bundleIdentifier: "com.example.app",
            passesPreflight: true,
            acknowledged: false
        )
        XCTAssertFalse(unacked.mayExecute)
        assertThrows(ZynSignError.presetConfirmationRequired().userMessage) {
            try PresetSignConfirmationGate.validate(unacked)
        }
        let blocked = PresetSignConfirmation(
            presetID: PresetIdentifier(),
            bundleIdentifier: "com.example.app",
            passesPreflight: false,
            acknowledged: true
        )
        XCTAssertFalse(blocked.mayExecute)
        assertThrows(ZynSignError.presetNotReady(
            userMessage: "That preset does not pass preflight for this app, so it was not signed."
        ).userMessage) {
            try PresetSignConfirmationGate.validate(blocked)
        }
        let allowed = PresetSignConfirmation(
            presetID: PresetIdentifier(),
            bundleIdentifier: "com.example.app",
            passesPreflight: true,
            acknowledged: true
        )
        XCTAssertTrue(allowed.mayExecute)
        XCTAssertNoThrow(try PresetSignConfirmationGate.validate(allowed))
    }

    func testStoredScheduleNeverStartsWork() {
        let schedule = PresetSchedule(isEnabled: true, hour: 2, minute: 0, weekday: 1, note: "nightly")
        XCTAssertFalse(PresetAutomation.shouldRun(schedule: schedule, at: now))
        XCTAssertFalse(PresetAutomation.shouldRun(schedule: nil, at: now))
        let stored = PresetDistribution(scope: .team, revision: 3, schedule: schedule, automationLabel: "hook")
        XCTAssertFalse(stored.willExecuteAutomatically)
    }

    func testTemplatesDoNotFillCertificateOrProfileReferences() {
        for template in PresetTemplate.allCases {
            let draft = template.makeDraft(now: now)
            XCTAssertNil(draft.certificateFingerprint)
            XCTAssertNil(draft.provisioningProfileName)
            XCTAssertNil(draft.provisioningProfileID)
            XCTAssertEqual(draft.usage, .empty)
            XCTAssertFalse(draft.distribution.willExecuteAutomatically)
        }
    }

    func testBuilderBackChangesOnlyTheStep() {
        var draft = PresetTemplate.personalDevelopment.makeDraft(now: now)
        draft.name = "Kept"
        var session = PresetBuilderSession(step: 3, draft: draft)
        session.goBack()
        XCTAssertEqual(session.step, 2)
        XCTAssertEqual(session.draft.name, "Kept")
        XCTAssertNil(session.draft.certificateFingerprint)
        session.goForward(maximum: 5)
        XCTAssertEqual(session.step, 3)
        XCTAssertEqual(session.draft.name, "Kept")
    }

    func testEncodedPresetCarriesReferencesAndNotSecrets() throws {
        let fingerprint = CertificateFingerprint(hexDigest: fingerprintHex)!
        let preset = SigningPreset(
            name: "Personal",
            certificateFingerprint: fingerprint,
            provisioningProfileName: "Dev Profile",
            teamIdentifier: "ABCDE12345",
            usage: PresetUsage(
                lastUsedAt: now,
                successfulUses: 2,
                failedUses: 1,
                lastSuccessfulBundleIdentifier: "com.example.app",
                lastSuccessfulDisplayName: "Example"
            ),
            createdAt: now,
            updatedAt: now
        )
        let data = try JSONEncoder().encode(preset)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(fingerprintHex))
        XCTAssertTrue(text.contains("Dev Profile"))
        XCTAssertTrue(text.contains("com.example.app"))
        for forbidden in ["privateKey", "password", "BEGIN ", "p12", "outputFileName", "Documents/"] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(forbidden), forbidden)
        }
        let decoded = try JSONDecoder().decode(SigningPreset.self, from: data)
        XCTAssertEqual(decoded, preset)
    }

    private func makePreset(
        name: String,
        fingerprint: CertificateFingerprint? = CertificateFingerprint(hexDigest: String(repeating: "ab", count: 32)),
        profileID: ProvisioningProfileIdentifier,
        isDefault: Bool = false,
        verification: SigningPreset.VerificationPreference = .always
    ) -> SigningPreset {
        SigningPreset(
            name: name,
            certificateFingerprint: fingerprint,
            provisioningProfileName: "Dev Profile",
            provisioningProfileID: profileID,
            teamIdentifier: "ABCDE12345",
            verificationPreference: verification,
            isDefault: isDefault,
            createdAt: now,
            updatedAt: now
        )
    }

    private func makeProfile(
        id: ProvisioningProfileIdentifier,
        name: String = "Dev Profile",
        team: String = "ABCDE12345",
        patterns: [String] = ["com.example.*"],
        expiration: Date? = nil
    ) -> PresetInventory.Profile {
        PresetInventory.Profile(
            id: id,
            name: name,
            teamIdentifier: team,
            bundleIdentifierPatterns: patterns,
            expirationDate: expiration ?? now.addingTimeInterval(400 * 86_400),
            sourceFileName: "\(id.rawValue).mobileprovision",
            fileIsPresent: true
        )
    }

    private func inventory(profiles: [PresetInventory.Profile]) -> PresetInventory {
        PresetInventory(
            certificates: [
                PresetInventory.Certificate(
                    fingerprint: CertificateFingerprint(hexDigest: fingerprintHex)!,
                    displayName: "Test Cert",
                    teamIdentifier: "ABCDE12345",
                    isUsable: true,
                    notValidBefore: now.addingTimeInterval(-86_400),
                    notValidAfter: now.addingTimeInterval(400 * 86_400)
                )
            ],
            profiles: profiles,
            now: now
        )
    }

    private func assertThrows(_ message: String, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body()) { error in
            XCTAssertEqual((error as? ZynSignError)?.userMessage, message)
        }
    }
}

final class SigningPresetWorkflowTests: XCTestCase {

    private var directory: URL!
    private let now = Date(timeIntervalSinceReferenceDate: 750_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZynSignPresetWorkflow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testCreateDuplicateDefaultAndHistoryDoNotStoreSecrets() async throws {
        let harness = try await makeHarness()
        let created = try await harness.workflow.create(harness.draft(name: "Personal", isDefault: false))
        XCTAssertTrue(created.isDefault)
        let second = try await harness.workflow.create(harness.draft(name: "Testing", isDefault: false))
        XCTAssertFalse(second.isDefault)
        try await harness.workflow.setDefault(id: second.id)
        let listed = try await harness.workflow.allPresets()
        XCTAssertEqual(listed.first { $0.id == second.id }?.isDefault, true)
        XCTAssertEqual(listed.first { $0.id == created.id }?.isDefault, false)
        try await harness.workflow.record(PresetUseOutcome(
            presetID: created.id,
            result: .succeeded,
            bundleIdentifier: "com.example.app",
            displayName: "Example",
            at: now
        ))
        try await harness.workflow.record(PresetUseOutcome(
            presetID: created.id,
            result: .cancelled,
            bundleIdentifier: "com.example.app",
            displayName: "Example",
            at: now
        ))
        let used = try await harness.presets.preset(withID: created.id)
        XCTAssertEqual(used?.usage.successfulUses, 1)
        XCTAssertEqual(used?.usage.failedUses, 0)
        XCTAssertEqual(used?.usage.lastSuccessfulBundleIdentifier, "com.example.app")
        let copy = try await harness.workflow.duplicate(id: created.id)
        XCTAssertNotEqual(copy.id, created.id)
        XCTAssertFalse(copy.isDefault)
        XCTAssertEqual(copy.usage, .empty)
        XCTAssertEqual(copy.certificateFingerprint, created.certificateFingerprint)
        XCTAssertNil(copy.distribution.schedule)
        let recommendation = try await harness.workflow.recommendation(
            for: PresetAppContext(bundleIdentifier: "com.example.app", displayName: "Example")
        )
        XCTAssertNotNil(recommendation)
        let afterOffer = try await harness.presets.preset(withID: created.id)
        XCTAssertEqual(afterOffer?.usage.successfulUses, 1, "Offering a preset must not count as a use.")
    }

    func testSaveKeepsUsageAndDoesNotStartAStoredSchedule() async throws {
        let harness = try await makeHarness()
        var draft = harness.draft(name: "Personal", isDefault: true)
        draft.distribution = PresetDistribution(
            scope: .local,
            revision: 1,
            schedule: PresetSchedule(isEnabled: true, hour: 1, minute: 0, weekday: 2, note: "later"),
            automationLabel: "nightly"
        )
        let created = try await harness.workflow.create(draft)
        try await harness.workflow.record(PresetUseOutcome(
            presetID: created.id,
            result: .failed,
            bundleIdentifier: "com.example.app",
            displayName: "Example",
            at: now
        ))
        var edited = created
        edited.name = "Personal Renamed"
        let saved = try await harness.workflow.save(edited)
        XCTAssertEqual(saved.usage.failedUses, 1)
        XCTAssertEqual(saved.distribution.schedule?.note, "later")
        XCTAssertEqual(saved.distribution.automationLabel, "nightly")
        XCTAssertFalse(saved.distribution.willExecuteAutomatically)
        XCTAssertGreaterThan(saved.distribution.revision, created.distribution.revision)
    }

    func testProfileBytesRejectPathEscapeAndQueueOmitsAttentionApps() async throws {
        let harness = try await makeHarness()
        let escaped = ProvisioningProfileSummary(
            name: "Escaped",
            teamIdentifier: "ABCDE12345",
            bundleIdentifierPatterns: ["com.example.*"],
            expirationDate: now.addingTimeInterval(400 * 86_400),
            entitlementsKeys: [],
            allowsDebug: true,
            sourceFileName: "../secret",
            importedAt: now
        )
        XCTAssertThrowsError(try harness.workflow.profileBytes(for: escaped))
        let created = try await harness.workflow.create(harness.draft(name: "Personal", isDefault: true))
        let covered = LibraryFixtures.record(
            identity: LibraryFixtures.identity(bundleIdentifier: "com.example.app", displayName: "Covered")
        )
        let other = LibraryFixtures.record(
            identity: LibraryFixtures.identity(bundleIdentifier: "com.other.app", displayName: "Other")
        )
        try Data([0x01]).write(to: harness.artifactURL(covered.artifact.artifactID))
        let entries = [
            LibraryEntry(record: covered, artifactAvailability: .available),
            LibraryEntry(record: other, artifactAvailability: .available)
        ]
        let plan = try await harness.workflow.bulkPlan(
            preset: created,
            subjects: entries.map { $0.presetSubject() }
        )
        XCTAssertEqual(plan.compatible.map(\.id), [covered.id.rawValue])
        XCTAssertEqual(plan.needsAttention.map(\.id), [other.id.rawValue])
        XCTAssertFalse(plan.queuesIncompatibleApps)
        let requests = try await harness.workflow.executionRequests(
            for: plan,
            entries: entries,
            outputDirectory: directory
        )
        XCTAssertEqual(Set(requests.keys), [covered.id.rawValue])
        XCTAssertFalse(requests.keys.contains(other.id.rawValue))
    }

    private func makeHarness() async throws -> Harness {
        let presets = MemoryPresetStore()
        let profiles = MemoryProfileLibrary()
        let profileID = ProvisioningProfileIdentifier(rawValue: "profile-1")
        let fileName = "Dev.mobileprovision"
        let plist = try PropertyListSerialization.data(
            fromPropertyList: [String: String](),
            format: .xml,
            options: 0
        )
        try plist.write(to: directory.appendingPathComponent(fileName))
        let summary = ProvisioningProfileSummary(
            id: profileID,
            name: "Dev Profile",
            teamIdentifier: "ABCDE12345",
            bundleIdentifierPatterns: ["com.example.*"],
            expirationDate: now.addingTimeInterval(400 * 86_400),
            entitlementsKeys: [],
            allowsDebug: true,
            sourceFileName: fileName,
            importedAt: now
        )
        try await profiles.upsert(summary)
        let fingerprint = CertificateFingerprint(hexDigest: String(repeating: "ab", count: 32))!
        let identity = SigningIdentity(
            certificate: CertificateMetadata(
                subject: CertificateDistinguishedName(commonName: "Test Cert", rawRepresentation: "CN=Test Cert"),
                issuer: CertificateDistinguishedName(commonName: "Test CA", rawRepresentation: "CN=Test CA"),
                serialNumber: CertificateSerialNumber(hexadecimal: "01")!,
                notValidBefore: now.addingTimeInterval(-86_400),
                notValidAfter: now.addingTimeInterval(400 * 86_400),
                publicKeyInfo: PublicKeyInfo(algorithm: .rsa, keySizeInBits: 2048),
                signatureAlgorithm: .sha256WithRSAEncryption,
                sha256Fingerprint: fingerprint
            ),
            keyAvailability: .available,
            association: .matched,
            capabilityState: .ready
        )
        let root = directory!
        let artifactURL = { (id: ArtifactIdentifier) in
            root.appendingPathComponent("\(id.rawValue).ipa")
        }
        let workflow = SigningPresetWorkflow(
            presets: presets,
            profiles: profiles,
            identities: ListingIdentityStore(identities: [identity]),
            profileDirectory: root,
            artifactURL: artifactURL,
            now: { [now] in now }
        )
        return Harness(
            workflow: workflow,
            presets: presets,
            profileID: profileID,
            fingerprint: fingerprint,
            artifactURL: artifactURL,
            now: now
        )
    }

    private struct Harness {
        let workflow: SigningPresetWorkflow
        let presets: MemoryPresetStore
        let profileID: ProvisioningProfileIdentifier
        let fingerprint: CertificateFingerprint
        let artifactURL: (ArtifactIdentifier) -> URL
        let now: Date

        func draft(name: String, isDefault: Bool) -> SigningPreset {
            SigningPreset(
                name: name,
                certificateFingerprint: fingerprint,
                provisioningProfileName: "Dev Profile",
                provisioningProfileID: profileID,
                teamIdentifier: "ABCDE12345",
                isDefault: isDefault,
                createdAt: now,
                updatedAt: now
            )
        }
    }
}

@MainActor
final class ProfessionalSigningQueueTests: XCTestCase {

    func testStageDoesNotRunAndAttentionJobsAreNeverStarted() async throws {
        let log = CallLog()
        let queue = ProfessionalSigningQueue { step in
            log.ids.append(step.id)
            return .succeeded(outputFileName: "out.ipa")
        }
        let presetID = PresetIdentifier()
        let plan = PresetBulkPlan(
            presetID: presetID,
            presetName: "Personal",
            compatible: [PresetBulkItem(id: "ok", displayName: "Covered", bundleIdentifier: "com.example.app", reasons: [])],
            needsAttention: [PresetBulkItem(id: "no", displayName: "Other", bundleIdentifier: "com.other.app", reasons: ["The profile does not cover com.other.app."])]
        )
        let prepared = [ "ok": dummyRequest(id: "ok", presetID: presetID) ]
        try queue.stage(plan: plan, requests: prepared)
        XCTAssertEqual(queue.phase, .review)
        XCTAssertTrue(log.ids.isEmpty)
        await queue.confirmAndStart()
        XCTAssertEqual(log.ids, ["ok"])
        XCTAssertEqual(queue.phase, .finished)
        XCTAssertEqual(queue.jobs.first { $0.id == "no" }?.state, .needsAttention(reasons: ["The profile does not cover com.other.app."]))
        XCTAssertEqual(queue.jobs.first { $0.id == "ok" }?.state, .succeeded(outputFileName: "out.ipa"))
    }

    func testStagingAnAttentionRequestRefusesAndLeavesTheQueueIdle() async {
        let log = CallLog()
        let queue = ProfessionalSigningQueue { step in
            log.ids.append(step.id)
            return .succeeded(outputFileName: "out.ipa")
        }
        let presetID = PresetIdentifier()
        let plan = PresetBulkPlan(
            presetID: presetID,
            presetName: "Personal",
            compatible: [],
            needsAttention: [PresetBulkItem(id: "no", displayName: "Other", bundleIdentifier: "com.other.app", reasons: ["Manual"])]
        )
        XCTAssertThrowsError(try queue.stage(
            plan: plan,
            requests: ["no": dummyRequest(id: "no", presetID: presetID)]
        )) { error in
            XCTAssertEqual(
                (error as? ZynSignError)?.userMessage,
                "An application that needs manual attention was not queued."
            )
        }
        XCTAssertEqual(queue.phase, .idle)
        XCTAssertTrue(queue.jobs.isEmpty)
        await queue.confirmAndStart()
        XCTAssertTrue(log.ids.isEmpty)
    }

    private func dummyRequest(id: String, presetID: PresetIdentifier) -> SigningQueueStepRequest {
        let entry = LibraryEntry(record: LibraryFixtures.record(), artifactAvailability: .available)
        let entitlements = try! CodeSigningEntitlements(values: [:])
        return SigningQueueStepRequest(
            id: id,
            entry: entry,
            presetID: presetID,
            certificateFingerprint: nil,
            request: SignApplicationRequest(
                sourceURL: URL(fileURLWithPath: "/tmp/in.ipa"),
                profile: Data([0x01]),
                identityID: SigningIdentityIdentifier(),
                entitlements: entitlements,
                outputURL: URL(fileURLWithPath: "/tmp/out.ipa")
            )
        )
    }
}

private final class CallLog: @unchecked Sendable {
    var ids: [String] = []
}

private struct ListingIdentityStore: IdentityStore {
    var identities: [SigningIdentity]
    func listIdentities() throws -> [SigningIdentity] { identities }
    func identity(withID id: SigningIdentityIdentifier) throws -> SigningIdentity? {
        identities.first { $0.id == id }
    }
    func signingCapability(for id: SigningIdentityIdentifier) throws -> any SigningCapability {
        throw ZynSignError.presetNotReady()
    }
}

private actor MemoryPresetStore: SigningPresetStore {
    private var presets: [PresetIdentifier: SigningPreset] = [:]
    func allPresets() async throws -> [SigningPreset] { Array(presets.values) }
    func preset(withID id: PresetIdentifier) async throws -> SigningPreset? { presets[id] }
    func upsert(_ preset: SigningPreset) async throws { presets[preset.id] = preset }
    func remove(presetWithID id: PresetIdentifier) async throws { presets[id] = nil }
    func count() async throws -> Int { presets.count }
}

private actor MemoryProfileLibrary: ProvisioningProfileLibrary {
    private var profiles: [ProvisioningProfileIdentifier: ProvisioningProfileSummary] = [:]
    func allProfiles() async throws -> [ProvisioningProfileSummary] { Array(profiles.values) }
    func profile(withID id: ProvisioningProfileIdentifier) async throws -> ProvisioningProfileSummary? { profiles[id] }
    func upsert(_ summary: ProvisioningProfileSummary) async throws { profiles[summary.id] = summary }
    func remove(profileWithID id: ProvisioningProfileIdentifier) async throws { profiles[id] = nil }
    func count() async throws -> Int { profiles.count }
}
