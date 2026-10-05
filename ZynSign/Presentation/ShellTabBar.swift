import SwiftUI

/// ZynSign's own bottom tab bar.
///
/// The shell does not use UIKit's tab bar, and this view is the reason: that
/// bar draws five items and folds everything after the fifth into a *More*
/// list it **pushes**. A pushed destination that owns a `NavigationStack` —
/// which every ZynSign area does — crashes at runtime. Store and Downloads
/// remain direct destinations when their release gates are open; the Features
/// catalogue and signing materials are workflows inside Settings.
///
/// The shell draws its own bar so UIKit's five-item ceiling cannot decide
/// which root destinations the product shows. Every root tab the release
/// exposes gets a real slot here. The bar owns no navigation and no state: the selection belongs to
/// the shell, the content lives in `RootView`, and a tap is reported through
/// the binding.
struct ShellTabBar: View {

    /// The destinations to draw, in bar order.
    let tabs: [ShellSection]

    /// The shell's selected destination.
    @Binding var selection: ShellSection

    /// The badge a destination should show. Zero shows none.
    let badgeCount: (ShellSection) -> Int

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            ForEach(tabs) { section in
                item(for: section)
            }
        }
        .padding(.top, ZSpacing.xs)
        .padding(.bottom, ZSpacing.xxs)
        .background(.bar, ignoresSafeAreaEdges: .bottom)
        .overlay(alignment: .top) {
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sections")
    }

    /// One destination: its symbol, its name, and at most one badge.
    ///
    /// The label is drawn at a size that fits the narrowest slot a full bar
    /// leaves on the smallest supported phone, and scaled down further rather
    /// than truncated: a tab whose name cannot be read is not a tab a user can
    /// find.
    private func item(for section: ShellSection) -> some View {
        let isSelected = section == selection
        let badge = badgeCount(section)
        return Button {
            guard !isSelected else { return }
            ZHaptics.tap()
            selection = section
        } label: {
            VStack(spacing: ZSpacing.xxs) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: isSelected ? section.symbolName : section.symbolNameUnselected)
                        .font(.title3.weight(isSelected ? .semibold : .regular))
                        .frame(width: 30, height: 22)
                    if badge > 0 {
                        Text(badge > 99 ? "99+" : "\(badge)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, ZSpacing.xxs)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.red))
                            .offset(x: 6, y: -6)
                            .accessibilityHidden(true)
                    }
                }
                Text(section.title)
                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.title)
        .accessibilityValue(badge > 0 ? "\(badge) active" : "")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

#Preview {
    // One environment, like the shell's: the shared composition-root fallback.
    VStack {
        Spacer()
        ShellTabBar(
            tabs: ShellSection.allTabs,
            selection: .constant(.home),
            badgeCount: { $0 == .downloads ? 3 : 0 }
        )
    }
    .environment(\.applicationEnvironment, CompositionRoot.fallbackEnvironment)
}
