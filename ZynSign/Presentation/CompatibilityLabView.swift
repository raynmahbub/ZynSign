import SwiftUI
import UIKit

/// The Compatibility Lab: one screen that says whether this build is ready.
///
/// The screen is a dashboard, not a control panel. It shows the six rows a
/// release decision reads, the categories beyond them, the QA checklist with
/// what each item needs, and the tracked limitations — and it can write a
/// report to share. It never changes what the user has: running the Lab
/// builds synthetic packages in a scratch directory and deletes them.
///
/// The Lab is compiled into Debug and internal builds only. In every other
/// build this screen says so, rather than showing a dashboard that could not
/// run.
struct CompatibilityLabView: View {

    @Environment(\.applicationEnvironment) private var environment
    @StateObject private var lab = CompatibilityLab()
    @State private var shareItem: LabShareItem?
    @State private var showCopiedToast = false

    var body: some View {
        Group {
            if CompatibilityLabAvailability.isCompiledIn {
                labContent
            } else {
                unavailableContent
            }
        }
        .navigationTitle("Compatibility Lab")
        .navigationBarTitleDisplayMode(.inline)
        .task { lab.environment = environment }
        .sheet(item: $shareItem) { item in
            LabShareSheet(url: item.url)
        }
        .zToast(isPresented: $showCopiedToast, message: "Report copied", style: .success)
    }

    // MARK: - Content

    private var labContent: some View {
        List {
            verdictSection
            runSection
            dashboardSection
            extendedSection
            checklistSection
            limitationsSection
            if let report = lab.report {
                reportSection(report)
            }
            notesSection
        }
        .listStyle(.insetGrouped)
    }

