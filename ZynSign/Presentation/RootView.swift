import SwiftUI

/// The root of the ZynSign interface: the application shell.
///
/// The shell exposes the product's top-level areas as tabs and adapts to
/// iPhone and iPad idioms. Import, Applications, and Signing are working
/// capabilities in this build — Signing runs the profile-validation and
/// application-signing pipelines behind explicit inputs — and Settings
/// renders factual information about the application itself.
struct RootView: View {

    @Environment(\.applicationEnvironment)
    private var environment

    var body: some View {
        TabView {
            ForEach(ShellSection.allCases) { section in
                content(for: section)
                    .tabItem {
                        Label(section.title, systemImage: section.symbolName)
                    }
            }
        }
    }

    @ViewBuilder
    private func content(for section: ShellSection) -> some View {
        switch section {
        case .applications:
            ApplicationLibraryView(
                library: environment.library,
                importing: environment.packageImport,
                bundleInspection: environment.bundleInspection
            )
        case .importPackage:
            PackageImportView(importing: environment.packageImport)
        case .signing:
            SigningView(
                signing: environment.signing,
                library: environment.library
            )
        case .settings:
            SettingsView()
        }
    }
}

#Preview {
    RootView()
}
