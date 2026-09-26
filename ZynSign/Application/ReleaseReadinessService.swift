import Foundation

/// Composes independent evidence sources. Never consults the signing run's
/// success flag. Binary bytes are processed off the UI actor, one target at
/// a time; only small, redacted observations survive the pass.
actor ReleaseReadinessService {
    let history: ReleaseReadinessHistory
    private let diagnostics: SigningDiagnosticsService
    private let exports: ExportCenter
    private let operations: SigningOperationCenter
    private let binary: IPABinaryInspection
    private let bundles: IPABundleContentsInspection
    private let library: ApplicationLibrary
    private let identities: any IdentityStore

    init(diagnostics: SigningDiagnosticsService, exports: ExportCenter,
         operations: SigningOperationCenter, binary: IPABinaryInspection,
         history: ReleaseReadinessHistory, bundles: IPABundleContentsInspection,
         library: ApplicationLibrary, identities: any IdentityStore) {
        self.diagnostics = diagnostics
        self.exports = exports
        self.operations = operations
        self.binary = binary
        self.history = history
        self.bundles = bundles
        self.library = library
        self.identities = identities
    }

    struct Result {
        let report: ReleaseReadinessReport
        let historyUnavailable: Bool
    }

    func validate(recordID: ApplicationRecordIdentifier, identityID: SigningIdentityIdentifier?,
                  profileData: Data?, exportID: ExportIdentifier?,
                  defaultIdentityAvailable: Bool?, force: Bool = true) async throws -> Result {
        // Expiration and identity/profile policy are evaluated on every pass.
        // Only unchanged input archive inspection can use the diagnostics'
        // bounded 60-second cache. Full validation always bypasses it.
        let analysis = try await diagnostics.analyze(recordWithID: recordID,
            identityID: identityID, profileData: profileData, force: force)
        var checks = Self.inputChecks(analysis.report)
        checks.append(Self.check("defaultIdentity", .identity,
            defaultIdentityAvailable == true ? .verified : .warning,
            "Default identity health",
            defaultIdentityAvailable == true
                ? "The saved default resolves to a currently available signing identity."
                : "No healthy saved default was established. The explicitly selected identity is checked separately.",
            "Default registration and key availability only; not trust or signing authorization.",
            "Review the default in the Certificate & Identity Center."))
        checks.append(Self.check("platformBoundary", .signature, .unsupported,
            "Production compatibility is not established", ReleaseReadinessReport.boundary,
            "Local cryptographic checks cannot establish Apple's acceptance policy.",
            "Resolve the external-validation limitations and test the exported IPA on supported devices before Beta."))

        // Structure failure is terminal for output inspection; skipped stages
        // remain visible and cannot earn points.
        if checks.contains(where: { $0.category == .structure && $0.state == .blocked }) {
            checks.append(Self.check("structureStop", .package, .notChecked,
                "Output validation skipped", "Critical input structure checks failed.",
                "The produced IPA and its signatures were not scanned.", "Repair or reimport the app, then run full validation."))
            checks.append(Self.missingSignature("structureStopSignature"))
        } else {
            checks += try await entitlementChecks(recordID: recordID, identityID: identityID, profileData: profileData)
            if let exportID {
                guard let entry = try await exports.entry(withID: exportID),
                      entry.record.sourceRecordIdentifier == recordID.rawValue else {
                    throw ValidationError.exportDoesNotBelongToApp
                }
                try Task.checkCancellation()
                let before = try await measureOutput(entry.fileURL)
                if before == nil {
                    checks.append(Self.check("exportMeasurementUnavailable", .package, .unsupported,
                        "Export fingerprint unavailable", "The produced IPA could not be fingerprinted.",
                        "Export integrity was not established; availability and structure checks still run.",
                        "Restore a readable exported IPA and rescan."))
                }
                // Reopens the final exported IPA and independently reads layout,
                // metadata, nested signatures, profile, seal and sealed resources.
                let output = try await operations.verifyExportedArtifact(withID: exportID)
                checks += output.report.findings.enumerated().map { index, finding in
                    let state: ReleaseCheckState
                    switch finding.severity {
                    case .note: state = .verified
                    case .warning: state = .warning
                    case .error: state = .blocked
                    case .unsupported: state = .unsupported
                    }
                    // Do not persist the verifier's dynamic paths or identifiers.
                    return Self.check("output.\(index).\(finding.code.rawValue)", .package, state,
                        "IPA: \(finding.code.readinessTitle)",
                        "\(finding.code.readinessScope) Result: \(state.title.lowercased()).",
                        "Rule: \(finding.code.rawValue). Independently reopened output; no signing-state assumption. Open Export Center for detailed evidence.",
                        state == .verified ? "No action for this check." : "Inspect this finding in Export Center, correct the artifact and rescan.")
                }
                let structurallyBlocked = output.report.findings.contains {
                    [.containerUnreadable, .containerStructure, .bundleInformation, .executableMissing, .artifactUnavailable].contains($0.code)
                        && $0.severity != .note
                }
                if !structurallyBlocked, let url = entry.fileURL {
                    var completed = 0
                    do {
                        for try await event in binary.inspectBundle(.signedPackage(url)) {
                            try Task.checkCancellation()
                            switch event {
                            case .discovered(let overview):
                                if overview.omittedTargetCount > 0 || overview.targets.isEmpty {
                                    checks.append(Self.check("nestedCoverage", .signature, .unsupported,
                                        "Incomplete executable coverage", "Not every executable could be inspected.",
                                        "The bounded discovery pass omitted targets or found none.", "Inspect nested code in Binary & Signature Inspector."))
                                }
                            case .completed(let report):
                                completed += 1
                                if let integrity = report.integrity {
                                    for check in integrity.checks where check.kind != .certificateTrust {
                                        let state: ReleaseCheckState
                                        switch check.status {
                                        case .passed: state = .verified
                                        case .warning: state = .warning
                                        case .failed: state = .blocked
                                        case .notPerformed, .notApplicable: state = .unsupported
                                        }
                                        checks.append(Self.check("binary.\(completed).\(check.kind.rawValue)", .signature, state,
                                            "Executable \(completed): \(check.kind.title)", check.kind.explanation,
                                            "Independent byte verification: \(state.title). Details available in Binary & Signature Inspector.",
                                            state == .verified ? "No action for this check." : "Review the executable's verification details; repair or use a supported signing configuration."))
                                    }
                                } else {
                                    checks.append(Self.missingSignature("binary.\(completed)"))
                                }
                            case .unavailable:
                                checks.append(Self.missingSignature("unavailable.\(checks.count)"))
                            default: break
                            }
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { checks.append(Self.missingSignature("binaryReadFailure")) }
                    if completed == 0 { checks.append(Self.missingSignature("noCompletedTargets")) }
                } else {
                    checks.append(Self.missingSignature("outputUnavailable"))
                }
                if let url = entry.fileURL, let before {
                    let after = try await measureOutput(url)
                    let stable = after == before
                    let matches = after.flatMap { measurement in
                        entry.record.fingerprint.map { $0 == ExportFingerprint(measurement.fingerprint) }
                    }
                    checks.append(Self.check("exportFingerprint", .package,
                        !stable || matches == false ? .blocked : (matches == true ? .verified : .unsupported),
                        "Export content integrity",
                        "The final archive was fingerprinted before and after validation and compared with its export record.",
                        "A size match alone is not proof of unchanged bytes. Missing recorded fingerprints remain unsupported.",
                        stable && matches == true ? "No action for this check." : "Re-export from intact inputs and rescan without modifying the IPA."))
                }
            } else {
                checks.append(Self.check("noExport", .package, .notChecked,
                    "No produced IPA selected", "Input health is not output verification.",
                    "No final archive, export integrity or output signature was checked.",
                    "Sign and export this app, select its produced IPA, then validate again."))
                checks.append(Self.missingSignature("noOutputSignature"))
            }
        }
        try Task.checkCancellation()
        let report = ReleaseReadinessReport(id: UUID(), recordID: recordID.rawValue,
            exportID: exportID?.rawValue, validatedAt: Date(), checks: checks)
        do {
            try await history.append(report)
            return Result(report: report, historyUnavailable: false)
        } catch is CancellationError { throw CancellationError() }
        catch {
            return Result(report: report, historyUnavailable: true)
        }
    }

    private func measureOutput(_ url: URL?) async throws -> StagedExportMeasurement? {
        try Task.checkCancellation()
        guard let url else { return nil }
        do { return try await exports.measure(url) }
        catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }

    private func entitlementChecks(recordID: ApplicationRecordIdentifier,
                                   identityID: SigningIdentityIdentifier?, profileData: Data?) async throws -> [ReleaseReadinessCheck] {
        do {
            guard let entry = try await library.entry(withID: recordID) else { return [] }
            let targets = try await bundles.inspectEntitlements(recordWithID: recordID)
            let profile = try profileData.map { try EntitlementsStudioInspection.parseProfile($0) }
            let team = try identityID.flatMap { try identities.identity(withID: $0)?.certificate.subject.organizationalUnit }
            guard !targets.isEmpty else { throw EntitlementsError.notRepresentable }
            return targets.map { target in
                let analysis = EntitlementsStudioAnalyzer.analyze(app: target.entitlements,
                    profile: profile, bundleID: entry.record.bundleIdentifier,
                    certificateTeam: team, emitDER: false, sourceNote: target.note)
                // Authenticity is established separately by diagnostics, not
                // by Studio's declaration comparison. Unknown capability
                // interpretations are still surfaced and receive no credit.
                let relevant = analysis.findings.filter { $0.id != "authenticity" }
                let state: ReleaseCheckState = relevant.contains { $0.status == .blocked } ? .blocked
                    : relevant.contains { $0.status == .unknown } ? .unsupported
                    : relevant.contains { $0.status == .warning } ? .warning : .verified
                return Self.check("studio.\(target.id)", .entitlements, state,
                    "Entitlements Studio: architecture \(target.id + 1)",
                    "Capability mapping, missing matches and supported profile comparisons: \(state.title.lowercased()).",
                    "Uses the Studio analyzer on main-executable declarations. Nested entitlement authorization and DER-only decoding are not established.",
                    state == .verified ? "No action for supported main-executable comparisons." : "Open Entitlements Studio to review capability conflicts and unsupported combinations.")
            } + [Self.check("nestedEntitlements", .entitlements, .unsupported,
                "Nested entitlement authorization", "The Studio comparison covers main-executable architectures only.",
                "Nested signature verification does not prove provisioning authorization for every nested capability.",
                "Review nested provisioning and capability requirements before release.")]
        } catch is CancellationError { throw CancellationError() }
        catch {
            return [Self.check("studioUnavailable", .entitlements, .unsupported,
                "Entitlements Studio comparison unavailable", "App claims or profile declarations could not be read within supported limits.",
                "Unknown claims are not an empty entitlement set.", "Choose readable inputs and review Entitlements Studio.")]
        }
    }

    private static func missingSignature(_ id: String) -> ReleaseReadinessCheck {
        check(id, .signature, .notChecked, "Output signature not fully verified",
              "Independent signature evidence is incomplete.",
              "Missing or unsupported output is never counted as a pass.",
              "Select a readable produced IPA and inspect all executable targets.")
    }

    static func inputChecks(_ report: SigningDiagnosticsReport) -> [ReleaseReadinessCheck] {
        report.checks.compactMap { item in
            let category: ReleaseReadinessCategory
            switch item.area {
            case .package, .metadata, .executable, .nestedCode: category = .structure
            case .certificate: category = .identity
            case .profile, .bundleIdentifier, .teamIdentifier: category = .profile
            case .entitlements, .signingOptions: category = .entitlements
            case .existingSignature: return nil // structure inspection is not verification
            }
            let state: ReleaseCheckState
            switch item.state {
            case .passed: state = .verified
            case .attention: state = .warning
            case .blocked: state = .blocked
            case .notChecked: state = .notChecked
            case .unsupported: state = .unsupported
            }
            let issues = report.issues.filter { $0.area == item.area }
            return check("input.\(item.area.rawValue)", category, state,
                item.area.title, issues.map(\.explanation).joined(separator: " "),
                item.area.verificationScope + " " + issues.map(\.technicalDetails).joined(separator: " "),
                issues.isEmpty ? "No action for this check." : issues.map(\.suggestedAction).joined(separator: " "))
        }
    }

    private static func check(_ id: String, _ category: ReleaseReadinessCategory,
                              _ state: ReleaseCheckState, _ title: String,
                              _ explanation: String, _ technical: String, _ action: String) -> ReleaseReadinessCheck {
        ReleaseReadinessCheck(id: id, category: category, state: state, title: title,
            explanation: explanation, technicalDetails: technical, nextAction: action)
    }
    enum ValidationError: Error { case exportDoesNotBelongToApp }
}

private extension ArtifactVerificationFindingCode {
    var readinessTitle: String {
        // Human-readable fixed rule names, never package-supplied strings.
        var title = ""
        for character in rawValue {
            if character.isUppercase { title.append(" ") }
            title.append(character)
        }
        return title.prefix(1).uppercased() + String(title.dropFirst())
    }
    var readinessScope: String {
        switch self {
        case .artifactUnavailable:
            return "The exported artifact must be present and available in export storage."
        case .containerUnreadable, .containerStructure:
            return "The archive must be readable and contain a consistent Payload application layout."
        case .bundleInformation:
            return "The bundle information file must be readable and declare supported app metadata."
        case .executableMissing, .executableUnreadable, .executableFormat:
            return "The declared executable must exist and be readable within supported Mach-O inspection limits."
        case .mainSignature, .signatureStructure, .codeDirectory, .codeDirectoryIdentifier:
            return "The output executable must carry a readable signature and a CodeDirectory consistent with its bundle identifier."
        case .entitlements:
            return "The embedded entitlement slot must be decodable; decoding alone does not establish profile authorization."
        case .resourceSeal, .sealedResourceDigest, .sealedResourceUnreadable, .sealCoverage:
            return "The resource seal and covered file digests are rechecked within the verifier's read and coverage limits."
        case .nestedCode:
            return "Discovered nested code is inspected for its own signature."
        case .embeddedProfile, .embeddedProfileIdentifier:
            return "The embedded provisioning profile must be readable and compatible with the output bundle identifier."
        case .embeddedProfileExpiry:
            return "The embedded provisioning profile's validity period is compared with the validation time."
        case .embeddedProfileAuthenticity:
            return "Parsing the embedded provisioning profile does not establish the authenticity of its container."
        case .trustNotEvaluated:
            return "Certificate trust and platform authorization are not established by this artifact verifier."
        }
    }
}
