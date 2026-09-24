import SwiftUI

/// ZynSign card — the only container for material/filled cards.
///
/// Usage: `ZCard { VStack { ... } }` or `ZCard(variant: .material) { ... }`.
/// Never add your own `background` or `shadow` inside; `ZCard` owns them.
struct ZCard<Content: View>: View {
    enum Variant {
        case filled      // secondarySystemBackground + soft shadow
        case material    // ultraThinMaterial + soft shadow
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
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .zynSoftShadow(variant == .outlined ? ZShadow.ShadowToken(color: .clear, radius: 0, x: 0, y: 0) : ZShadow.soft)
            .overlay {
                if variant == .outlined {
                    RoundedRectangle(cornerRadius: cornerRadius).stroke(Color(.separator), lineWidth: 0.5)
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

// Convenience for the common “header” card
struct ZHeaderCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        ZCard(variant: .material, cornerRadius: ZRadius.lg) { content }
    }
}
