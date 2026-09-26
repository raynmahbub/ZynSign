import SwiftUI

// Shared building blocks for the Binary & Signature Inspector. Every status is
// carried by words first — the badge's text and the spoken label — so nothing
// depends on color or symbol alone, in light or dark appearance.

// MARK: - Status presentation

/// How a status is shown: its words, its symbol, and the badge kind.
struct BinaryStatusPresentation: Equatable {
    let text: String
    let systemImage: String
    let kind: ZStatusBadge.Kind

    init(text: String, systemImage: String, kind: ZStatusBadge.Kind) {
        self.text = text
        self.systemImage = systemImage
        self.kind = kind
    }

    init(_ status: BinaryCheckStatus) {
        switch status {
        case .passed: self.init(text: "Passed", systemImage: "checkmark.circle.fill", kind: .success)
        case .warning: self.init(text: "Warning", systemImage: "exclamationmark.triangle.fill", kind: .warning)
        case .failed: self.init(text: "Failed", systemImage: "xmark.octagon.fill", kind: .error)
        case .notPerformed: self.init(text: "Not Performed", systemImage: "questionmark.circle", kind: .unsupported)
        case .notApplicable: self.init(text: "Not Applicable", systemImage: "minus.circle", kind: .neutral)
        }
    }

    init(_ verdict: BinaryVerificationVerdict) {
        switch verdict {
        case .valid: self.init(text: "Valid", systemImage: "checkmark.seal.fill", kind: .success)
        case .warning: self.init(text: "Warning", systemImage: "exclamationmark.triangle.fill", kind: .warning)
        case .failed: self.init(text: "Failed", systemImage: "xmark.seal.fill", kind: .error)
        case .unsigned: self.init(text: "Unsigned", systemImage: "seal", kind: .neutral)
        case .pending: self.init(text: "Verifying", systemImage: "hourglass", kind: .info)
        case .notVerified: self.init(text: "Not Verified", systemImage: "questionmark.circle", kind: .unsupported)
        }
    }

    init(_ state: BinarySignatureTimelineStep.State) {
        switch state {
        case .complete: self.init(text: "Complete", systemImage: "checkmark.circle.fill", kind: .success)
        case .attention: self.init(text: "Attention", systemImage: "exclamationmark.triangle.fill", kind: .warning)
        case .failed: self.init(text: "Failed", systemImage: "xmark.circle.fill", kind: .error)
        case .skipped: self.init(text: "Not Applicable", systemImage: "minus.circle", kind: .neutral)
        case .pending: self.init(text: "In Progress", systemImage: "hourglass", kind: .info)
        }
    }

    init(_ severity: BinaryHealthFinding.Severity) {
        switch severity {
        case .positive: self.init(text: "Good", systemImage: "checkmark.circle.fill", kind: .success)
        case .information: self.init(text: "Note", systemImage: "info.circle.fill", kind: .info)
        case .warning: self.init(text: "Warning", systemImage: "exclamationmark.triangle.fill", kind: .warning)
        case .critical: self.init(text: "Problem", systemImage: "xmark.octagon.fill", kind: .error)
        }
    }
}

/// A status badge with a spoken label that names what the status is about,
/// for example "Page Hashes: Passed".
struct BinaryStatusBadge: View {
    let presentation: BinaryStatusPresentation
    var subject: String? = nil

    var body: some View {
        ZStatusBadge(presentation.text, systemImage: presentation.systemImage, kind: presentation.kind)
            .accessibilityLabel(subject.map { "\($0): \(presentation.text)" } ?? presentation.text)
    }
}

// MARK: - Rows and cards

/// A label and value that sit side by side when they fit and stack when they
/// do not, so large text sizes never truncate a value.
struct BinaryFieldRow: View {
    let label: String
    let value: String
    var explanation: String? = nil
    var monospaced: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: ZSpacing.sm) {
                    labelText
                    Spacer(minLength: ZSpacing.sm)
                    valueText
                        .multilineTextAlignment(.trailing)
                }
                VStack(alignment: .leading, spacing: 2) {
                    labelText
                    valueText
                }
            }
            if let explanation {
                Text(explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var labelText: some View {
        Text(label)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private var valueText: some View {
        Text(value)
            .font(monospaced ? .system(.subheadline, design: .monospaced) : .subheadline)
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A heading for a group of cards.
struct BinarySectionHeading: View {
    let title: String
    let systemImage: String
    var subtitle: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ZSpacing.xs) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, ZSpacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A card whose content expands on request. Collapsed by default, so
/// technical detail is offered, never imposed.
struct BinaryExpandableCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let status: BinaryStatusPresentation?
    let content: Content
    @State private var isExpanded: Bool

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        status: BinaryStatusPresentation? = nil,
        initiallyExpanded: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.status = status
        self.content = content()
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        ZCard {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: ZSpacing.sm) {
                    content
                }
                .padding(.top, ZSpacing.sm)
            } label: {
                HStack(alignment: .center, spacing: ZSpacing.sm) {
                    Image(systemName: systemImage)
                        .font(.headline)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        if let subtitle {
                            Text(subtitle)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: ZSpacing.xs)
                    if let status {
                        BinaryStatusBadge(presentation: status, subject: title)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityHint(isExpanded ? "Collapses the details." : "Expands the details.")
        }
    }
}

/// Technical values — offsets, type codes, hexadecimal — kept behind a
/// disclosure that starts collapsed.
struct BinaryAdvancedDetails<Content: View>: View {
    let content: Content
    @State private var isExpanded = false

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: ZSpacing.xs) {
                content
            }
            .padding(.top, ZSpacing.xs)
        } label: {
            Label("Advanced Details", systemImage: "wrench.and.screwdriver")
                .font(.subheadline.weight(.medium))
                .frame(minHeight: 44, alignment: .leading)
        }
        .accessibilityHint("Shows technical values such as offsets and type codes.")
    }
}

/// A row that leads to another page: icon, title, one line of detail, and a
/// value, with a full-width 44-point touch target.
struct BinaryNavigationRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var value: String? = nil

    var body: some View {
        HStack(spacing: ZSpacing.sm) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: ZRadius.sm, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: ZSpacing.xs)
            if let value {
                Text(value)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(ZSpacing.md)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .background(ZColors.cardBackground, in: RoundedRectangle(cornerRadius: ZRadius.card, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: ZRadius.card, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// The statement of what verification does and does not establish, shown
/// wherever a verdict is shown.
struct BinaryScopeNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: ZSpacing.sm) {
            Image(systemName: "lock.doc")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Read-only. \(BinaryInspectionReportRenderer.scopeStatement)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, ZSpacing.xs)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Formatting

/// Value formatting shared by the inspector screens.
enum BinaryFormat {
    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    static func bytesDetailed(_ count: Int) -> String {
        "\(bytes(count)) (\(count.formatted()) bytes)"
    }

    static func memory(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .memory)
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }
}
