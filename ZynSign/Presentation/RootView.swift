import SwiftUI

/// The root of the ZynSign interface: the application shell.
///
/// The shell exposes the product's top-level areas as tabs and adapts to
/// iPhone and iPad idioms. Settings renders factual information about the
/// application itself; every other area is an explicit placeholder until the
/// corresponding workflow exists.
struct RootView: View {

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
        case .settings:
            SettingsView()
        default:
            PlaceholderFeatureView(section: section)
        }
    }
}

#Preview {
    RootView()
}
