import SwiftUI
import UIKit

/// Standardized error view for ZynSign.
///
/// Ensures error presentation is actionable, transparent, and user-friendly:
/// - What happened
/// - Why it happened
/// - What to do next
/// - Expandable technical diagnostics for troubleshooting and bug reporting
struct ZErrorView: View {

    let title: String
    let explanation: String
    let suggestedAction: String?
    let technicalDetails: String?
    let onRetry: (() -> Void)?
    let onDismiss: (() -> Void)?
    let onLearnMore: (() -> Void)?

    @State private var isShowingTechnicalDetails = false
    @State private var didCopyDiagnostics = false

    init(
        title: String,
        explanation: String,
        suggestedAction: String? = nil,
        technicalDetails: String? = nil,
        onRetry: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil,
        onLearnMore: (() -> Void)? = nil
    ) {
        self.title = title
        self.explanation = explanation
        self.suggestedAction = suggestedAction
        self.technicalDetails = technicalDetails
        self.onRetry = onRetry
        self.onDismiss = onDismiss
        self.onLearnMore = onLearnMore
    }

    var body: some View {
        VStack(spacing: ZSpacing.lg) {
            illustration

            VStack(spacing: ZSpacing.xs) {
                Text(title)
                    .font(ZTypography.title3)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)

                Text(explanation)
                    .font(ZTypography.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 340)
            }

            if let suggestedAction {
                HStack(alignment: .top, spacing: ZSpacing.xs) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                        .padding(.top, 2)
                    Text(suggestedAction)
                        .font(ZTypography.footnote)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(ZSpacing.sm)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: ZRadius.card))
                .frame(maxWidth: 360)
            }

            if let technicalDetails, !technicalDetails.isEmpty {
                VStack(alignment: .leading, spacing: ZSpacing.xs) {
                    DisclosureGroup("Technical Details", isExpanded: $isShowingTechnicalDetails) {
                        VStack(alignment: .leading, spacing: ZSpacing.xs) {
                            ScrollView {
                                Text(technicalDetails)
                                    .font(ZTypography.codeCaption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(ZSpacing.xs)
                            }
                            .frame(maxHeight: 120)
                            .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: ZRadius.sm))

                            Button {
                                UIPasteboard.general.string = technicalDetails
                                didCopyDiagnostics = true
                                ZHaptics.success()
                                Task {
                                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                                    didCopyDiagnostics = false
                                }
                            } label: {
                                Label(didCopyDiagnostics ? "Copied!" : "Copy Diagnostic Details",
                                      systemImage: didCopyDiagnostics ? "checkmark" : "doc.on.doc")
                                    .font(.caption.weight(.medium))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                            .padding(.top, 2)
                        }
                        .padding(.top, 4)
                    }
                    .font(.footnote.weight(.medium))
                    .tint(.secondary)
                }
                .padding(.horizontal, ZSpacing.md)
                .frame(maxWidth: 360)
            }

            actionButtons
        }
        .padding(ZSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var illustration: some View {
        ZStack {
            Circle()
                .fill(Color.orange.opacity(0.12))
                .frame(width: 88, height: 88)

            Circle()
                .fill(Color.orange.opacity(0.18))
                .frame(width: 68, height: 68)

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.orange)
        }
        .zynSoftShadow(ZShadow.subtle)
        .accessibilityHidden(true)
    }

    private var actionButtons: some View {
        VStack(spacing: ZSpacing.xs) {
            if let onRetry {
                Button {
                    ZHaptics.tap()
                    onRetry()
                } label: {
                    Text("Try Again")
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }

            if let onLearnMore {
                Button {
                    ZHaptics.tap()
                    onLearnMore()
                } label: {
                    Text("Learn More")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
            }

            if let onDismiss {
                Button {
                    ZHaptics.tap()
                    onDismiss()
                } label: {
                    Text("Dismiss")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .padding(.top, 2)
            }
        }
        .padding(.top, ZSpacing.xs)
    }
}
