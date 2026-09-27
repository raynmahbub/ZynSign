import SwiftUI

/// ZynSign card — the standardized container for filled, material, and outlined cards.
///
/// Usage: `ZCard { VStack { ... } }` or `ZCard(variant: .material) { ... }`.
/// Handles corner radii, backgrounds, subtle borders, and elevation shadows
/// consistently across Light and Dark Mode.
struct ZCard<Content: View>: View {
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
        content
            .padding(ZSpacing.md)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .zynSoftShadow(variant == .outlined ? ZShadow.ShadowToken(color: .clear, radius: 0, x: 0, y: 0) : ZShadow.soft)
            .overlay {
                if variant == .outlined {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color(.separator), lineWidth: 0.5)
                } else {
                    // Subtle border ensures cards maintain crisp contrast against pure OLED black
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                }
            }
    }

    @ViewBuilder
    private var background: some View {
        switch variant {
        case .filled: ZColors.cardBackground
        case .material: ZColors.headerMaterial
        case .outlined: Color.clear
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
