import SwiftUI

/// Premium first-launch onboarding walkthrough.
///
/// Follows the 6-step guided setup:
/// 1. Welcome
/// 2. Import Apps
/// 3. Add Certificate
/// 4. Add Profile
/// 5. Explore Library
/// 6. You’re Ready
///
/// Users can step forward and back, or choose "Skip" at any point.
/// Completing or skipping records `onboardingCompleted = true` in preferences.
struct ZOnboardingView: View {

    @Binding var isPresented: Bool
    var onComplete: () -> Void

    @State private var currentStepIndex: Int = 0
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    enum OnboardingStep: Int, CaseIterable, Identifiable {
        case welcome = 0
        case importApps = 1
        case addCertificate = 2
        case addProfile = 3
        case exploreLibrary = 4
        case ready = 5

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .welcome: return "Welcome to ZynSign"
            case .importApps: return "Import Applications"
            case .addCertificate: return "Add Signing Identities"
            case .addProfile: return "Provisioning Profiles"
            case .exploreLibrary: return "Explore & Organize"
            case .ready: return "You’re Ready to Sign"
            }
        }

        var subtitle: String {
            switch self {
            case .welcome:
                return "The professional on-device iOS application signing & binary inspection studio."
            case .importApps:
                return "Bring your .ipa and .tipa packages into a local, isolated library."
            case .addCertificate:
                return "Import .p12 developer identities with hardware-backed Keychain security."
            case .addProfile:
                return "Link .mobileprovision profiles that authorize your devices and capabilities."
            case .exploreLibrary:
                return "Deep Mach-O binary analysis, entitlements studio, and smart presets."
            case .ready:
                return "Your on-device workspace is fully configured and ready for your first app."
            }
        }

        var symbol: String {
            switch self {
            case .welcome: return "signature"
            case .importApps: return "square.and.arrow.down.fill"
            case .addCertificate: return "key.fill"
            case .addProfile: return "person.text.rectangle.fill"
            case .exploreLibrary: return "square.grid.2x2.fill"
            case .ready: return "checkmark.seal.fill"
            }
        }

        var tint: Color {
            switch self {
            case .welcome: return .accentColor
            case .importApps: return .blue
            case .addCertificate: return .purple
            case .addProfile: return .orange
            case .exploreLibrary: return .teal
            case .ready: return .green
            }
        }

        var highlights: [(icon: String, title: String, text: String)] {
            switch self {
            case .welcome:
                return [
                    ("lock.shield.fill", "100% On-Device & Private", "Your private keys, certificates, and IPAs never leave your device. Zero cloud processing."),
                    ("cpu.fill", "Apple-Compliant Signatures", "RFC-standard CMS signatures, CodeDirectory SuperBlobs, and nested Mach-O binary handling."),
                    ("sparkles", "Production Quality", "Designed to feel native, responsive, and completely at home on iOS and iPadOS.")
                ]
            case .importApps:
                return [
                    ("folder.fill", "Files & AirDrop", "Import packages from Files, AirDrop, or via Share Sheet directly into ZynSign."),
                    ("hand.draw.fill", "Drag & Drop Ready", "Drop packages straight onto your library from Files or Split View on iPad."),
                    ("magnifyingglass", "Preflight Validation", "Validates ZIP directory integrity and Info.plist structure before saving.")
                ]
            case .addCertificate:
                return [
                    ("key.horizontal.fill", "Keychain Protection", "Private keys are encrypted and stored directly inside the secure iOS Keychain."),
                    ("calendar.badge.clock", "Expiration Intelligence", "Automatic countdown tracking alerts you well before certificates expire."),
                    ("shield.lefthalf.filled", "Zero Key Leakage", "ZynSign never uploads, exports, or transmits your private keys.")
                ]
            case .addProfile:
                return [
                    ("link.badge.plus", "Automatic Matching", "Matches profiles to your apps by bundle identifier pattern and App ID."),
                    ("checkmark.seal", "Entitlements Mapping", "Inspects push notifications, iCloud, and custom capabilities before signing."),
                    ("exclamationmark.triangle.fill", "Stale Profile Warnings", "Alerts you if a profile has expired or doesn't match your certificate.")
                ]
            case .exploreLibrary:
                return [
                    ("slider.horizontal.3", "Signing Presets", "Save reusable combinations of identities and profiles for fast one-tap signing."),
                    ("tray.full.fill", "Background Queue", "Queue multiple signing jobs with priorities and live stage progress."),
                    ("doc.text.magnifyingglass", "Binary Inspector", "Inspect Mach-O headers, load commands, frameworks, and architecture slices.")
                ]
            case .ready:
                return [
                    ("house.fill", "Dashboard Overview", "Keep track of your library, certificates, and profiles on the Home screen."),
                    ("arrow.down.app.fill", "Ready to Sign", "Select an app from your library, pick your identity and profile, and sign."),
                    ("gearshape.fill", "Full Control", "Customize haptics, motion, storage, and diagnostics at any time in Settings.")
                ]
            }
        }
    }

    private var currentStep: OnboardingStep {
        OnboardingStep(rawValue: currentStepIndex) ?? .welcome
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header progress dots
                headerBar

                // Content area with animation
                ScrollView {
                    VStack(spacing: ZSpacing.xl) {
                        heroIllustration
                        titleAndSubtitle
                        highlightRows
                    }
                    .padding(.horizontal, ZSpacing.lg)
                    .padding(.top, ZSpacing.md)
                    .padding(.bottom, ZSpacing.xl)
                }

                // Bottom navigation controls
                bottomNavigation
            }
            .background(Color(.systemBackground))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if currentStepIndex < OnboardingStep.allCases.count - 1 {
                        Button("Skip") {
                            complete()
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases) { step in
                Capsule()
                    .fill(step.rawValue <= currentStepIndex ? currentStep.tint : Color(.tertiarySystemFill))
                    .frame(height: 4)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: currentStepIndex)
            }
        }
        .padding(.horizontal, ZSpacing.lg)
        .padding(.top, ZSpacing.sm)
        .padding(.bottom, ZSpacing.xs)
    }

    // MARK: - Hero Illustration

    @ViewBuilder
    private var heroIllustration: some View {
        if currentStep == .welcome {
            // The welcome step opens on the app's own mark — the same Z·Pen as the
            // home-screen icon and the launch splash.
            ZynSignMark(size: 96)
                .zynSoftShadow(ZShadow.subtle)
                .padding(.top, ZSpacing.sm)
                .accessibilityHidden(true)
        } else {
            ZStack {
                Circle()
                    .fill(currentStep.tint.opacity(0.1))
                    .frame(width: 108, height: 108)

                Circle()
                    .fill(currentStep.tint.opacity(0.18))
                    .frame(width: 84, height: 84)

                Image(systemName: currentStep.symbol)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(currentStep.tint)
            }
            .zynSoftShadow(ZShadow.subtle)
            .padding(.top, ZSpacing.sm)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Title & Subtitle

    private var titleAndSubtitle: some View {
        VStack(spacing: ZSpacing.xs) {
            Text(currentStep.title)
                .font(ZTypography.title2)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text(currentStep.subtitle)
                .font(ZTypography.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)
        }
    }

    // MARK: - Highlights

    private var highlightRows: some View {
        VStack(spacing: ZSpacing.md) {
            ForEach(currentStep.highlights, id: \.title) { item in
                HStack(alignment: .top, spacing: ZSpacing.md) {
                    Image(systemName: item.icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(currentStep.tint)
                        .frame(width: 28, height: 28)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(item.text)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(ZSpacing.md)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: ZRadius.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: ZRadius.card, style: .continuous)
                        .stroke(Color.primary.opacity(0.04), lineWidth: 0.5)
                }
            }
        }
        .frame(maxWidth: 440)
    }

    // MARK: - Bottom Controls

    private var bottomNavigation: some View {
        VStack(spacing: ZSpacing.xs) {
            HStack(spacing: ZSpacing.md) {
                if currentStepIndex > 0 {
                    Button {
                        stepBack()
                    } label: {
                        Text("Back")
                            .font(.subheadline.weight(.medium))
                            .frame(minWidth: 72, minHeight: 48)
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    if currentStepIndex < OnboardingStep.allCases.count - 1 {
                        stepForward()
                    } else {
                        complete()
                    }
                } label: {
                    Text(currentStepIndex == OnboardingStep.allCases.count - 1 ? "Start Using ZynSign" : "Continue")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(currentStep.tint)
            }
            .padding(.horizontal, ZSpacing.lg)
            .padding(.vertical, ZSpacing.sm)
        }
        .background(Color(.systemBackground).shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: -2))
    }

    // MARK: - Actions

    private func stepForward() {
        ZHaptics.selection()
        if systemReduceMotion {
            currentStepIndex += 1
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                currentStepIndex += 1
            }
        }
    }

    private func stepBack() {
        ZHaptics.selection()
        if systemReduceMotion {
            currentStepIndex -= 1
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                currentStepIndex -= 1
            }
        }
    }

    private func complete() {
        ZHaptics.success()
        onComplete()
        isPresented = false
    }
}
