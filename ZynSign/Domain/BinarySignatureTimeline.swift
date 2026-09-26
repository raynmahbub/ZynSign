import Foundation

/// One step of the signature timeline.
struct BinarySignatureTimelineStep: Equatable, Identifiable {

    enum Kind: String, CaseIterable, Hashable {
        case executable
        case codeDirectory
        case pageHashes
        case signatureApplied
        case verification
    }

    enum State: String, Hashable {
        /// The step is present and consistent.
        case complete
        /// The step is present but deserves attention.
        case attention
        /// The step contradicts the signature.
        case failed
        /// The step does not apply, for example to unsigned code.
        case skipped
        /// The step is still running.
        case pending

        var displayName: String {
            switch self {
            case .complete: return "Complete"
            case .attention: return "Needs attention"
            case .failed: return "Failed"
            case .skipped: return "Not applicable"
            case .pending: return "In progress"
            }
        }
    }

    let kind: Kind
    let title: String
    let detail: String
    let state: State
    /// A time for the step, when one is known.
    let timestamp: Date?
    /// What the timestamp is, so a declared time is never read as a trusted
    /// one.
    let timestampNote: String?

    var id: String { kind.rawValue }
}

/// Derives the signature timeline from a report.
///
/// The timeline is the logical order in which a signature is built —
/// executable, CodeDirectory, page hashes, signature, verification — derived
/// from the structures present. ZynSign has no record of when the
/// CodeDirectory or page hashes were made; the only times shown are the
/// signing time the signer declared (not a trusted timestamp) and the time
/// ZynSign verified the executable on this device.
enum BinarySignatureTimeline {

    static func steps(for report: BinaryInspectionReport) -> [BinarySignatureTimelineStep] {
        let signature = report.primarySignature
        let primary = signature?.primaryCodeDirectory
        var steps: [BinarySignatureTimelineStep] = []

        steps.append(BinarySignatureTimelineStep(
            kind: .executable,
            title: "Executable",
            detail: "\(report.target.name) · \(report.architectureSummary) · \(ByteCountFormatter.string(fromByteCount: Int64(report.fileSize), countStyle: .file))",
            state: .complete,
            timestamp: nil,
            timestampNote: nil
        ))

        if let primary {
            steps.append(BinarySignatureTimelineStep(
                kind: .codeDirectory,
                title: "CodeDirectory Generated",
                detail: "Version \(primary.versionText) · \(primary.hashType.displayName) · identifier \(primary.identifier)",
                state: primary.hashType.digestAlgorithm == nil ? .attention : .complete,
                timestamp: nil,
                timestampNote: nil
            ))
            let pageText = primary.pageSize.map {
                "\(primary.pageCount.formatted()) page hashes of \(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory))"
            } ?? "One hash over the whole code range"
            steps.append(BinarySignatureTimelineStep(
                kind: .pageHashes,
                title: "Page Hashes Created",
                detail: pageText,
                state: pageHashState(report),
                timestamp: nil,
                timestampNote: nil
            ))
        } else {
            steps.append(BinarySignatureTimelineStep(
                kind: .codeDirectory,
                title: "CodeDirectory Generated",
                detail: "No CodeDirectory — the executable is not signed.",
                state: .skipped,
                timestamp: nil,
                timestampNote: nil
            ))
            steps.append(BinarySignatureTimelineStep(
                kind: .pageHashes,
                title: "Page Hashes Created",
                detail: "No page hashes — the executable is not signed.",
                state: .skipped,
                timestamp: nil,
                timestampNote: nil
            ))
        }

        steps.append(signatureStep(report: report, signature: signature))
        steps.append(verificationStep(report: report))
        return steps
    }

    private static func pageHashState(_ report: BinaryInspectionReport) -> BinarySignatureTimelineStep.State {
        guard let integrity = report.integrity else { return .complete }
        switch integrity.check(.pageHashes)?.status {
        case .some(.failed): return .failed
        default: return .complete
        }
    }

    private static func signatureStep(
        report: BinaryInspectionReport,
        signature: CodeSignatureSummary?
    ) -> BinarySignatureTimelineStep {
        guard let signature else {
            return BinarySignatureTimelineStep(
                kind: .signatureApplied,
                title: "Signature Applied",
                detail: "No signature was applied.",
                state: .skipped,
                timestamp: nil,
                timestampNote: nil
            )
        }
        let evaluation = report.integrity?.architectures.lazy.compactMap(\.cms.evaluation).first
        switch signature.form {
        case .certificate:
            let signer = evaluation?.signer?.commonName ?? "a certificate named in the CMS signature"
            return BinarySignatureTimelineStep(
                kind: .signatureApplied,
                title: "Signature Applied",
                detail: "CMS signature by \(signer).",
                state: .complete,
                timestamp: evaluation?.declaredSigningTime,
                timestampNote: evaluation?.declaredSigningTime == nil
                    ? nil
                    : "Signing time declared by the signer's own clock. It is not a trusted timestamp."
            )
        case .adHoc, .linkerSigned, .incomplete:
            return BinarySignatureTimelineStep(
                kind: .signatureApplied,
                title: "Signature Applied",
                detail: "\(signature.form.displayName) signature — no signer identity.",
                state: .attention,
                timestamp: nil,
                timestampNote: nil
            )
        }
    }

    private static func verificationStep(report: BinaryInspectionReport) -> BinarySignatureTimelineStep {
        let verifiedAt = report.integrity?.verifiedAt
        let note = verifiedAt == nil ? nil : "When ZynSign verified the executable on this device."
        switch report.verdict {
        case .valid:
            return BinarySignatureTimelineStep(
                kind: .verification, title: "Verification Passed",
                detail: "Every check that applies passed on this device.",
                state: .complete, timestamp: verifiedAt, timestampNote: note
            )
        case .warning:
            return BinarySignatureTimelineStep(
                kind: .verification, title: "Verification Completed with Warnings",
                detail: "No contradiction was found, but at least one check needs attention or could not be completed.",
                state: .attention, timestamp: verifiedAt, timestampNote: note
            )
        case .failed:
            return BinarySignatureTimelineStep(
                kind: .verification, title: "Verification Failed",
                detail: "At least one check found that the bytes do not match the signature.",
                state: .failed, timestamp: verifiedAt, timestampNote: note
            )
        case .unsigned:
            return BinarySignatureTimelineStep(
                kind: .verification, title: "Verification Not Applicable",
                detail: "There is no signature to verify.",
                state: .skipped, timestamp: verifiedAt, timestampNote: note
            )
        case .pending:
            return BinarySignatureTimelineStep(
                kind: .verification, title: "Verification Running",
                detail: "ZynSign is hashing and comparing the executable.",
                state: .pending, timestamp: nil, timestampNote: nil
            )
        case .notVerified:
            return BinarySignatureTimelineStep(
                kind: .verification, title: "Verification Not Performed",
                detail: "The executable could not be verified.",
                state: .skipped, timestamp: nil, timestampNote: nil
            )
        }
    }
}
