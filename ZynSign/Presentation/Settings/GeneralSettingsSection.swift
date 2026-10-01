import SwiftUI

/// General — where ZynSign starts, how it responds, and how much it moves.
///
/// These are the preferences a user changes once and forgets. Nothing here
/// gates a feature, and nothing here is unfinished: the language row reports
/// that ZynSign ships in English rather than offering a list of languages it
/// cannot speak.
struct GeneralSettingsSection: View {

    @Environment(\.settingsCenter) private var settings
    @State private var isConfirmingOnboardingReset = false
    @State private var isShowingWalkthrough = false

    static let descriptor = SettingsSectionDescriptor(
        identifier: .general,
        title: "General",
        symbolName: "gearshape",
        summary: "Landing tab, feedback, motion, and onboarding.",
        footer: "Every change here is saved as you make it. Nothing waits for a confirmation."
    )

    var body: some View {
        List {
            startupSection
            feedbackSection
            motionSection
            languageSection
            onboardingSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Self.descriptor.title)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Show onboarding again?", isPresented: $isConfirmingOnboardingReset) {
            Button("Cancel", role: .cancel) {}
            Button("Show Again", role: .destructive) {
                settings.resetOnboarding()
            }
        } message: {
            Text("The welcome card will appear on Home the next time you look at it. Nothing you have imported is affected.")
        }
        .sheet(isPresented: $isShowingWalkthrough) {
            ZOnboardingView(
                isPresented: $isShowingWalkthrough,
                onComplete: {}
            )
        }
    }

    // MARK: - Startup

    private var startupSection: some View {
        Section {
            ZSettingsPickerRow(
                title: "Default Landing Tab",
                symbol: "house",
                subtitle: "The tab ZynSign opens when it launches.",
                selection: settings.binding(\.general.landingTab)
            ) {
                ForEach(LandingTab.tabCases, id: \.self) { tab in
                    Text(tab.title).tag(tab)
                }
            }
        } header: {
            Text("Startup")
        } footer: {
            Text("Changing this switches tabs now, and ZynSign will open here next time it launches.")
        }
    }

    // MARK: - Feedback

    private var feedbackSection: some View {
        Section {
            ZSettingsToggleRow(
                title: "Haptic Feedback",
                subtitle: "A light tap when something is confirmed.",
                symbol: "hand.tap",
                isOn: settings.binding(\.general.hapticFeedbackEnabled)
            )
        } header: {
            Text("Feedback")
        } footer: {
            Text("Haptics are produced by the system's feedback engine. Nothing is sent anywhere, and the setting has no effect on a device without a haptic engine.")
        }
    }

    // MARK: - Motion

    private var motionSection: some View {
        Section {
            ZSettingsPickerRow(
                title: "Animation",
                symbol: "wind",
                subtitle: "How much ZynSign's own transitions move.",
                selection: settings.binding(\.general.animationPreference)
            ) {
                ForEach(AnimationPreference.allCases, id: \.self) { preference in
                    Text(preference.displayName).tag(preference)
                }
            }
        } header: {
            Text("Motion")
        } footer: {
            Text("Reduced keeps changes legible without movement. Off removes ZynSign's own transitions. Your system Reduce Motion setting always wins, so you never get more motion than you asked for.")
        }
    }

    // MARK: - Language

    /// Language readiness, stated honestly.
    ///
    /// ZynSign's interface is English only in this version. The preference
    /// model has a place for a language, so a later localization adds a choice
    /// rather than a migration — but offering a picker of languages ZynSign
    /// cannot speak would be a promise, so this row reports the fact instead.
    private var languageSection: some View {
        Section {
            ZSettingsValueRow(
                title: "Language",
                symbol: "character.bubble",
                subtitle: "The language ZynSign's interface uses."
            ) {
                Text("English (U.S.)")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Language")
        } footer: {
            Text("ZynSign ships in English only today. Additional languages are planned; the settings are stored in a way that lets a later release add them without changing anything else you have chosen.")
        }
    }

    // MARK: - Onboarding

    private var onboardingSection: some View {
        Section {
            ZSettingsButtonRow(
                title: "View Onboarding Walkthrough",
                subtitle: "Review the 6-step guided setup walkthrough.",
                symbol: "sparkles",
                action: { isShowingWalkthrough = true }
            )
            ZSettingsButtonRow(
                title: "Reset Onboarding",
                subtitle: "Show the welcome card on Home again.",
                symbol: "arrow.counterclockwise",
                action: { isConfirmingOnboardingReset = true }
            )
        } header: {
            Text("Onboarding")
        } footer: {
            Text("Resetting onboarding only shows the welcome card again. Your library, certificates, profiles, and preferences are untouched.")
        }
    }
}

#Preview {
    NavigationStack {
        GeneralSettingsSection()
    }
    .environment(\.settingsCenter, SettingsCenterModel(
        store: FilePreferencesStore(location: CompositionRoot.preferencesDocumentLocation()),
        environment: CompositionRoot.fallbackEnvironment
    ))
}
