import SwiftUI

/// ZynSign toast — slide-in banner for import/sign success or refusal.
///
/// Usage: `.overlay { if show { ZToast("Imported MyApp") } }`
/// Never contains business logic; caller decides when to show and haptics.
struct ZToast: View {
    enum Style {
        case success, warning, error, info
        var color: Color {
            switch self {
            case .success: return .green
            case .warning: return .orange
            case .error: return .red
            case .info: return .blue
            }
        }
        var icon: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            case .info: return "info.circle.fill"
            }
        }
    }

    let message: String
    let style: Style
    var onDismiss: (() -> Void)? = nil

    init(_ message: String, style: Style = .success, onDismiss: (() -> Void)? = nil) {
        self.message = message; self.style = style; self.onDismiss = onDismiss
    }

    var body: some View {
        HStack(spacing: ZSpacing.sm) {
            Image(systemName: style.icon)
                .foregroundStyle(style.color)
                .font(.title3)
            Text(message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if onDismiss != nil {
                Button { onDismiss?() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, ZSpacing.md)
        .padding(.vertical, ZSpacing.sm)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: ZRadius.card))
        .overlay { RoundedRectangle(cornerRadius: ZRadius.card).stroke(style.color.opacity(0.2), lineWidth: 1) }
        .zynSoftShadow()
        .padding(.horizontal, ZSpacing.md)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityLabel(message)
    }
}

/// Modifier to show a ZToast at the top of any view
struct ZToastModifier: ViewModifier {
    @Binding var isPresented: Bool
    let message: String
    let style: ZToast.Style
    let duration: Duration

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if isPresented {
                ZToast(message, style: style) { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { isPresented = false } }
                    .padding(.top, ZSpacing.sm)
                    .onAppear {
                        // Auto-dismiss after duration, haptic on appear
                        ZHaptics.success()
                        Task {
                            try? await Task.sleep(for: duration)
                            await MainActor.run {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { isPresented = false }
                            }
                        }
                    }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isPresented)
    }
}

extension View {
    func zToast(isPresented: Binding<Bool>, message: String, style: ZToast.Style = .success, duration: Duration = .seconds(3)) -> some View {
        modifier(ZToastModifier(isPresented: isPresented, message: message, style: style, duration: duration))
    }
}
