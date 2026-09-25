import SwiftUI

/// Everything one signing run established, in one scrolling screen.
///
/// The sheet is read-only: the stage table, the run's summary, every
/// independent verification check, and the recovery facts. It is the screen
/// **Open Details** opens, and it carries no signing material — no key, no
/// profile body, no certificate bytes.
struct SigningDetailsView: View {

    /// The run's result.
    let result: SigningEngineResult

    /// The entry the run signed, for naming.
    let entry: LibraryEntry

    private var name: String {
        entry.record.displayName ?? entry.record.bundleIdentifier.rawValue
    }

    var body: some View {
        List {
            summarySection
            stagesSection
            if let verification = result.verification {
                verificationSection(title: "Independent verification", report: verification)
            }
            if let container = result.containerVerification {
                containerVerificationSection(container)
            }
            recoverySection
            honestSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Signing Details")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sections

    private var summarySection: some View {
        Section("Run") {
            LabeledContent("Application", value: name)
            LabeledContent("Identifier", value: entry.record.bundleIdentifier.rawValue)
            if let summary = result.summary {
                LabeledContent("Bundle", value: summary.bundleName)
                LabeledContent("Executable", value: summary.executableName)
                LabeledContent("Binaries signed", value: "\(summary.signedBinaryCount)")
                LabeledContent("Nested targets", value: "\(summary.nestedTargetCount)")
                LabeledContent("Sealed resources", value: "\(summary.sealedResourceCount)")
                LabeledContent("Container entries", value: "\(summary.entryCount)")
                LabeledContent(
                    "Container size",
                    value: ByteCountFormatter.string(fromByteCount: Int64(summary.containerByteCount), countStyle: .file)
                )
                LabeledContent("Duration", value: String(format: "%.2f s", summary.duration))
                HStack(spacing: ZSpacing.xs) {
                    ZStatusBadge(
                        "\(summary.verificationPassedCount)/\(summary.verificationCheckCount) checks",
                        systemImage: summary.verificationPassed ? "checkmark.shield.fill" : "exclamationmark.triangle",
                        kind: summary.verificationPassed ? .success : .warning
                    )
                    Spacer()
                }
            }
            if let failure = result.failure {
                HStack(spacing: ZSpacing.xs) {
                    ZStatusBadge("Refused at \(failure.stage.title)", systemImage: "xmark.shield.fill", kind: .error)
                    ZStatusBadge(String(describing: failure.category), kind: .neutral)
                    Spacer()
                }
                Text(failure.detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var stagesSection: some View {
        Section("Stages") {
            ForEach(result.stages, id: \.stage) { outcome in
                VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: ZSpacing.xs) {
                        Text(outcome.stage.title).font(.subheadline.weight(.medium))
                        Spacer(minLength: 0)
                        ZStatusBadge(
                            outcome.status == .succeeded ? "Done" : (outcome.status == .skipped ? "Skipped" : "Failed"),
                            systemImage: outcome.status == .succeeded
                                ? "checkmark.circle.fill"
                                : (outcome.status == .skipped ? "minus.circle" : "xmark.octagon.fill"),
                            kind: outcome.status == .succeeded ? .success : (outcome.status == .skipped ? .neutral : .error)
                        )
                    }
                    Text(outcome.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let metrics = Self.metricsText(outcome.metrics) {
                        Text(metrics).font(.caption2.monospaced()).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(String(format: "%.2f s", outcome.duration))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                .padding(.vertical, ZSpacing.xxs)
            }
        }
    }

    private func verificationSection(title: String, report: SigningEngineVerificationReport) -> some View {
        Section {
            ForEach(report.checks, id: \.name) { check in
                VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                    HStack(spacing: ZSpacing.xs) {
                        Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(check.passed ? .green : .red)
                        Text(check.name).font(.subheadline.monospaced())
                        Spacer(minLength: 0)
                    }
                    Text(check.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, ZSpacing.xxs)
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text(title)
        } footer: {
            Text("Every value here was re-derived from the signed bytes: page hashes recomputed, special slots recomputed from the seal and the entitlement set, and the CMS signature verified against the certificate resolved from secure storage. Certificate trust is not evaluated.")
        }
    }

    private func containerVerificationSection(_ report: VerifySignedApplicationReport) -> some View {
        Section {
            ForEach(report.checks, id: \.name) { check in
                HStack(spacing: ZSpacing.xs) {
                    Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(check.passed ? .green : .red)
                    Text(check.name).font(.subheadline.monospaced())
                    Spacer(minLength: 0)
                }
            }
        } header: {
            Text("Delivered container")
        } footer: {
            Text("The written container was reopened through the archive boundary and held to the same rules as any imported package.")
        }
    }

    @ViewBuilder
    private var recoverySection: some View {
        if let workingCopy = result.workingCopy {
            Section("Recovery") {
                LabeledContent("Original unchanged", value: workingCopy.originalUnchanged ? "Verified" : "Not verified")
                LabeledContent("Working copy discarded", value: workingCopy.discarded ? "Yes" : "No")
                LabeledContent("Reclaimed", value: ByteCountFormatter.string(fromByteCount: Int64(workingCopy.reclaimedByteCount), countStyle: .file))
                if let failure = result.failure {
                    LabeledContent("Partial output removed", value: failure.outputRemoved ? "Yes" : "None left behind")
                    LabeledContent("Retry", value: failure.isRetryable ? "May succeed" : "Requires different inputs")
                }
            }
        }
    }

    private var honestSection: some View {
        Section("What this does not establish") {
            Text("A passing run means the delivered container is exactly what the pipeline produced and is internally coherent. It does not mean any certificate is trusted, that the platform authorizes the result, or that the application is installable — those conclusions need device evidence this run never claims to hold.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One line of the countable results a stage reported, or `nil` when the
    /// stage reported none.
    static func metricsText(_ metrics: SigningEngineStageMetrics) -> String? {
        var parts: [String] = []
        if let value = metrics.entryCount { parts.append("\(value) entries") }
        if let value = metrics.nestedTargetCount { parts.append("\(value) nested") }
        if let value = metrics.signedBinaryCount { parts.append("\(value) signed") }
        if let value = metrics.sealedResourceCount { parts.append("\(value) sealed") }
        if let value = metrics.verificationCheckCount {
            parts.append("\(metrics.verificationPassedCount ?? 0)/\(value) checks")
        }
        if let value = metrics.signatureByteCount { parts.append("\(value) byte signature") }
        if let value = metrics.containerByteCount {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
