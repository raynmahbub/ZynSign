import SwiftUI

/// Settings → Compatibility Lab: the validation dashboard for a release.
///
/// The section is registered like any other, and is listed apart from the
/// everyday sections because it is not one: it configures nothing, and it
/// exists so a release candidate can be judged. It is compiled into Debug and
/// internal builds; in any other build it says so instead of showing a
/// dashboard that could not run.
///
/// Nothing in this section changes what the user has. A Lab run builds
/// synthetic packages in a scratch directory, reads them back through the
/// production pipeline, and deletes what it made.
struct CompatibilityLabSection: View {

    static let descriptor = SettingsSectionDescriptor(
        identifier: .compatibilityLab,
        title: "Compatibility Lab",
        symbolName: "testtube.products",
        summary: "Run the compatibility, performance and recovery checks a release is judged by.",
        footer: "The Lab is validation apparatus, not a feature. It builds synthetic packages, exercises the pipeline with them, and reports what it found — nothing of yours is imported, signed, exported or removed.",
        isAdvanced: true,
        isValidationOnly: true
    )

    var body: some View {
        CompatibilityLabView()
    }
}
