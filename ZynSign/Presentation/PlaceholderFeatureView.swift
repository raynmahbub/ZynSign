import SwiftUI

/// The placeholder shown for shell sections whose capability is not
/// implemented in the current build.
///
/// The view states what the area is for and that it is not available yet. It
/// offers no controls, because there is nothing to operate on: a control that
/// pretended otherwise would misrepresent the application.
struct PlaceholderFeatureView: View {

    let section: ShellSection

    var body: some View {
        ContentUnavailableView {
            Label(section.title, systemImage: section.symbolName)
        } description: {
            Text(section.statusSummary)
        }
    }
}

#Preview {
    PlaceholderFeatureView(section: .home)
}
