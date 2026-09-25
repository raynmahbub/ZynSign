import SwiftUI

/// One signing operation in full: what it signed, how it was configured,
/// what verification concluded, where its output went, and — when it failed —
/// exactly where it stopped and why.
///
/// The screen holds one rule above the others: an operation that did not
/// deliver output is never shown as if it had. Its mark, its summary, and its
/// sections say what happened; a failure shows the stage it failed at, the
/// category, the fixed-language explanation, and the pipeline's own
/// vocabulary behind a disclosure — and never a key, a password, or a
/// profile's contents, because none of those were ever recorded.
struct SigningOperationDetailView: View {

    /// The operation being shown.
    let operation: SigningRecord

    /// The export entry its artifact produced, when the catalog still holds
    /// one. The export record is where the *latest* verification lives; the
    /// operation's own fields are what the run recorded at the time.
    let exportEntry: ExportEntry?

    /// The library, so a failed operation can offer to try again with the
    /// same application when it is still held.
    var library: ApplicationLibrary? = nil

    @State private var sourceEntry: LibraryEntry?
    @State private var showsFailureDetail = false

    var body: some View {
        List {
            outcomeSection
            applicationSection
            signingSection
            verificationSection
            outputSection
            timelineSection
            if operation.outcome != .succeeded {
                retrySection
            }
            privacySection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(operation.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: operation.id) { await resolveSourceEntry() }
    }

    // MARK: - Sections

    private var outcomeSection: some View {
        Section {
            HStack(spacing: ZSpacing.sm) {
                Text(operation.outcome.displayMark)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(color(for: operation.outcome))
                VStack(alignment: .leading, spacing: 2) {
                    Text(operation.outcome.displayName)
                        .font(.headline)
                    Text(operation.outcomeSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            detailRow("Started", Self.dateString(operation.startedAt))
            detailRow("Duration", Self.durationString(operation.duration))
        }
    }

    private var applicationSection: some View {
        Section("Application") {
            detailRow("Name", operation.displayName)
            detailRow("Bundle ID", operation.sourceBundleIdentifier ?? "Not recorded")
            detailRow("Version", operation.shortVersion ?? "Not recorded")
            detailRow("Build", operation.buildVersion ?? "Not recorded")
        }
    }

    private var signingSection: some View {
        Section {
            detailRow("Certificate", operation.certificateDisplayName ?? "Not recorded")
            if let fingerprint = operation.certificateFingerprint {
                detailRow("Fingerprint", fingerprint.hexValue)
            }
            detailRow("Team ID", operation.teamIdentifier ?? "Not recorded")
            detailRow("Profile", operation.provisioningProfileName ?? "Not recorded")
            if let configuration = operation.configuration {
                detailRow("Configuration", configuration.summary)
            } else {
                detailRow("Configuration", "Not recorded")
            }
        } header: {
            Text("Signing")
        } footer: {
            Text("Identifiers only: the certificate is named by its fingerprint and display name, the profile by its declared name. No key material, password, or profile content is stored in the history.")
        }
    }

    private var verificationSection: some View {
        Section {
            if let status = operation.verificationStatus {
                detailRow("Result", status.displayName)
                if let verifiedAt = operation.verificationRecordedAt {
                    detailRow("Verified", Self.dateString(verifiedAt))
                }
            } else {
                detailRow("Result", "Not recorded")
            }
            if let exportEntry {
                detailRow("Latest on artifact", exportEntry.record.verificationStatus.displayName)
                if let verifiedAt = exportEntry.record.verificationRecordedAt {
                    detailRow("Last verified", Self.dateString(verifiedAt))
                }
            }
        } header: {
            Text("Verification")
        } footer: {
            if exportEntry != nil {
                Text("The result above is what this operation recorded. The latest line comes from verifying the exported artifact itself, which is the check the Export Center runs.")
            } else {
                Text("This operation's artifact is no longer listed in the Export Center, so only the run's own verification is shown.")
            }
        }
    }

    private var outputSection: some View {
        Section("Output") {
            detailRow("File name", operation.outputFileName ?? "No artifact was delivered")
            if let bytes = operation.outputByteCount {
                detailRow("Size", ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
            }
            if let fingerprint = operation.outputFingerprint {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fingerprint").font(.caption).foregroundStyle(.secondary)
                    Text(fingerprint.hexDigest)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                detailRow("Fingerprint", "Not recorded")
            }
            detailRow("Delivered", operation.deliveredArtifact ? "Yes" : "No")
        }
    }

    private var timelineSection: some View {
        Section {
            SigningTimelineView(timeline: operation.stages, showsTimes: true)
        } header: {
            Text("Timeline")
        } footer: {
            Text(operation.stages.summary)
        }
    }

    private var retrySection: some View {
        Section {
            if let failure = operation.failure {
                VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                    Text(failure.explanation)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Category: \(failure.category) · Stage: \(failure.stage.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let technical = failure.technicalDetail {
                    DisclosureGroup(isExpanded: $showsFailureDetail) {
                        Text(technical)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } label: {
                        Label("Technical Details", systemImage: "chevron.left.forwardslash.chevron.right")
                            .font(.subheadline)
                    }
                }
            } else {
                Text(operation.outcomeSummary)
                    .font(.subheadline)
            }

            if let sourceEntry, ReleaseTrain.isAvailable(.smartSign) {
                NavigationLink {
                    SigningView(entry: sourceEntry)
                } label: {
                    Label("Sign Again…", systemImage: "arrow.clockwise")
                }
            } else {
                Text(operation.sourceRecordID == nil
                    ? "This operation predates the library record it came from, so ZynSign cannot find the application it signed."
                    : "The application this operation signed is no longer in your library, so it cannot be signed again. Import the package to try again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Failure and Retry")
        } footer: {
            Text("Signing again starts a new operation with a freshly chosen identity and profile. The profile's bytes were never stored, so a run is never repeated silently with old credentials.")
        }
    }

    private var privacySection: some View {
        Section {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: ZSpacing.sm) {
                    if let identifier = operation.sourceRecordIdentifier {
                        labelledValue("Source record", identifier)
                    }
                    if let preset = operation.presetID {
                        labelledValue("Preset", preset.rawValue)
                    }
                    if let code = operation.errorCode {
                        labelledValue("Error code", code)
                    }
                    if let exportIdentifier = operation.exportIdentifier {
                        labelledValue("Export record", exportIdentifier)
                    }
                    labelledValue("Record", operation.id.rawValue)
                }
            } label: {
                Label("Record Identifiers", systemImage: "number")
                    .font(.subheadline)
            }
        } footer: {
            Text("Identifiers are ZynSign's own opaque values. They name records, not credentials, and they are the only technical detail this history keeps about the operation.")
        }
    }

    // MARK: - Pieces

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: ZSpacing.sm)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }

    private func labelledValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func resolveSourceEntry() async {
        guard let library, let recordID = operation.sourceRecordID else { return }
        sourceEntry = try? await library.entry(withID: recordID)
    }

    private func color(for outcome: SigningRecord.Outcome) -> Color {
        switch outcome {
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }

    private static func dateString(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func durationString(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        if seconds < 60 { return "\(seconds) s" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        return remainder == 0 ? "\(minutes) min" : "\(minutes) min \(remainder) s"
    }
}
