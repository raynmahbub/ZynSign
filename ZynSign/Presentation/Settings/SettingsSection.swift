import SwiftUI

/// The identity of one settings section.
///
/// A section is a peer of every other: adding one is a new case plus a new
/// file, and nothing that already exists has to change.
enum SettingsSectionIdentifier: String, CaseIterable, Hashable, Sendable {
    case general
    case signing
    case security
    case storage
    case diagnostics
    case appearance
    case advanced
    case recovery
    case about
}

/// What the Control Center knows about a section before it opens it.
///
/// The descriptor is the section's own statement about itself: its title, its
/// symbol, the one sentence the hub shows, and the footer its page shows. It
/// lives next to the section rather than in the hub, so the two cannot drift
/// apart.
struct SettingsSectionDescriptor: Identifiable, Hashable, Sendable {

    /// Which section this is.
    let identifier: SettingsSectionIdentifier

    /// The section's name.
    let title: String

    /// The SF Symbol for the section.
    let symbolName: String

    /// One sentence describing what the section configures.
    let summary: String

    /// The explanatory footer the section's page shows.
    var footer: String = ""

    /// Whether the section holds destructive actions.
    var isDestructive: Bool = false

    /// Whether the section is for experienced users, and is therefore listed
    /// apart from everyday settings.
    var isAdvanced: Bool = false

    var id: String { identifier.rawValue }
}

/// One entry in the Control Center: what a section is, and where it goes.
///
/// The destination is a closure so the hub can hold sections of different
/// view types in one list without knowing any of their types. That is the
/// whole extension mechanism: a new section is one new entry.
struct SettingsSectionScreen: Identifiable {

    /// What the section says about itself.
    let descriptor: SettingsSectionDescriptor

    /// Builds the section's page.
    let destination: @MainActor () -> AnyView

    var id: String { descriptor.id }
}

/// Every settings section, in the order the Control Center lists them.
///
/// The catalog is the only place sections are named, and naming one is the
/// entire registration step: a section's contents, its preferences, and its
/// recovery actions live in its own file. Nothing here decides what a section
/// contains, so a later version can add, reorder, or extend sections without
/// restructuring this one.
@MainActor
enum SettingsSectionCatalog {

    /// Every section, in display order.
    static let all: [SettingsSectionScreen] = [
        SettingsSectionScreen(descriptor: GeneralSettingsSection.descriptor) {
            AnyView(GeneralSettingsSection())
        },
        SettingsSectionScreen(descriptor: SigningPreferencesSection.descriptor) {
            AnyView(SigningPreferencesSection())
        },
        SettingsSectionScreen(descriptor: SecurityCenterSection.descriptor) {
            AnyView(SecurityCenterSection())
        },
        SettingsSectionScreen(descriptor: StorageManagerSection.descriptor) {
            AnyView(StorageManagerSection())
        },
        SettingsSectionScreen(descriptor: DiagnosticsPreferencesSection.descriptor) {
            AnyView(DiagnosticsPreferencesSection())
        },
        SettingsSectionScreen(descriptor: AppearanceSettingsSection.descriptor) {
            AnyView(AppearanceSettingsSection())
        },
        SettingsSectionScreen(descriptor: AdvancedSettingsSection.descriptor) {
            AnyView(AdvancedSettingsSection())
        },
        SettingsSectionScreen(descriptor: RecoverySettingsSection.descriptor) {
            AnyView(RecoverySettingsSection())
        },
        SettingsSectionScreen(descriptor: AboutSettingsSection.descriptor) {
            AnyView(AboutSettingsSection())
        }
    ]

    /// The section with `identifier`, or `nil` when no such section exists.
    static func screen(for identifier: SettingsSectionIdentifier) -> SettingsSectionScreen? {
        all.first { $0.descriptor.identifier == identifier }
    }

    /// The everyday sections, in display order.
    static var everyday: [SettingsSectionScreen] {
        all.filter {
            !$0.descriptor.isAdvanced && !$0.descriptor.isDestructive && $0.descriptor.identifier != .about
        }
    }

    /// The sections kept apart from everyday settings.
    static var separated: [SettingsSectionScreen] {
        all.filter { $0.descriptor.isAdvanced || $0.descriptor.isDestructive }
    }

    /// About, on its own at the end.
    static var about: [SettingsSectionScreen] {
        all.filter { $0.descriptor.identifier == .about }
    }

    /// Every section's descriptor, in display order.
    static var descriptors: [SettingsSectionDescriptor] {
        all.map(\.descriptor)
    }
}
