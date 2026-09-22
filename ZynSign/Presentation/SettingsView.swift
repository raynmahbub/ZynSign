import SwiftUI

/// The Settings area of the shell.
///
/// The foundation build has no configurable behaviour, so this area reports
/// factual information about the application itself and states plainly that
/// the workflow capabilities are not implemented. It contains no controls
/// that would suggest otherwise.
struct SettingsView: View {

    @Environment(\.applicationEnvironment)
    private var environment

    var body: some View {
        NavigationStack {
            List {
                Section("About") {
                    LabeledContent("Name", value: environment.applicationInfo.displayName)
                    LabeledContent("Version", value: versionText)
                }
                Section("Capabilities") {
                    Text("This build can import a package you select and read its structure and the metadata its application declares. The application library, signing, verification, packaging, and installation are not implemented.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(ShellSection.settings.title)
        }
    }

    private var versionText: String {
        let info = environment.applicationInfo
        return "\(info.marketingVersion) (\(info.buildVersion))"
    }
}

#Preview {
    SettingsView()
}
