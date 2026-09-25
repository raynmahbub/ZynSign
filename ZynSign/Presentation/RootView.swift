import SwiftUI

/// The root of the ZynSign interface: the tab shell the user navigates.
///
/// Tabs are in the deliberate order ZynSign presents: Files → Library →
/// Home → App Store → Downloads → Settings. Each case is a real area with
/// its own NavigationStack; no placeholder is shown. Home is the default
/// selected tab so a fresh install lands on the dashboard.
///
/// App Store and Downloads appear only once the release train reaches the
/// stage that ships them (`ReleaseTrain.isAvailable`).
struct RootView: View {

    @Environment(\.applicationEnvironment) private var environment
    @State private var selected: ShellSection = .home

    var body: some View {
        TabView(selection: $selected) {
            FilesView()
                .tabItem { Label(ShellSection.files.title, systemImage: selected == .files ? ShellSection.files.symbolName : ShellSection.files.symbolNameUnselected) }
                .tag(ShellSection.files)

            LibraryTabView()
                .tabItem { Label(ShellSection.library.title, systemImage: selected == .library ? ShellSection.library.symbolName : ShellSection.library.symbolNameUnselected) }
                .tag(ShellSection.library)

            HomeView()
                .tabItem { Label(ShellSection.home.title, systemImage: selected == .home ? ShellSection.home.symbolName : ShellSection.home.symbolNameUnselected) }
                .tag(ShellSection.home)

            if ReleaseTrain.isAvailable(.appStore) {
                AppStoreView()
                    .tabItem { Label(ShellSection.appStore.title, systemImage: selected == .appStore ? ShellSection.appStore.symbolName : ShellSection.appStore.symbolNameUnselected) }
                    .tag(ShellSection.appStore)
            }

            if ReleaseTrain.isAvailable(.downloads) {
                DownloadsView()
                    .tabItem { Label(ShellSection.downloads.title, systemImage: selected == .downloads ? ShellSection.downloads.symbolName : ShellSection.downloads.symbolNameUnselected) }
                    .tag(ShellSection.downloads)
            }

            SettingsView()
                .tabItem { Label(ShellSection.settings.title, systemImage: selected == .settings ? ShellSection.settings.symbolName : ShellSection.settings.symbolNameUnselected) }
                .tag(ShellSection.settings)
        }
        .tint(.primary)
    }
}

#Preview {
    RootView().environment(\.applicationEnvironment, CompositionRoot.makeApplicationEnvironment())
}
