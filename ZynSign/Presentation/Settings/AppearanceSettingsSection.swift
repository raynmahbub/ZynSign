import SwiftUI

/// Appearance — light, dark, contrast, text size, and the theme.
///
/// The choices that change how the interface looks: the scheme, increased
/// contrast, the theme, an accent override, and the minimal-density mode.
/// Dynamic Type is reported as a fact — supported everywhere, because every
/// screen uses the system's text styles. `AppThemeCatalog` is the single
/// place the shipped themes are defined; this section renders the catalog
/// and writes the user's choice to preferences.
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
            ForEach(AppThemeCatalog.all, id: \.identifier) { theme in
                themeRow(theme)
            }
            accentSection
            ZSettingsToggleRow(
                title: "Minimal Interface",
                subtitle: "Reduce visual density: gradients step back, hero surfaces shrink to their essential rows.",
                symbol: "minus.circle",
                isOn: settings.binding(\.appearance.minimalInterface)
            )
        } header: {
            Text("Theme")
        } footer: {
            Text("The theme changes accents, hero gradients, and density. It never changes what the app does or how signing works.")
        }
    }

    private func themeRow(_ theme: AppThemeDefinition) -> some View {
        let isSelected = settings.preferences.appearance.themeIdentifier == theme.identifier
        return Button {
            settings.update { $0.appearance.themeIdentifier = theme.identifier }
        } label: {
            HStack(spacing: ZSpacing.sm) {
                RoundedRectangle(cornerRadius: ZynSignTokens.Radius.sm, style: .continuous)
                    .fill(LinearGradient(
                        colors: theme.gradientHex.map { Color(themeHex: $0) },
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 44, height: 44)
                    .overlay {
                        Image(systemName: theme.symbolName)
                            .foregroundStyle(.white)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(theme.displayName).font(.body).foregroundStyle(.primary)
                    Text(theme.summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color(themeHex: theme.accentHex) : Color.secondary.opacity(0.4))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.displayName) theme")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The accent override: the theme's own accent plus a small palette.
    private var accentSection: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            Label("Accent", systemImage: "drop")
                .font(.body)
            HStack(spacing: ZSpacing.sm) {
                accentSwatch(nil, label: "Theme")
                ForEach(Self.accentPalette, id: \.self) { hex in
                    accentSwatch(hex, label: hex)
                }
            }
        }
        .padding(.vertical, ZSpacing.xxs)
    }

    private static let accentPalette = ["#FF6A3D", "#FF3B30", "#FF9F0A", "#34C759", "#5E8BFF", "#AF52DE"]

    private func accentSwatch(_ hex: String?, label: String) -> some View {
        let current = settings.preferences.appearance.accentOverrideHex
        let isSelected = (hex == nil && current == nil) || (hex != nil && current == hex)
        return Button {
            settings.update { $0.appearance.accentOverrideHex = hex }
        } label: {
            if let hex {
                Circle()
                    .fill(Color(themeHex: hex))
                    .frame(width: 30, height: 30)
                    .overlay {
                        if isSelected {
                            Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                        }
                    }
            } else {
                Circle()
                    .strokeBorder(Color.secondary, lineWidth: 1.5)
                    .frame(width: 30, height: 30)
                    .overlay {
                        if isSelected {
                            Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.secondary)
                        }
                    }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label == "Theme" ? "Use the theme's accent" : "Accent \(label)")
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
