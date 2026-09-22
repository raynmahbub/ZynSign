import Foundation

/// The top-level sections of the ZynSign shell.
///
/// Presentation metadata only: the shell renders these as navigation entries.
/// A section being listed does not mean the capability exists — every section
/// except Settings currently renders an explicit placeholder stating that the
/// capability is not part of the build.
enum ShellSection: Hashable, CaseIterable, Identifiable {
    case applications
    case importPackage
    case signing
    case settings

    var id: Self { self }

    /// The navigation title of the section.
    var title: String {
        switch self {
        case .applications: return "Applications"
        case .importPackage: return "Import"
        case .signing: return "Signing"
        case .settings: return "Settings"
        }
    }

    /// The symbol shown for the section's navigation entry.
    var symbolName: String {
        switch self {
        case .applications: return "square.stack.3d.up"
        case .importPackage: return "square.and.arrow.down"
        case .signing: return "signature"
        case .settings: return "gearshape"
        }
    }

    /// An honest description of what the section is for and its current build
    /// status. The text deliberately avoids implying that a capability works
    /// beyond what this build does.
    var statusSummary: String {
        switch self {
        case .applications:
            return "Imported packages are recorded in ZynSign's library and kept across launches. A screen for browsing and managing the library is not part of this build yet."
        case .importPackage:
            return "Import brings a selected package into ZynSign, reads its structure and declared metadata, and records accepted packages in the library."
        case .signing:
            return "Signing a package with an identity and provisioning profile is not part of this build yet."
        case .settings:
            return "Configuration is not part of this build yet."
        }
    }
}