    private var unavailableContent: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: ZSpacing.sm) {
                    Label("Not available in this build", systemImage: "lock.fill")
                        .font(.headline)
                    Text(CompatibilityLabAvailability.availabilityNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, ZSpacing.xs)
            } footer: {
                Text("The Compatibility Lab is validation apparatus: it builds synthetic packages, exercises the pipeline, and reports what it found. It is compiled into Debug and internal builds, and is not shipped to users.")
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: Verdict

    private var verdictSection: some View {
        Section {
            if let verdict = lab.verdict {
                VStack(alignment: .leading, spacing: ZSpacing.sm) {
                    HStack(alignment: .firstTextBaseline) {
                        ZStatusBadge(
                            verdict.readiness.displayName,
                            systemImage: symbol(for: verdict.readiness),
                            kind: kind(for: verdict.readiness)
                        )
                        Spacer(minLength: 0)
                        Text(verdict.headline)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(verdict.readiness.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, ZSpacing.xs)
                .accessibilityElement(children: .combine)
            } else {
                Text("Run the Lab to see whether this build is ready.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Release readiness")
        }
    }

    // MARK: Run

    private var runSection: some View {
        Section {
            Button {
                Task { await lab.run() }
            } label: {
                HStack {
                    Image(systemName: "play.fill")
                    Text(lab.report == nil ? "Run the Lab" : "Run again")
                    Spacer(minLength: 0)
                    Text("\(lab.suiteCount) suites")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(lab.phase.isRunning)

            if case .running(let progress, let suite) = lab.phase {
                VStack(alignment: .leading, spacing: ZSpacing.xs) {
                    ProgressView(value: progress)
                    Text(suite)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Running \(suite)")
            }
            if case .failed(let message) = lab.phase {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } footer: {
            Text("A run builds synthetic packages in a scratch directory, reads them back through the production pipeline, and removes everything it made. It does not import, sign, export or delete anything of yours.")
        }
    }

    // MARK: Dashboard

    private var dashboardSection: some View {
        Section {
            ForEach(lab.dashboard) { summary in
                NavigationLink {
                    CompatibilityChecklistView(
                        title: summary.category.displayName,
                        checks: lab.report?.checks(in: summary.category) ?? []
                    )
                } label: {
                    categoryRow(summary)
                }
                .disabled(summary.checkCount == 0)
            }
        } header: {
            Text("Dashboard")
        } footer: {
            Text("A row marked \"Not run\" is an open question, not a pass: it is a check this device could not execute.")
        }
    }

    private func categoryRow(_ summary: CompatibilityCategorySummary) -> some View {
        HStack(alignment: .top, spacing: ZSpacing.sm) {
            Image(systemName: summary.category.symbolName)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: ZSpacing.xs) {
                    Text(summary.category.displayName)
                        .font(.body)
                    Spacer(minLength: 0)
                    ZStatusBadge(summary.status.displayName, kind: kind(for: summary.status))
                }
                Text(summary.category.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if summary.checkCount > 0 {
                    Text("\(summary.passedCount) of \(summary.checkCount) passed · \(summary.failedCount) failed · \(summary.notRunCount) not run")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    // MARK: Extended

    private var extendedSection: some View {
        Section {
            ForEach(lab.extendedSummaries) { summary in
                NavigationLink {
                    CompatibilityChecklistView(
                        title: summary.category.displayName,
                        checks: lab.report?.checks(in: summary.category) ?? []
                    )
                } label: {
                    categoryRow(summary)
                }
                .disabled(summary.checkCount == 0)
            }
        } header: {
            Text("Further validation")
        } footer: {
            Text("These areas are not part of the six dashboard rows, but a release decision reads them too: an accessibility or security regression blocks a candidate just as a broken pipeline does.")
        }
    }

    // MARK: Checklist

    private var checklistSection: some View {
        Section {
            if lab.checklist.isEmpty {
                Text("Run the Lab to fill in the release checklist.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(lab.checklist) { result in
                    VStack(alignment: .leading, spacing: ZSpacing.xs) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(result.item.title)
                            Spacer(minLength: 0)
                            ZStatusBadge(result.status.displayName, kind: kind(for: result.status))
                        }
                        Text(result.item.howVerified)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let next = result.nextStep {
                            Label(next, systemImage: "arrow.right.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
            }
        } header: {
            Text("Release checklist")
        } footer: {
            Text("Nothing enters RC 2 until every line here is a pass or an accepted limitation.")
        }
    }

    // MARK: Limitations

    private var limitationsSection: some View {
        Section {
            ForEach(ReleaseBlockerRecord.registry) { record in
                VStack(alignment: .leading, spacing: ZSpacing.xs) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(record.title)
                        Spacer(minLength: 0)
                        ZStatusBadge(
                            "\(record.severity.displayName) · \(record.state.displayName)",
                            kind: kind(for: record)
                        )
                    }
                    Text(record.disposition)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(record.severity.displayName): \(record.severity.action)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Tracked limitations")
        } footer: {
            Text("A limitation nobody has to discover twice is the point of this list. Every entry names what ZynSign does instead, or what the user should do.")
        }
    }

    // MARK: Report

    private func reportSection(_ report: CompatibilityLabReport) -> some View {
        Section {
            LabeledContent("Release stage") { Text(report.releaseStage) }
            LabeledContent("Version") { Text("\(report.marketingVersion) (\(report.buildVersion))") }
            LabeledContent("Environment") { Text("iOS \(report.osVersion) · \(report.deviceClass)") }
            LabeledContent("Generated") { Text(Self.timestamp(report.generatedAt)) }
            LabeledContent("Checks") { Text("\(report.checks.count)") }
            if lab.overlaySource != "none" {
                LabeledContent("Imported results") { Text(lab.overlaySource) }
            }
            Button {
                Task { await exportReport() }
            } label: {
                Label("Export report", systemImage: "square.and.arrow.up")
            }
            Button {
                UIPasteboard.general.string = lab.reportText()
                showCopiedToast = true
            } label: {
                Label("Copy report as text", systemImage: "doc.on.doc")
            }
        } header: {
            Text("Report")
        } footer: {
            Text("The report carries counts, classifications, durations and the fixed text of its own checks. No path, no credential, and nothing of yours.")
        }
    }

    private var notesSection: some View {
        Section {
            ForEach(lab.report?.notes ?? Self.standingNotes, id: \.self) { note in
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("What this report does not claim")
        } footer: {
            Text(CompatibilityLabAvailability.availabilityNote)
        }
    }

    // MARK: Actions

    private func exportReport() async {
        do {
            let location = try lab.writeReport()
            shareItem = LabShareItem(url: location)
        } catch {
            // The only failure is "nothing has been produced yet", which the
            // button's own availability already prevents.
            return
        }
    }

    // MARK: Support

    private static var standingNotes: [String] {
        [
            "This report records what the Compatibility Lab executed on the device it ran on. A row marked \"Not run\" is an open question, not a pass.",
            "Nothing in a run signs, imports, exports or deletes anything of the user's."
        ]
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func kind(for status: CompatibilityStatus) -> ZStatusBadge.Kind {
        switch status {
        case .passed: return .success
        case .warning: return .warning
        case .failed: return .error
        case .notRun: return .neutral
        case .skipped: return .unsupported
        }
    }

    private func kind(for readiness: ReleaseReadiness) -> ZStatusBadge.Kind {
        switch readiness {
        case .ready: return .success
        case .incomplete: return .warning
        case .blocked: return .error
        }
    }

    private func symbol(for readiness: ReleaseReadiness) -> String {
        switch readiness {
        case .ready: return "checkmark.seal.fill"
        case .incomplete: return "questionmark.circle.fill"
        case .blocked: return "xmark.octagon.fill"
        }
    }

    private func kind(for record: ReleaseBlockerRecord) -> ZStatusBadge.Kind {
        switch (record.severity, record.state) {
        case (.critical, .open): return .error
        case (_, .accepted): return .warning
        case (_, .resolved): return .success
        case (.high, .open): return .warning
        default: return .neutral
        }
    }
}

// MARK: - Check list

/// One category's checks, each with its evidence, its measurement and what
/// it needs next.
struct CompatibilityChecklistView: View {

    let title: String
    let checks: [CompatibilityCheck]

    var body: some View {
        List {
            ForEach(checks) { check in
                CompatibilityCheckRow(check: check)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One check, in the three parts every answer has.
private struct CompatibilityCheckRow: View {

    let check: CompatibilityCheck
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(check.title)
                Spacer(minLength: 0)
                ZStatusBadge(check.status.displayName, kind: kind)
            }
            Text(check.summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                withAnimation(ZMotion.fast) { isExpanded.toggle() }
            } label: {
                Label(isExpanded ? "Hide detail" : "Show detail", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            if isExpanded {
                VStack(alignment: .leading, spacing: ZSpacing.xs) {
                    detailHeading("What was verified")
                    Text(check.verified)
                    if let next = check.nextStep {
                        detailHeading("What to do next")
                        Text(next)
                    }
                    if !check.evidence.isEmpty {
                        detailHeading("Evidence")
                        ForEach(check.evidence, id: \.self) { line in
                            Text("· \(line)")
                        }
                    }
                    if !check.measurements.isEmpty {
                        detailHeading("Measurements")
                        ForEach(check.measurements) { measurement in
                            Text("· \(measurement.rendered)")
                        }
                    }
                    if check.durationMilliseconds > 0 {
                        Text("Took \(check.durationMilliseconds) ms")
                    }
                    if let blocker = check.blocker {
                        detailHeading("If this fails")
                        Text("\(blocker.displayName): \(blocker.action)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(check.title): \(check.status.displayName). \(check.summary)")
    }

    private func detailHeading(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.top, ZSpacing.xs)
    }

    private var kind: ZStatusBadge.Kind {
        switch check.status {
        case .passed: return .success
        case .warning: return .warning
        case .failed: return .error
        case .notRun: return .neutral
        case .skipped: return .unsupported
        }
    }
}

// MARK: - Sharing

private struct LabShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct LabShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
