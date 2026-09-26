import SwiftUI
import UIKit

/// One exported artifact in full: what was signed, how it was verified, where
/// it is, and what can be done with it.
///
/// The screen is the Export Center's detail surface, and it stays honest
/// about three things:
///
/// - **Availability.** If the artifact's file is gone or was changed, the
///   screen says so and disables the actions that need its bytes. The record,
///   and the history around it, stay.
/// - **Verification.** The status shown is the last independent verification
///   of this artifact, with its findings; "Verify Again" reopens the file and
///   replaces that conclusion with what the check actually finds now.
/// - **Provenance.** When the signing journal still holds the operation that
///   produced the artifact, the screen shows that operation's timeline.
///   Nothing about the artifact is taken from the run's own opinion of
///   itself.
struct ExportDetailView: View {

    /// The entry being shown, refreshed by the model as actions run.
    let entry: ExportEntry

    /// The operation that produced it, when the journal still holds one.
    let operation: SigningRecord?

    /// The application record to reveal in the library, when it is known.
    let onRevealInLibrary: (ApplicationRecordIdentifier) -> Void

    /// Runs an independent verification and updates the list.
    let onVerify: () async -> Void

    /// Records that the artifact was handed to the system and delivered.
    let onDelivered: () async -> Void

    /// Asks for confirmation before deleting the export.
    let onDelete: () -> Void

    @State private var showsTechnicalDetail = false

    private var record: ExportRecord { entry.record }

    var body: some View {
        List {
            Section {
                ReleaseReadinessLink(recordID: record.sourceRecordIdentifier.flatMap { ApplicationRecordIdentifier(rawValue: $0) }, exportID: record.id)
            }
            headerSection
            if !entry.isAvailable { availabilitySection }
            applicationSection
            verificationSection
            outputSection
            if let operation {
                timelineSection(operation)
            }
            actionsSection
            if let findings = record.verificationFindings, !findings.isEmpty {
                findingsSection(findings)
            }
            honestySection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(record.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sections

    private var headerSection: some View {
        Section {
            HStack(alignment: .top, spacing: ZSpacing.md) {
                icon
                VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                    Text(record.displayName)
                        .font(.headline)
                    Text(record.bundleIdentifier)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: ZSpacing.xs) {
                        ZStatusBadge(
                            record.verificationStatus.displayName,
                            systemImage: Self.verificationSymbol(record.verificationStatus),
                            kind: Self.verificationKind(record.verificationStatus)
                        )
                        ZStatusBadge(
                            entry.availability.displayName,
                            systemImage: entry.isAvailable ? "internaldrive" : "exclamationmark.triangle",
                            kind: entry.isAvailable ? .neutral : .warning
                        )
                        if record.hasBeenDelivered {
                            ZStatusBadge("Exported", systemImage: "square.and.arrow.up", kind: .info)
                        }
                    }
                }
            }
        } footer: {
            Text(record.verificationStatus.explanation)
        }
    }

    private var availabilitySection: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("The artifact is not where this record says it is.")
                        .font(.subheadline)
                    Text(entry.availability.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text("Sharing, verifying, and revealing the file are unavailable until the artifact is back. The record is kept so the operation stays readable.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Availability")
        }
    }

    private var applicationSection: some View {
        Section("Application") {
            detailRow("Name", record.displayName)
            detailRow("Bundle ID", record.bundleIdentifier)
            detailRow("Version", record.shortVersion ?? "Not declared")
            detailRow("Build", record.buildVersion ?? "Not declared")
            if let operation {
                detailRow("Signed", Self.dateString(operation.startedAt))
                if let certificate = operation.certificateDisplayName {
                    detailRow("Certificate", certificate)
                }
                if let team = operation.teamIdentifier {
                    detailRow("Team ID", team)
                }
                if let profile = operation.provisioningProfileName {
                    detailRow("Profile", profile)
                }
            }
        }
    }

