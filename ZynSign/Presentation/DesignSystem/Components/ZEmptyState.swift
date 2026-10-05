import SwiftUI

/// Standardized, premium empty state for ZynSign.
///
/// Replaces generic system placeholders with bespoke iconography,
/// plain-language explanations, and clear primary actions.
struct ZEmptyState: View {

    let title: String
    let message: String
    let systemImage: String
    let tint: Color
    let badgeSymbol: String?
    let primaryActionTitle: String?
    let primaryAction: (() -> Void)?
    let secondaryActionTitle: String?
    let secondaryAction: (() -> Void)?
    /// A bespoke line-art drawing; when set it replaces the symbol disc.
    let lineArt: ZEmptyIllustration?

    init(
        title: String,
        message: String,
        systemImage: String,
        tint: Color = .accentColor,
        badgeSymbol: String? = nil,
        primaryActionTitle: String? = nil,
        primaryAction: (() -> Void)? = nil,
        secondaryActionTitle: String? = nil,
        secondaryAction: (() -> Void)? = nil,
        lineArt: ZEmptyIllustration? = nil
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.tint = tint
        self.badgeSymbol = badgeSymbol
        self.primaryActionTitle = primaryActionTitle
        self.primaryAction = primaryAction
        self.secondaryActionTitle = secondaryActionTitle
        self.secondaryAction = secondaryAction
        self.lineArt = lineArt
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

                Text(message)
                    .font(ZTypography.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 340)
            }

            if primaryActionTitle != nil || secondaryActionTitle != nil {
                VStack(spacing: ZSpacing.xs) {
                    if let primaryActionTitle, let primaryAction {
                        Button {
                            ZHaptics.tap()
                            primaryAction()
                        } label: {
                            Text(primaryActionTitle)
                                .font(.subheadline.weight(.semibold))
                                .frame(minWidth: 160)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    }

                    if let secondaryActionTitle, let secondaryAction {
                        Button {
                            ZHaptics.tap()
                            secondaryAction()
                        } label: {
                            Text(secondaryActionTitle)
                                .font(.subheadline)
                        }
                        .buttonStyle(.borderless)
                        .padding(.top, 4)
                    }
                }
                .padding(.top, ZSpacing.xs)
            }
        }
        .padding(ZSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Layered illustration

    @ViewBuilder
    private var illustration: some View {
        if let lineArt {
            lineArt.view(size: 112, tint: tint)
                .padding(ZSpacing.sm)
                .zynSoftShadow(ZShadow.subtle)
        } else {
            symbolIllustration
        }
    }

    private var symbolIllustration: some View {
        ZStack {
            // Outer glow ring
            Circle()
                .fill(tint.opacity(0.08))
                .frame(width: 104, height: 104)

            // Inner soft disc
            Circle()
                .fill(tint.opacity(0.16))
                .frame(width: 80, height: 80)

            // Hero symbol
            Image(systemName: systemImage)
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(tint)

            // Optional corner badge
            if let badgeSymbol {
                Image(systemName: badgeSymbol)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(tint)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                    .offset(x: 30, y: -28)
            }
        }
        .zynSoftShadow(ZShadow.subtle)
        .accessibilityHidden(true)
    }
}

// MARK: - Factory Presets

extension ZEmptyState {

    /// Empty state for Application Library when no packages have been imported.
    static func noApps(action: @escaping () -> Void) -> ZEmptyState {
        ZEmptyState(
            title: "Your Library is Empty",
            message: "Import your first iOS application (.ipa or .tipa) to inspect its binaries, entitlements, and sign it for your device.",
            systemImage: "square.stack.3d.up.slash",
            tint: .blue,
            badgeSymbol: "plus",
            primaryActionTitle: "Import Package…",
            primaryAction: action,
            lineArt: .noApps
        )
    }

    /// Empty state for the Certificates segment in the combined area.
    static func noCertificates(action: @escaping () -> Void) -> ZEmptyState {
        ZEmptyState(
            title: "No Certificates Yet",
            message: "Import a .p12 developer identity to sign applications. Private keys are encrypted and stored safely in the iOS Keychain.",
            systemImage: "signature",
            tint: .purple,
            badgeSymbol: "key.fill",
            primaryActionTitle: "Import Certificate",
            primaryAction: action,
            lineArt: .noCertificates
        )
    }

