import SwiftUI

/// The readiness card for one signed application: name, identity, the
/// check states that fit on a card, and the actions the report allows.
///
/// The card reports only checks ZynSign evaluated. A blocked card offers
/// no delivery action at all — not a disabled one with a mystery — so the
/// absence is itself information.
struct InstallationReadinessCard: View {

    let row: InstallationWorkspaceModel.CandidateRow
    let onOpenChecklist: () -> Void
    /// Non-`nil` only when the report permits delivery.
    let onDeliver: (() -> Void)?
    let onVerify: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ZSpacing.sm) {
            header
            identityRows
            checkSummary
            actions
        }
        .padding(.vertical, ZSpacing.xxs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: ZSpacing.xs) {
            ApplicationIconView(
                artifactID: row.candidate.entry.record.artifact.artifactID,
                displayName: row.candidate.displayName,
                bundleIdentifier: row.candidate.bundleIdentifier,
                size: 36
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(row.candidate.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(row.candidate.bundleIdentifier) · \(row.candidate.versionDisplay)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            ZStatusBadge(
                InstallationPresentation.readinessTitle(for: row.report),
                systemImage: row.report.isReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                kind: InstallationPresentation.badgeKind(for: row.report)
            )
        }
        .accessibilityElement(children: .combine)
    }

    private var identityRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let signing = row.candidate.signingRecord {
                HStack(spacing: ZSpacing.xxs) {
                    Image(systemName: "signature").font(.caption2).foregroundStyle(.secondary)
                    Text("Signed \(InstallationPresentation.timestamp(signing.startedAt))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let export = row.candidate.exportEntry {
                HStack(spacing: ZSpacing.xxs) {
                    Image(systemName: export.isAvailable ? "doc.checkmark" : "doc.slash").font(.caption2).foregroundStyle(.secondary)
                    Text(export.isAvailable
                         ? "Artifact held · \(ByteCountFormatter.string(fromByteCount: Int64(export.record.byteCount), countStyle: .file))"
                         : "Artifact no longer held")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The check marks that fit on the card: one pill per state group.
    private var checkSummary: some View {
        HStack(spacing: ZSpacing.xxs) {
            ForEach(InstallationReadinessCheck.presentationOrder, id: \.self) { check in
                if let state = row.report.state(of: check) {
                    CheckMarkPill(check: check, state: state)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        HStack(spacing: ZSpacing.sm) {
            Button("Checklist", action: onOpenChecklist)
                .buttonStyle(.bordered)
            if let onDeliver {
                Button(action: onDeliver) {
                    Label("Deliver…", systemImage: "tray.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
            }
            if row.candidate.exportEntry?.permitsArtifactActions == true {
                Button(action: onVerify) {
                    Label("Verify Again", systemImage: "checkmark.shield")
                }
                .buttonStyle(.bordered)
            }
            Spacer(minLength: 0)
        }
        .font(.footnote)
    }

    private var accessibilitySummary: String {
        var parts = [row.candidate.displayName, row.candidate.versionDisplay]
        parts.append(InstallationPresentation.readinessTitle(for: row.report))
        parts.append(row.report.spokenSummary)
        if onDeliver == nil {
            parts.append("Delivery is unavailable until the blocked checks are resolved.")
        }
        return parts.joined(separator: ". ") + "."
    }
}

/// One small check mark on a readiness card.
struct CheckMarkPill: View {
    let check: InstallationReadinessCheck
    let state: InstallationCheckState

    var body: some View {
        HStack(spacing: 2) {
            Text(state.displayMark)
                .font(.caption2.weight(.bold))
                .monospacedDigit()
            Text(check.displayName)
                .font(.caption2)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(background, in: Capsule())
        .foregroundStyle(foreground)
        .accessibilityLabel("\(check.displayName): \(stateLabel)")
    }

    private var background: Color {
        switch InstallationPresentation.badgeKind(for: state) {
        case .success: return .green.opacity(0.14)
        case .warning: return .orange.opacity(0.14)
        case .error: return .red.opacity(0.14)
        case .neutral: return Color(.tertiarySystemFill)
        case .info: return .blue.opacity(0.12)
        @unknown default: return Color(.tertiarySystemFill)
        }
    }

    private var foreground: Color {
        switch InstallationPresentation.badgeKind(for: state) {
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        case .neutral: return .secondary
        case .info: return .blue
        @unknown default: return .secondary
        }
    }

    private var stateLabel: String {
        switch state {
        case .passed: return "passed"
        case .attention(let reason): return "needs a look — \(reason)"
        case .blocked(let reason): return "blocked — \(reason)"
        case .notPerformed(let reason): return "not checked — \(reason)"
        }
    }
}

/// The pre-install checklist for one signed application: every check
/// ZynSign evaluated, what it found, the compatibility guidance, and the
/// actions the report allows.
///
/// The checklist is where the workspace is most explicit: ZynSign's
/// validation is one section, the delivery step is another, and the line
/// between them is drawn in words, every time.
struct InstallationChecklistSheet: View {

    @ObservedObject var model: InstallationWorkspaceModel
    let row: InstallationWorkspaceModel.CandidateRow

    /// Called when the user chooses to deliver, so the presenting screen
    /// can dismiss this sheet and open the channel picker.
    var onDeliver: () -> Void

    /// Called when the user chooses to record an installation after the
    /// fact, so the presenting screen can dismiss this sheet and open the
    /// recording sheet.
    var onRecord: () -> Void

    @Environment(\.dismiss) private var dismiss

    init(
        model: InstallationWorkspaceModel,
        row: InstallationWorkspaceModel.CandidateRow,
        onDeliver: @escaping () -> Void = {},
        onRecord: @escaping () -> Void = {}
    ) {
        self.model = model
        self.row = row
        self.onDeliver = onDeliver
        self.onRecord = onRecord
    }

    /// Sets the deliver closure, which the dashboard supplies.
    func onDeliver(_ action: @escaping () -> Void) -> Self {
        var copy = self
        copy.onDeliver = action
        return copy
    }

    var body: some View {
        NavigationStack {
            List {
                appSection
                checksSection
                guidanceSection
                actionsSection
                honestySection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Pre-Install Checklist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                // Spoken readiness summary: the checklist says what it
                // found, out loud, when it appears.
                AccessibilityNotification.Announcement(row.report.spokenSummary).post()
            }
        }
    }

    private var appSection: some View {
        Section {
            LabeledContent("App", value: row.candidate.displayName)
            LabeledContent("Version", value: row.candidate.versionDisplay)
            LabeledContent("Bundle ID", value: row.candidate.bundleIdentifier)
            if let signing = row.candidate.signingRecord {
                LabeledContent("Signature", value: "Signed \(InstallationPresentation.timestamp(signing.startedAt))")
                if let team = signing.teamIdentifier {
                    LabeledContent("Team", value: team)
                }
            } else {
                LabeledContent("Signature", value: "No signing run in the journal")
            }
            LabeledContent("Verification", value: verificationText)
        } header: {
            Text("Signed Application")
        }
    }

    private var verificationText: String {
        guard let export = row.candidate.exportEntry else { return "No export" }
        if export.record.verificationRecordedAt == nil { return "Never run" }
        return "\(export.record.verificationStatus.displayName), \(InstallationPresentation.timestamp(export.record.verificationRecordedAt ?? export.record.createdAt))"
    }

    private var checksSection: some View {
        Section {
            ForEach(InstallationReadinessCheck.presentationOrder, id: \.self) { check in
                if let state = row.report.state(of: check) {
                    ChecklistRow(check: check, state: state)
                }
            }
        } header: {
            Text("Checks ZynSign Performed")
        } footer: {
            Text("A check with no evidence reads as not performed. ZynSign reports only what it evaluated.")
        }
    }

    private var guidanceSection: some View {
        Section {
            ForEach(Array(row.report.guidance.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: ZSpacing.xs) {
                    Image(systemName: "text.quote")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(line).font(.footnote)
                }
            }
        } header: {
            Text("Before You Continue")
        }
    }

    private var actionsSection: some View {
        Section {
            if row.report.isReady {
                Button {
                    dismiss()
                    onDeliver()
                } label: {
                    Label("Deliver…", systemImage: "tray.and.arrow.up")
                }
            } else {
                Label("Delivery opens when the blocked checks are resolved", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
            if row.candidate.exportEntry?.permitsArtifactActions == true {
                Button {
                    Task { await model.verifyAgain(row) }
                } label: {
                    Label("Verify Again", systemImage: "checkmark.shield")
                }
            }
            Button {
                dismiss()
                onRecord()
            } label: {
                Label("Record an Installation…", systemImage: "square.and.pencil")
            }
        } header: {
            Text("Actions")
        }
    }

    private var honestySection: some View {
        Section {
            Text("These checks describe ZynSign's own validation of the artifact's bytes. ZynSign cannot see the platform's acceptance decision, and this checklist is never one.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// One checklist row: the check, its mark, and its reason.
struct ChecklistRow: View {
    let check: InstallationReadinessCheck
    let state: InstallationCheckState

    var body: some View {
        HStack(alignment: .top, spacing: ZSpacing.sm) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.displayName).font(.subheadline.weight(.medium))
                Text(state.reason ?? check.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(check.displayName), \(spokenState)")
    }

    private var symbol: String {
        switch state {
        case .passed: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.circle.fill"
        case .blocked: return "xmark.circle.fill"
        case .notPerformed: return "minus.circle"
        }
    }

    private var color: Color {
        switch InstallationPresentation.badgeKind(for: state) {
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        case .neutral: return .secondary
        case .info: return .blue
        @unknown default: return .secondary
        }
    }

    private var spokenState: String {
        switch state {
        case .passed: return "passed"
        case .attention: return "needs attention"
        case .blocked: return "blocked"
        case .notPerformed: return "not performed"
        }
    }
}

/// The channel picker shown when a delivery starts. Choosing a channel
/// records the attempt and hands the delivery package to the caller.
struct DeliveryChannelSheet: View {

    @ObservedObject var model: InstallationWorkspaceModel
    let target: InstallationWorkspaceView.DeliveryTarget
    /// Called with the package to hand off, after the attempt is recorded.
    let onDeliver: (InstallationDeliveryPackage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var channel: InstallationChannel = .otaLink
    @State private var isStarting = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("App", value: target.attempt.displayOrIdentifier)
                    LabeledContent("Action", value: target.attempt.intent.displayName)
                    LabeledContent("Version", value: target.attempt.versionDisplay)
                    if let exportName = target.attempt.exportFileName {
                        LabeledContent("Artifact", value: exportName)
                    }
                } header: {
                    Text("Delivery")
                } footer: {
                    Text("Starting records that you committed to delivering — nothing more. The attempt stays open until you confirm what happened.")
                }

                Section {
                    ForEach(InstallationChannel.allCases, id: \.self) { option in
                        Button {
                            ZHaptics.tap()
                            channel = option
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.displayName).font(.subheadline.weight(.medium))
                                    Text(option.explanation)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer()
                                if channel == option {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(channel == option ? [.isSelected] : [])
                    }
                } header: {
                    Text("How will you deliver it?")
                }

                Section {
                    Button {
                        start()
                    } label: {
                        if isStarting {
                            ProgressView()
                        } else {
                            Label("Start Delivery Hand-off", systemImage: "tray.and.arrow.up")
                        }
                    }
                    .disabled(isStarting)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Deliver")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        // Leaving without delivering leaves the attempt
                        // open on purpose: it stays visible and the user
                        // resolves it when ready.
                        dismiss()
                    }
                }
            }
        }
    }

    private func start() {
        isStarting = true
        Task {
            if let package = await model.deliveryPackage(for: target.attempt) {
                onDeliver(package)
            } else {
                model.notice = InstallationWorkspaceModel.Notice(
                    title: "Artifact not held",
                    message: "The signed artifact is no longer in export storage, so the hand-off cannot open.",
                    isError: true
                )
                isStarting = false
            }
        }
    }
}

/// The after-the-fact recording sheet: the user tells ZynSign what
/// already happened on the device.
struct RecordAfterTheFactSheet: View {

    @ObservedObject var model: InstallationWorkspaceModel
    let row: InstallationWorkspaceModel.CandidateRow

    @Environment(\.dismiss) private var dismiss
    @State private var intent: InstallationEventKind = .installed

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("App", value: row.candidate.displayName)
                    LabeledContent("Version", value: row.candidate.versionDisplay)
                } header: {
                    Text("Record Installation")
                } footer: {
                    Text("This writes a record that you confirmed an installation. ZynSign did not observe it, and the record says so.")
                }

                Section {
                    ForEach(InstallationEventKind.allCases, id: \.self) { option in
                        Button {
                            ZHaptics.tap()
                            intent = option
                        } label: {
                            HStack {
                                Text(option.displayName)
                                Spacer()
                                if intent == option {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(intent == option ? [.isSelected] : [])
                    }
                } header: {
                    Text("What happened?")
                }

                Section {
                    Button {
                        Task {
                            await model.recordAfterTheFact(row, intent: intent)
                            dismiss()
                        }
                    } label: {
                        Label("Record", systemImage: "square.and.pencil")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Record")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// The installed-app row used on the dashboard's Installed and Updates
/// sections.
struct InstalledAppRow: View {
    let row: InstallationWorkspaceModel.InstalledRow

    var body: some View {
        HStack(spacing: ZSpacing.sm) {
            InstalledAppMark(bundleIdentifier: row.record.bundleIdentifier, name: row.record.displayOrIdentifier, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.record.displayOrIdentifier)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text("\(row.record.installedVersionDisplay) · \(InstallationPresentation.timestamp(row.record.lastInstalledAt ?? row.record.recordedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            ZStatusBadge(
                InstallationPresentation.updateLabel(for: row.updateState),
                systemImage: row.updateState.offersUpdate ? "arrow.triangle.2.circlepath" : "checkmark.circle",
                kind: InstallationPresentation.badgeKind(for: row.updateState)
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.spokenSummary)
    }
}

/// The mark an installed card shows: the derived monogram from the same
/// palette the library's icon fallback uses. An installed record has no
/// package bytes of its own — the library entry may be gone — so the mark
/// is honest by design and never pretends to be the app's artwork.
struct InstalledAppMark: View {
    let bundleIdentifier: String
    let name: String
    var size: CGFloat = 52

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                .fill(LinearGradient(
                    colors: palette,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            Text(initials)
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(size * 0.08)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
        .accessibilityHidden(true)
    }

    private var initials: String {
        let words = name.split(separator: " ").filter { !$0.isEmpty }
        if let first = words.first {
            let second = words.count > 1 ? words[1].prefix(1) : ""
            return (first.prefix(1) + second).uppercased()
        }
        let components = bundleIdentifier.split(separator: ".")
        if let last = components.last, let character = last.first {
            return String(character).uppercased()
        }
        return "·"
    }

    private var palette: [Color] {
        var hasher = UInt32(0)
        for byte in bundleIdentifier.utf8 {
            hasher = (hasher &* 31) &+ UInt32(byte)
        }
        let hue = Double(hasher % 360) / 360
        let base = Color(hue: hue, saturation: 0.52, brightness: 0.82)
        let companion = Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.62)
        return [base, companion]
    }
}
