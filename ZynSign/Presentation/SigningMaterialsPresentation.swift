import SwiftUI

/// How any screen asks the shell to import a signing-material file.
///
/// Certificates and provisioning profiles are not the Import Hub's
/// business: they belong to Certificates & Profiles, and every way one can
/// arrive — Open In, a drag from another app — must land in the same
/// password-sheet and profile-import flows a deliberate choice opens,
/// rather than in the hub's refusal. Screens ask through this value; the
/// shell owns the presentation exactly as it does for the Import Hub, so a
/// drop, a hand-off, and a tap on a button can never become three subtly
/// different certificate imports.
///
/// The default implementation does nothing, so a screen shown outside the
/// shell (a preview, a test) never crashes on a missing presentation; it
/// simply has nowhere to route the file, and the caller falls back to the
/// hub's own explanation. `isAvailable` lets a caller tell "no shell here"
/// from "shell that declined".
struct SigningMaterialsPresentation {

    /// Opens Certificates with `url` — a `.p12` / `.pfx` — ready to import
    /// through the password sheet.
    var importIdentity: (URL) -> Void = { _ in }

    /// Opens Profiles with `url` — a `.mobileprovision` — ready to import.
    var importProfile: (URL) -> Void = { _ in }

    /// Whether a signing-material presentation exists to ask.
    var isAvailable: Bool = false
}

private struct SigningMaterialsPresentationKey: EnvironmentKey {
    static let defaultValue = SigningMaterialsPresentation()
}

extension EnvironmentValues {

    /// The signing-material presentation the shell installed.
    var signingMaterialsPresentation: SigningMaterialsPresentation {
        get { self[SigningMaterialsPresentationKey.self] }
        set { self[SigningMaterialsPresentationKey.self] = newValue }
    }
}