    /// Empty state for the Profiles segment in the combined area.
    static func noProfiles(action: @escaping () -> Void) -> ZEmptyState {
        ZEmptyState(
            title: "No Profiles Yet",
            message: "Add an Apple provisioning profile (.mobileprovision) that authorizes your application's bundle identifier and capabilities.",
            systemImage: "person.text.rectangle",
            tint: .orange,
            badgeSymbol: "plus",
            primaryActionTitle: "Import Profile",
            primaryAction: action
        )
    }

    /// Empty state for Downloads tab.
    static func noDownloads(action: @escaping () -> Void) -> ZEmptyState {
        ZEmptyState(
            title: "No Active Downloads",
            message: "Add a direct .ipa or itms-services link to download in the background. Downloads survive app restarts.",
            systemImage: "arrow.down.circle",
            tint: .teal,
            badgeSymbol: "link",
            primaryActionTitle: "Add Download URL",
            primaryAction: action,
            lineArt: .noDownloads
        )
    }

    /// Empty state for user custom collections.
    static func noCollections(action: @escaping () -> Void) -> ZEmptyState {
        ZEmptyState(
            title: "No Custom Collections",
            message: "Organize applications by project, testing group, or workflow using custom collections.",
            systemImage: "folder.badge.plus",
            tint: .indigo,
            badgeSymbol: "folder",
            primaryActionTitle: "Create Collection",
            primaryAction: action
        )
    }

    /// Empty state for signing or diagnostic history.
    static func noHistory(action: (() -> Void)? = nil) -> ZEmptyState {
        ZEmptyState(
            title: "No History Recorded",
            message: "Completed signing sessions, audit trails, and validation summaries will appear here.",
            systemImage: "clock.arrow.circlepath",
            tint: .secondary,
            badgeSymbol: "doc.text",
            primaryActionTitle: action != nil ? "View Library" : nil,
            primaryAction: action
        )
    }

    /// Empty state for Signing Presets.
    static func noPresets(action: @escaping () -> Void) -> ZEmptyState {
        ZEmptyState(
            title: "No Signing Presets",
            message: "Save combinations of certificates, provisioning profiles, and entitlements rules for fast one-tap signing.",
            systemImage: "slider.horizontal.3",
            tint: .teal,
            badgeSymbol: "plus",
            primaryActionTitle: "Create First Preset",
            primaryAction: action
        )
    }

    /// Empty state for the Professional Signing Queue.
    static func noQueueJobs(action: @escaping () -> Void) -> ZEmptyState {
        ZEmptyState(
            title: "Signing Queue is Idle",
            message: "Queue applications from your library to sign in the background. Each job runs in an isolated workspace.",
            systemImage: "tray",
            tint: .indigo,
            badgeSymbol: "checkmark",
            primaryActionTitle: "Open Library",
            primaryAction: action
        )
    }

    /// Empty state for search and filter results.
    static func noSearchResults(query: String, onClear: @escaping () -> Void) -> ZEmptyState {
        ZEmptyState(
            title: "No Results for “\(query)”",
            message: "No matching items found. Check your search terms, bundle identifier spelling, or active filters.",
            systemImage: "magnifyingglass",
            tint: .secondary,
            badgeSymbol: "xmark",
            primaryActionTitle: "Clear Search & Filters",
            primaryAction: onClear
        )
    }

    /// Empty state when sources list is empty.
    static func noSources(action: @escaping () -> Void) -> ZEmptyState {
        ZEmptyState(
            title: "No Sources Added",
            message: "Add an AltSource feed to discover community applications and receive package updates.",
            systemImage: "globe.desk",
            tint: .blue,
            badgeSymbol: "plus",
            primaryActionTitle: "Add AltSource Feed",
            primaryAction: action,
            lineArt: .noSources
        )
    }

    /// Empty state when library or subsystem is unavailable.
    static func unavailable(title: String, message: String, onRetry: @escaping () -> Void) -> ZEmptyState {
        ZEmptyState(
            title: title,
            message: message,
            systemImage: "exclamationmark.triangle",
            tint: .orange,
            primaryActionTitle: "Retry",
            primaryAction: onRetry
        )
    }
}
