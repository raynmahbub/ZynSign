import SwiftUI

/// Appearance — light, dark, contrast, and the text size.
///
/// Three choices and two facts. The choices are the ones that change how the
/// interface looks: the scheme, and whether the system is asked for increased
/// contrast. The facts are Dynamic Type — supported everywhere, because every
/// screen uses the system's text styles — and the theme, of which there is
/// exactly one. An invented second theme would be worse than none, so this
/// section says so rather than offering one.
struct AppearanceSettingsSection: View {

    @Environment(\.settingsCenter) private var settings

    static let descriptor = SettingsSectionDescriptor(
        identifier: .appearance,
        title: "Appearance",
        symbolName: "paintbrush",
        summary: "Light or dark, contrast, and text size.",
        footer: "Appearance applies immediately. Contrast follows your system setting where the interface uses the system's own colours."
    )

    var body: some View {
        List {
            schemeSection
            contrastSection
            textSizeSection
            themeSection
            iconSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Self.descriptor.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Scheme

    private var schemeSection: some View {
        Section {
            ZSettingsPickerRow(
                title: "Appearance",
                symbol: "circle.lefthalf.filled",
                subtitle: "Light, dark, or whatever the system is set to.",
                selection: settings.binding(\.appearance.appearanceMode)
            ) {
                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Scheme")
        } footer: {
            Text("\"System\" follows your device's light and dark schedule and changes when it does.")
        }
    }

    // MARK: - Contrast

    private var contrastSection: some View {
        Section {
            ZSettingsToggleRow(
                title: "Increase Contrast",
                subtitle: "Ask the system for higher-contrast colours throughout ZynSign.",
                symbol: "circle.righthalf.filled",
                isOn: settings.binding(\.appearance.increaseContrast)
            )
        } header: {
            Text("Contrast")
        } footer: {
            Text("This is the same distinction your system's Increase Contrast setting makes. Turning it on here applies it to ZynSign only; turning it off restores ZynSign to your system's setting.")
        }
    }

    // MARK: - Text size

    /// Dynamic Type, reported rather than configured.
    ///
    /// Every screen in ZynSign is laid out with the system's text styles, so
    /// the text size chosen in Settings → Display & Brightness applies
    /// everywhere without ZynSign needing a setting of its own. Offering a
    /// second, competing text size would only make the two disagree.
    private var textSizeSection: some View {
        Section {
            ZSettingsValueRow(
                title: "Dynamic Type",
                symbol: "textformat.size",
                subtitle: "Your system text size, applied to every screen."
            ) {
                Text("Supported")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Text Size")
        } footer: {
            Text("ZynSign uses the system's text styles throughout, so your text-size setting applies to every screen, including Settings. There is no separate text size to choose, and nothing to reset.")
        }
    }

    // MARK: - Theme

    private var themeSection: some View {
        Section {
            ZSettingsValueRow(
                title: "Theme",
                symbol: "paintpalette",
                subtitle: "The colour and material set ZynSign draws with."
            ) {
                Text(ZynSignTheme.zynSign.displayName)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Theme")
        } footer: {
            Text("One theme ships today, and it is the one ZynSign was designed with. The setting stores which theme is in use, so a later release can add themes without changing anything else you have chosen.")
        }
    }

    // MARK: - Icon

    private var iconSection: some View {
        Section {
            NavigationLink { AppIconSettingsView() } label: {
                ZSettingsLabel(
                    title: "App Icon",
                    subtitle: "The icon ZynSign shows on your Home Screen.",
                    symbol: "app.badge"
                )
            }
        } header: {
            Text("Icon")
        }
    }
}

#Preview {
    NavigationStack {
        AppearanceSettingsSection()
    }
    .environment(\.settingsCenter, SettingsCenterModel(
        store: FilePreferencesStore(location: CompositionRoot.preferencesDocumentLocation()),
        environment: CompositionRoot.makeApplicationEnvironment()
    ))
}
