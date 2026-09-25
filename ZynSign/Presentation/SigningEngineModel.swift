import Foundation
import SwiftUI

/// Drives one signing run for the signing screen.
///
/// The model owns the run's lifetime — starting it, publishing progress to
/// the main actor, cancelling it, re-verifying a delivered container, and
/// exposing the result — while the engine owns the pipeline's order and its
/// safety. The model holds no signing material of its own beyond the request
/// it was asked to run.
@MainActor
final class SigningEngineModel: ObservableObject {

    /// The latest progress snapshot, or `nil` before a run starts.
    @Published private(set) var progress: SigningEngineProgress?

    /// The finished run's result, on either path.
    @Published private(set) var result: SigningEngineResult?

    /// Whether the engine is running.
    @Published private(set) var isRunning = false

    /// The independent re-verification of a delivered container, when the
    /// user asks for one.
    @Published private(set) var reVerification: VerifySignedApplicationReport?

    /// Whether a re-verification is running.
    @Published private(set) var isReVerifying = false

    /// Why a re-verification could not run or did not hold up.
    @Published private(set) var reVerificationMessage: String?

    /// Whether the user asked for the result's details.
    @Published var isPresentingDetails = false

    private var runTask: Task<Void, Never>?

    init() {}

    /// The stage records to render, in execution order. Before a run starts
    /// every stage is pending, so the table is legible from the first frame.
    var stageRecords: [SigningEngineStageRecord] {
        progress?.records ?? SigningEngineStage.allCases.map { stage in
            SigningEngineStageRecord(
                stage: stage,
                state: .pending,
                completedItemCount: 0,
                totalItemCount: 0,
                detail: nil
            )
        }
    }

    /// The delivered container's location, when the run succeeded.
    var outputURL: URL? { result?.outputURL }

    /// Whether a container was delivered and can be exported, re-verified, or
    /// delivered to another device.
    var hasOutput: Bool { outputURL != nil }

    /// Starts one run and updates the model as it advances.
    ///
    /// - Parameters:
    ///   - request: The run's inputs.
    ///   - environment: The environment the engine is reached through.
    func run(_ request: SigningEngineRequest, environment: ApplicationEnvironment) {
        guard !isRunning else { return }
        isRunning = true
        result = nil
        progress = nil
        reVerification = nil
        reVerificationMessage = nil
        let engine = environment.signingEngine
        runTask = Task { [weak self] in
            var outcome: SigningEngineResult?
            do {
                outcome = try await engine.sign(request) { snapshot in
                    Task { @MainActor [weak self] in
                        self?.progress = snapshot
                    }
                }
            } catch is CancellationError {
                outcome = nil
            } catch {
                outcome = nil
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isRunning = false
                self.result = outcome
                self.progress = outcome?.progress
                if let outcome, outcome.status == .signed {
                    environment.recordAnalyticsEvent(
                        category: .signing,
                        name: "sign.succeeded",
                        succeeded: true
                    )
                } else {
                    environment.recordAnalyticsEvent(
                        category: .signing,
                        name: "sign.refused",
                        succeeded: false
                    )
                }
            }
        }
    }

    /// Cancels a running signing run. The engine discards its working copy,
    /// delivers nothing, and leaves the original untouched.
    func cancel() {
        runTask?.cancel()
    }

    /// Re-verifies the delivered container, independently of the run.
    ///
    /// - Parameter environment: The environment the engine is reached
    ///   through.
    func verifyAgain(environment: ApplicationEnvironment) async {
        guard let result, let outputURL = result.outputURL,
              let expectations = result.expectations else { return }
        isReVerifying = true
        reVerification = nil
        reVerificationMessage = nil
        defer { isReVerifying = false }
        do {
            let report = try await environment.signingEngine.verifyAgain(
                containerURL: outputURL,
                expectations: expectations
            )
            reVerification = report
            if !report.passed {
                reVerificationMessage = "The delivered container no longer passes independent verification."
            }
        } catch let error as ZynSignError {
            reVerificationMessage = error.userMessage
        } catch {
            reVerificationMessage = "The container could not be re-verified."
        }
    }

    /// The one-line summary of the delivered container.
    var deliverySummary: String {
        guard let result, result.status == .signed, let summary = result.summary else {
            return result?.failure?.userMessage ?? ""
        }
        let size = ByteCountFormatter.string(fromByteCount: Int64(summary.containerByteCount), countStyle: .file)
        let seconds = summary.duration < 1
            ? "under a second"
            : String(format: "%.1f s", summary.duration)
        return "\(summary.bundleName) signed in \(seconds) — \(summary.signedBinaryCount) binaries, \(summary.sealedResourceCount) sealed resources, \(size)."
    }

    /// The one-line explanation of a refusal.
    var failureSummary: String? {
        guard let failure = result?.failure else { return nil }
        return "\(failure.stage.title): \(failure.detail)"
    }

    /// Builds one run's request, including the delivery location inside
    /// `Documents/Signed`.
    ///
    /// - Parameters:
    ///   - entry: The library entry being signed.
    ///   - sourceURL: The imported container's location in library storage.
    ///   - profile: The provisioning profile's bytes.
    ///   - identityID: The selected identity.
    ///   - entitlements: The entitlement set derived from the profile.
    ///   - emitDEREntitlements: Whether to advertise the DER slot version.
    static func makeRequest(
        entry: LibraryEntry,
        sourceURL: URL,
        profile: Data,
        identityID: SigningIdentityIdentifier,
        entitlements: CodeSigningEntitlements,
        emitDEREntitlements: Bool
    ) -> SigningEngineRequest {
        var options = SignApplicationOptions()
        if emitDEREntitlements {
            options = SignApplicationOptions(emitDEREntitlements: true)
        }
        return SigningEngineRequest(
            sourceURL: sourceURL,
            profile: profile,
            identityID: identityID,
            entitlements: entitlements,
            outputURL: signedOutputURL(for: entry),
            options: options
        )
    }

    /// Where a signed container for `entry` is delivered:
    /// `Documents/Signed/<name>_signed.ipa`, with the name derived from the
    /// record rather than from a user-selected file name.
    static func signedOutputURL(for entry: LibraryEntry) -> URL {
        let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let directory = documents.appendingPathComponent("Signed", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = (entry.record.displayName ?? entry.record.bundleIdentifier.rawValue)
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("\(base)_signed.ipa", isDirectory: false)
    }
}
