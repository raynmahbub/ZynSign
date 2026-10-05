import SwiftUI

/// ZynSign card — the standardized container for filled, material, and outlined cards.
///
/// Usage: `ZCard { VStack { ... } }` or `ZCard(variant: .material) { ... }`.
/// Handles corner radii, backgrounds, subtle borders, and elevation shadows
/// consistently across Light and Dark Mode.
struct ZCard<Content: View>: View {
    @Environment(\.appTheme) private var appTheme

    enum Variant {
        case filled      // secondarySystemBackground + soft shadow + subtle border
        case material    // ultraThinMaterial + soft shadow + subtle border
        case outlined    // clear + stroke
    }

    let variant: Variant
    let cornerRadius: CGFloat
    let content: Content

    init(variant: Variant = .filled, cornerRadius: CGFloat = ZRadius.card, @ViewBuilder content: () -> Content) {
        self.variant = variant
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        Group {
            if #available(iOS 26.0, *), appTheme.liquidGlass {
                // iOS 26: the card *is* the system glass — refraction and
                // edge highlight included; no material fill, no extra stroke,
                // and no shadow the glass would already cast.
                content
                    .padding(ZSpacing.md)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay {
                        // Outlined cards still ask for their own stroke, and
                        // glass must not swallow it.
                        if variant == .outlined {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .stroke(Color(.separator), lineWidth: 0.5)
                        }
                    }
            } else {
                content
                    .padding(ZSpacing.md)
                    .background(background)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .zynSoftShadow(variant == .outlined ? ZShadow.ShadowToken(color: .clear, radius: 0, x: 0, y: 0) : ZShadow.soft)
                    .overlay {
                        if variant == .outlined {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .stroke(Color(.separator), lineWidth: 0.5)
                        } else if appTheme.liquidGlass {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .stroke(ZGlass.highlight, lineWidth: 1)
                        } else {
                            // Subtle border ensures cards maintain crisp contrast against pure OLED black
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var background: some View {
        if appTheme.liquidGlass {
            Rectangle().fill(.ultraThinMaterial)
        } else {
            switch variant {
            case .filled: ZColors.cardBackground
            case .material: Rectangle().fill(ZColors.headerMaterial)
            case .outlined: Color.clear
            }
        }
    }
}

/// Convenience header card used for dashboard announcements, summaries, and hero cards.
struct ZHeaderCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        ZCard(variant: .material, cornerRadius: ZRadius.lg) { content }
    }
}
