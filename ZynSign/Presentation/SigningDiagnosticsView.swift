import SwiftUI

extension Notification.Name {
    static let zynsignSigningIdentityChanged = Notification.Name("ZynSign.signingIdentityChanged")
    static let zynsignProvisioningProfilesChanged = Notification.Name("ZynSign.provisioningProfilesChanged")
}

/// The same evidence summary appears on every app and in the signing flow.
/// A green score never asserts iOS acceptance: it counts local checks only.
struct SigningHealthCard: View {
    let report: SigningDiagnosticsReport?
    let isAnalyzing: Bool
    let error: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ZCard(variant: .material, cornerRadius: ZRadius.lg) {
            VStack(alignment: .leading, spacing: ZSpacing.sm) {
                Label("Signing Health", systemImage: "heart.text.square")
                    .font(.headline)
                if let report {
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: ZSpacing.sm) { scoreRing(report); scoreLabel(report) }
                        } else {
                            HStack(alignment: .center, spacing: ZSpacing.md) {
                                scoreRing(report); scoreLabel(report)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Local health score \(report.score) out of 100, \(report.status.title)")
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: ZSpacing.md) { issueCounts(report) }
                        VStack(alignment: .leading, spacing: ZSpacing.xs) { issueCounts(report) }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    if report.unsupportedCount > 0 {
                        Text("\(report.unsupportedCount) unsupported check\(report.unsupportedCount == 1 ? "" : "s")")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    LabeledContent("Last analysis") {
                        Text(report.analyzedAt, format: .dateTime.date().hour().minute())
                    }
                    .font(.footnote)
                    SigningCompatibilitySummary(report: report)
                    Text("Score = implemented checks, not certificate trust, iOS acceptance or installability.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if isAnalyzing {
                    HStack(spacing: ZSpacing.sm) {
                        ProgressView()
                        Text("Checking the app and signing configuration…")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Analyzing signing health")
                } else {
                    Label(error ?? "No analysis yet. Open the app to check signing health.",
                          systemImage: "questionmark.shield")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: report?.score)
    }

    private func scoreRing(_ report: SigningDiagnosticsReport) -> some View {
        ZProgressRing(progress: Double(report.score) / 100,
                      status: "Local checks", tint: report.status.tint)
            .accessibilityHidden(true)
    }

    private func scoreLabel(_ report: SigningDiagnosticsReport) -> some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            Text("\(report.score) / 100")
                .font(.title2.bold()).monospacedDigit()
            ZStatusBadge(report.status.title, systemImage: report.status.symbol,
                         kind: report.status.badgeKind)
        }
    }

    @ViewBuilder private func issueCounts(_ report: SigningDiagnosticsReport) -> some View {
        Label("\(report.warningCount) warnings", systemImage: "exclamationmark.triangle")
        Label("\(report.errorCount) errors", systemImage: "xmark.circle")
    }
}

/// Scannable but VoiceOver-readable; a gray dash is never presented as a tick.
struct SigningCompatibilitySummary: View {
    let report: SigningDiagnosticsReport
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var columns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible(), spacing: ZSpacing.xs)]
            : [GridItem(.adaptive(minimum: 145), spacing: ZSpacing.xs)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            Text("Compatibility").font(.subheadline.weight(.semibold))
            LazyVGrid(columns: columns, alignment: .leading, spacing: ZSpacing.xs) {
                ForEach(report.checks) { check in
                    HStack(spacing: ZSpacing.xxs) {
                        Image(systemName: check.state.symbol)
                            .foregroundStyle(check.state.badgeKind.color)
                            .accessibilityHidden(true)
                        Text(check.area.title).font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(check.area.title): \(check.state.title)")
                }
            }
        }
    }
}

/// A full, per-app inspector; history contains status/codes only and can never
/// reconstruct or display old profile values, keys, paths or identifiers.
struct SigningDiagnosticsView: View {
    /// Where the independent validation record lives. Optional because a URL
    /// is built from text: the two call sites guard it, and a link that
    /// cannot be built is simply not shown rather than a trap.
    static let validationRecordURL = URL(string:
        "https://github.com/raynmahbub/ZynSign/blob/main/docs/architecture/external-validation.md"
    )

    let report: SigningDiagnosticsReport
    let history: [SigningDiagnosticSnapshot]
    let changes: SigningDiagnosticChanges?
    let historyUnavailable: Bool

