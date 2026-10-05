import SwiftUI

/// ZynSign's own bottom tab bar — the Storefront shell, drawn in liquid glass.
///
/// The shell does not use UIKit's tab bar, and this view is the reason: that
/// bar draws five items and folds everything after the fifth into a *More*
/// list it **pushes**. A pushed destination that owns a `NavigationStack` —
/// which every ZynSign area does — crashes at runtime.
///
/// The bar draws exactly the five root tabs the product keeps (see
/// `ShellSection.allTabs`: Home, Library, Store, Downloads, Settings) and no
/// more. It is a floating glass island rather than a full-width chrome strip:
/// on iOS 26 it renders as a system glass capsule, on earlier systems as the
/// material + specular recipe, and with Liquid Glass turned off in Settings →
/// Appearance it falls back to the classic solid `.bar` background flush to the
/// home-indicator edge — one switch, decided by `ZGlass`, never per-surface.
///
/// The bar owns no navigation and no state: the selection belongs to
/// the shell, the content lives in `RootView`, and a tap is reported through
/// the binding.
struct ShellTabBar: View {

    /// The destinations to draw, in bar order.
    let tabs: [ShellSection]

    /// The shell's selected destination.
    @Binding var selection: ShellSection

    /// The badge a destination should show. Zero shows none.
    let badgeCount: (ShellSection) -> Int

    /// The selection capsule is tinted with the resolved theme accent, so
    /// the bar follows the theme — and the Storefront look — with no
    /// per-screen styling.
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        HStack(alignment: .center, spacing: ZSpacing.xxs) {
            ForEach(tabs) { section in
                item(for: section)
            }
        }
        .padding(.horizontal, ZSpacing.xs)
        .padding(.vertical, ZSpacing.xs)
        .modifier(ShellBarBackground())
        .padding(.horizontal, ZSpacing.sm)
        .padding(.bottom, ZSpacing.xxs)
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
            withAnimation(ZMotion.fast, { selection = section })
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
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.title)
        .accessibilityValue(badge > 0 ? "\(badge) active" : "")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// The bar's own background, one decision for three states: system glass on
/// iOS 26, material glass before it, and the solid classic bar otherwise.
private struct ShellBarBackground: ViewModifier {
    @Environment(\.appTheme) private var appTheme

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), appTheme.liquidGlass {
            content.glassEffect(.regular, in: Capsule())
        } else if appTheme.liquidGlass {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.35), Color.white.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
                .zynSoftShadow()
        } else {
            content
                .background(.bar, in: RoundedRectangle(cornerRadius: 0))
                .overlay(alignment: .top) {
                    Divider()
                }
        }
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
