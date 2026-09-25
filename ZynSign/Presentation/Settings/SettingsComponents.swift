import SwiftUI

// The rows every settings section is built from.
//
// Settings are a list of decisions, so the decisions look alike: a symbol, a
// title, one line of explanation, and one control. These components are the
// only place that pattern is drawn, which is what keeps the Control Center
// consistent while sections come and go.
//
// Accessibility is not a pass over these rows at the end — it is how they are
// written. Every control is a real SwiftUI control with a text label, so
// VoiceOver reads what it does rather than what it looks like; every row is
// at least a standard list row tall, which is comfortably past the 44-point
// touch target; and every value that can be hidden says so instead of
// showing dots.

// MARK: - Toggle row

/// A toggle with a title, an explanation, and a symbol.
struct ZSettingsToggleRow: View {

    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            ZSettingsLabel(title: title, subtitle: subtitle, symbol: symbol)
        }
        .toggleStyle(.switch)
    }
}

// MARK: - Value row

/// A preference shown as a value, for the settings that are facts rather than
/// choices — a version, a location, or something a later release will offer.
struct ZSettingsValueRow<Value: View>: View {

    let title: String
    var symbol: String?
    var subtitle: String?
    private let value: () -> Value

    init(
        title: String,
        symbol: String? = nil,
        subtitle: String? = nil,
        @ViewBuilder value: @escaping () -> Value
    ) {
        self.title = title
        self.symbol = symbol
        self.subtitle = subtitle
        self.value = value
    }

    var body: some View {
        LabeledContent {
            value()
        } label: {
            ZSettingsLabel(title: title, subtitle: subtitle, symbol: symbol)
        }
    }
}

// MARK: - Picker row

/// A choice between a small, fixed set of options.
struct ZSettingsPickerRow<Selection: Hashable, Content: View>: View {

    let title: String
    var symbol: String?
    var subtitle: String?
    @Binding var selection: Selection
    private let content: () -> Content

    init(
        title: String,
        symbol: String? = nil,
        subtitle: String? = nil,
        selection: Binding<Selection>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.subtitle = subtitle
        _selection = selection
        self.content = content
    }

    var body: some View {
        Picker(selection: $selection) {
            content()
        } label: {
            ZSettingsLabel(title: title, subtitle: subtitle, symbol: symbol)
        }
    }
}

// MARK: - Button row

/// An action, optionally destructive.
struct ZSettingsButtonRow: View {

    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    var isDestructive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZSettingsLabel(title: title, subtitle: subtitle, symbol: symbol)
                .foregroundStyle(isDestructive ? Color.red : Color.accentColor)
        }
    }
}

// MARK: - Label

/// The symbol, title, and explanation every settings row carries.
struct ZSettingsLabel: View {

    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil

    var body: some View {
        HStack(alignment: .center, spacing: ZSpacing.sm) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 26, alignment: .center)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // The row's own label is the accessible name; the explanation is read
        // with it rather than as a separate element.
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Banner

/// A short, prominent statement: what a section is for, or what a state means.
struct ZSettingsBanner: View {
    enum Kind {
        case info
        case warning
        case neutral

        var color: Color {
            switch self {
            case .info: return .blue
            case .warning: return .orange
            case .neutral: return .secondary
            }
        }

        var symbol: String {
            switch self {
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .neutral: return "circle.fill"
            }
        }
    }

    let title: String
    var message: String
    var kind: Kind = .info

    var body: some View {
        HStack(alignment: .top, spacing: ZSpacing.sm) {
            Image(systemName: kind.symbol)
                .font(.title3)
                .foregroundStyle(kind.color)
                .frame(width: 26, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ZSpacing.sm)
        .background(kind.color.opacity(0.10), in: RoundedRectangle(cornerRadius: ZRadius.card))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Sensitive value

/// A value that identifies signing material — a certificate fingerprint, a
/// profile name.
///
/// Whether it is shown is the Security Center's decision, made in one place
/// (`AppLockController.shouldHideSensitiveValues()`), so the Certificates
/// list, the Profiles list, and the signing preferences cannot disagree. When
/// it is hidden, the row says so: a row of dots with no explanation is worse
/// than no row.
///
/// No private key material can reach this view. It is a string the user can
/// already read elsewhere in the interface; keys are not strings, and never
/// leave the Keychain.
struct SensitiveValueText: View {

    let value: String
    var placeholder: String = "Not set"

    @Environment(\.appLock) private var appLock

    var body: some View {
        if appLock.shouldHideSensitiveValues() {
            Text("Hidden")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Hidden until ZynSign is unlocked")
        } else {
            Text(value.isEmpty ? placeholder : value)
                .font(.subheadline)
                .foregroundStyle(value.isEmpty ? .secondary : .primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Storage bar

/// One share of the storage total.
struct ZStorageUsageBar: View {

    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: ZRadius.sm)
                    .fill(Color(.tertiarySystemFill))
                RoundedRectangle(cornerRadius: ZRadius.sm)
                    .fill(Color.accentColor)
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

// MARK: - Appearance mapping

extension AppearanceMode {

    /// The scheme the interface should use, or `nil` to follow the system.
    var resolvedColorScheme: SwiftUI.ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