    var body: some View {
        List {
            Section {
                SigningHealthCard(report: report, isAnalyzing: false, error: nil)
                    .listRowInsets(EdgeInsets(top: ZSpacing.xs, leading: ZSpacing.md,
                                              bottom: ZSpacing.xs, trailing: ZSpacing.md))
                    .listRowBackground(Color.clear)
            }
            Section("Compatibility Summary") {
                ForEach(report.checks) { check in
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Text(check.area.title)
                            Spacer(minLength: ZSpacing.xs)
                            ZStatusBadge(check.state.title, systemImage: check.state.symbol,
                                         kind: check.state.badgeKind)
                        }
                        VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                            Text(check.area.title)
                            ZStatusBadge(check.state.title, systemImage: check.state.symbol,
                                         kind: check.state.badgeKind)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(check.area.title): \(check.state.title)")
                }
                LabeledContent("Ready to sign", value: report.readyToSign ? "Yes, for these checks" : "No")
            }
            Section {
                if report.issues.isEmpty {
                    Label("No local issues found. iOS acceptance is still unverified.",
                          systemImage: "checkmark.shield")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(report.issues) { issue in
                    NavigationLink { SigningDiagnosticIssueView(issue: issue) } label: {
                        VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                            Label(issue.title, systemImage: issue.severity.symbol)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(issue.severity.badgeKind.color)
                            Text(issue.explanation).font(.footnote).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, ZSpacing.xxs)
                    }
                    .accessibilityHint("Opens details and a recommended next step")
                }
            } header: { Text("Issues & Recommendations") }
            historySection
            Section("Platform Boundary") {
                Text(SigningDiagnostic.platformBoundary)
                    .font(.footnote).foregroundStyle(.secondary)
                if let validationRecordURL = Self.validationRecordURL {
                    Link("Read the independent validation record", destination: validationRecordURL)
                }
                    .font(.footnote)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Signing Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var historySection: some View {
        Section {
            if historyUnavailable {
                Label("Recent scans could not be saved or read. Current results are still shown.",
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let lastReady = history.first(where: { $0.status == .ready }) {
                LabeledContent("Last ready local scan") {
                    Text(lastReady.analyzedAt, format: .dateTime.date().hour().minute().second())
                }
            } else {
                LabeledContent("Last ready local scan", value: "None yet")
            }
            if let lastBlocked = history.first(where: { $0.status == .blocked }) {
                LabeledContent("Last blocked local scan") {
                    Text(lastBlocked.analyzedAt, format: .dateTime.date().hour().minute().second())
                }
            } else {
                LabeledContent("Last blocked local scan", value: "None yet")
            }
            if let changes {
                LabeledContent("Since previous scan", value: changes.isEmpty
                               ? "No issue changes"
                               : "\(changes.added.count) new · \(changes.resolved.count) resolved")
                ForEach(changes.added, id: \.self) { code in
                    Label("New: \(code.displayName)", systemImage: "plus.circle")
                        .font(.footnote).foregroundStyle(.orange)
                }
                ForEach(changes.resolved, id: \.self) { code in
                    Label("Resolved: \(code.displayName)", systemImage: "checkmark.circle")
                        .font(.footnote).foregroundStyle(.green)
                }
            }
            ForEach(history) { scan in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: scan.status.symbol)
                        .foregroundStyle(scan.status.tint)
                        .accessibilityHidden(true)
                    Text(scan.analyzedAt, format: .dateTime.date().hour().minute().second())
                    Spacer(minLength: ZSpacing.xs)
                    Text("\(scan.score) / 100 · \(scan.status.title)")
                        .foregroundStyle(.secondary)
                }
                .font(.footnote)
                .accessibilityElement(children: .combine)
            }
            if history.isEmpty && !historyUnavailable {
                Text("No earlier scans for this app.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: { Text("Recent Analyses") } footer: {
            Text("Only the app's opaque record ID, times, scores, counts and issue codes are retained. Repeated identical results share a history entry. Removing the app clears its history.")
        }
    }
}

struct SigningDiagnosticIssueView: View {
    let issue: SigningDiagnostic
    @State private var showTechnicalDetails = false

    var body: some View {
        List {
            Section("What happened") {
                ZStatusBadge(issue.severity.title, systemImage: issue.severity.symbol,
                             kind: issue.severity.badgeKind)
                Text(issue.explanation)
            }
            Section("Why it matters") { Text(consequence) }
            Section("ZynSign's local check") { Text(issue.whatWasVerified) }
            Section("What still depends on iOS") {
                Text(SigningDiagnostic.platformBoundary)
                if let validationRecordURL = SigningDiagnosticsView.validationRecordURL {
                    Link("Read the independent validation record", destination: validationRecordURL)
                }
                    .font(.footnote)
            }
            Section("Recommended next step") {
                Label(issue.suggestedAction, systemImage: "arrow.right.circle")
            }
            Section {
                DisclosureGroup("Technical details", isExpanded: $showTechnicalDetails) {
                    Text(issue.technicalDetails)
                        .font(.footnote).textSelection(.enabled)
                    Text("Check code: \(issue.id.rawValue)")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(issue.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var consequence: String {
        switch issue.severity {
        case .error, .unsupported:
            return "This check is blocked or unsupported; signing should not start with the current inputs."
        case .warning:
            return "This is a warning from local inspection. Check it before signing; the pipeline may still refuse the input."
        case .info:
            return "This is context about what ZynSign has and has not evaluated, not a pass or failure."
        case .success:
            return "This local check passed; iOS acceptance is a separate question."
        }
    }
}

private extension SigningReadiness {
    var symbol: String {
        switch self {
        case .ready: return "checkmark.shield.fill"
        case .attention: return "exclamationmark.shield.fill"
        case .blocked: return "xmark.shield.fill"
        }
    }
    var tint: Color { badgeKind.color }
    var badgeKind: ZStatusBadge.Kind {
        switch self {
        case .ready: return .success
        case .attention: return .warning
        case .blocked: return .error
        }
    }
}

private extension SigningCheckState {
    var symbol: String {
        switch self {
        case .passed: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .blocked: return "xmark.circle.fill"
        case .notChecked: return "minus.circle"
        case .unsupported: return "questionmark.square.dashed"
        }
    }
    var badgeKind: ZStatusBadge.Kind {
        switch self {
        case .passed: return .success
        case .attention: return .warning
        case .blocked: return .error
        case .notChecked, .unsupported: return .neutral
        }
    }
}

private extension SigningDiagnosticSeverity {
    var symbol: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        case .unsupported: return "questionmark.square.dashed"
        }
    }
    var title: String { rawValue.capitalized }
    var badgeKind: ZStatusBadge.Kind {
        switch self {
        case .success: return .success
        case .info: return .info
        case .warning: return .warning
        case .error: return .error
        case .unsupported: return .neutral
        }
    }
}
