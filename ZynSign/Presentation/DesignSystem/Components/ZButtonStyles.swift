import SwiftUI

/// Standardized button styles for ZynSign.
///
/// Ensures consistent interactive feedback, touch-target sizing (44pt+),
/// spring press states, and haptics across all screens.

/// Prominent primary action button.
struct ZPrimaryButtonStyle: ButtonStyle {
    var isFullWidth: Bool = false
    var cornerRadius: CGFloat = ZRadius.card

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, ZSpacing.lg)
            .padding(.vertical, ZSpacing.sm)
            .frame(maxWidth: isFullWidth ? .infinity : nil, minHeight: 44)
            .background(Color.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed { ZHaptics.tap() }
            }
    }
}

/// Secondary action button with subtle fill and border.
struct ZSecondaryButtonStyle: ButtonStyle {
    var isFullWidth: Bool = false
    var cornerRadius: CGFloat = ZRadius.card

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, ZSpacing.md)
            .padding(.vertical, ZSpacing.sm)
            .frame(maxWidth: isFullWidth ? .infinity : nil, minHeight: 44)
            .background(Color(.secondarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color(.separator).opacity(0.4), lineWidth: 0.5)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed { ZHaptics.tap() }
            }
    }
}

/// Destructive action button.
struct ZDestructiveButtonStyle: ButtonStyle {
    var isFullWidth: Bool = false
    var cornerRadius: CGFloat = ZRadius.card

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.red)
            .padding(.horizontal, ZSpacing.md)
            .padding(.vertical, ZSpacing.sm)
            .frame(maxWidth: isFullWidth ? .infinity : nil, minHeight: 44)
            .background(Color.red.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed { ZHaptics.warning() }
            }
    }
}

/// Large prominent button used for primary calls to action (Onboarding, Signing confirm).
struct ZLargeProminentButtonStyle: ButtonStyle {
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(tint)
            .clipShape(RoundedRectangle(cornerRadius: ZRadius.lg, style: .continuous))
            .zynSoftShadow(ZShadow.card)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed { ZHaptics.tap() }
            }
    }
}

extension View {
    func zPrimaryButton(isFullWidth: Bool = false) -> some View {
        buttonStyle(ZPrimaryButtonStyle(isFullWidth: isFullWidth))
    }

    func zSecondaryButton(isFullWidth: Bool = false) -> some View {
        buttonStyle(ZSecondaryButtonStyle(isFullWidth: isFullWidth))
    }

    func zLargeProminentButton(tint: Color = .accentColor) -> some View {
        buttonStyle(ZLargeProminentButtonStyle(tint: tint))
    }
}