    private var verificationSection: some View {
        Section {
            detailRow("Result", record.verificationStatus.displayName)
            if let verifiedAt = record.verificationRecordedAt {
                detailRow("Verified", Self.dateString(verifiedAt))
            } else {
                detailRow("Verified", "Not yet verified")
            }
            if let checks = record.verificationChecksRun {
                detailRow("Checks run", "\(checks)")
            }
        } header: {
            Text("Verification")
        } footer: {
            Text("Verification reopens the exported artifact and inspects its bytes. It does not evaluate trust, and it does not claim the package is installable.")
        }
    }

    private var outputSection: some View {
        Section("Output") {
            detailRow("File name", record.fileName)
            detailRow("Size", ByteCountFormatter.string(fromByteCount: Int64(record.byteCount), countStyle: .file))
            if let fingerprint = record.fingerprint {
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
            detailRow("Exported", Self.dateString(record.createdAt))
            detailRow(
                "Delivered",
                record.deliveredAt.map(Self.dateString) ?? "Not exported yet"
            )
        }
    }

    private func timelineSection(_ operation: SigningRecord) -> some View {
        Section {
            SigningTimelineView(timeline: operation.stages)
            NavigationLink {
                SigningOperationDetailView(operation: operation, exportEntry: entry)
            } label: {
                Label("Operation Details", systemImage: "list.bullet.rectangle")
            }
        } header: {
            Text("Signing Timeline")
        } footer: {
            Text(operation.outcomeSummary)
        }
    }

    private var actionsSection: some View {
        Section("Actions") {
            Button {
                ZShareSheet.present(items: [entry.fileURL].compactMap { $0 }) { completed in
                    guard completed else { return }
                    Task { await onDelivered() }
                }
            } label: {
                Label("Export / Share", systemImage: "square.and.arrow.up")
            }
            .disabled(!entry.permitsArtifactActions)

            Button {
                Task { await onVerify() }
            } label: {
                Label("Verify Again", systemImage: "checkmark.seal")
            }

            Button {
                UIPasteboard.general.string = record.reference
            } label: {
                Label("Copy Artifact Reference", systemImage: "doc.on.doc")
            }

            Button {
                guard let source = record.sourceRecordID else { return }
                onRevealInLibrary(source)
            } label: {
                Label("Reveal in Library", systemImage: "books.vertical")
            }
            .disabled(record.sourceRecordID == nil)

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete Exported Artifact", systemImage: "trash")
            }
        }
    }

    private func findingsSection(_ findings: [String]) -> some View {
        Section {
            ForEach(findings, id: \.self) { finding in
                Text(finding)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Findings")
        } footer: {
            Text("Findings are recorded in the language ZynSign uses for diagnostics: bundle-relative locations at most, never a key, a credential, or a profile's contents.")
        }
    }

    private var honestySection: some View {
        Section {
            DisclosureGroup(isExpanded: $showsTechnicalDetail) {
                VStack(alignment: .leading, spacing: ZSpacing.xs) {
                    Text("The record identifies a stored file by name. Verification re-read and re-digested the artifact's own bytes; it shares no state with the signing run.")
                    Text("No private key, password, or profile content is stored in this record, in the export catalog, or in the signing history.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } label: {
                Label("About This Record", systemImage: "info.circle")
                    .font(.subheadline)
            }
            if let source = record.sourceRecordID {
                Text("Source record: \(source.rawValue)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var icon: some View {
        if let artifactID = record.sourceArtifactID {
            ApplicationIconView(
                artifactID: artifactID,
                displayName: record.displayName,
                bundleIdentifier: record.bundleIdentifier,
                size: 52
            )
        } else {
            RoundedRectangle(cornerRadius: ZRadius.card, style: .continuous)
                .fill(Color(.tertiarySystemFill))
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: "shippingbox")
                        .foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
        }
    }

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

    private static func verificationKind(_ status: ArtifactVerificationStatus) -> ZStatusBadge.Kind {
        switch status {
        case .valid: return .success
        case .warning: return .warning
        case .invalid: return .error
        case .unsupported: return .neutral
        }
    }

    private static func verificationSymbol(_ status: ArtifactVerificationStatus) -> String {
        switch status {
        case .valid: return "checkmark.seal.fill"
        case .warning: return "exclamationmark.triangle"
        case .invalid: return "xmark.seal.fill"
        case .unsupported: return "questionmark.circle"
        }
    }

    private static func dateString(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
