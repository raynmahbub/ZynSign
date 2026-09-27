import SwiftUI

/// What ZynSign shows while it is locked.
///
/// The overlay covers the whole interface, which is the strongest form of
/// "hide sensitive information when locked": there is nothing behind it to
/// read. It is one control — unlock — with the reason the system will show
/// already explained, and the outcome of a failed attempt reported rather
/// than swallowed.
struct AppLockOverlay: View {

    @Environment(\.appLock) private var appLock
    @State private var isAuthenticating = false
    @State private var message: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
            VStack(spacing: ZSpacing.lg) {
                ZynSignMark(size: 72)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(7)
                            .background(Circle().fill(Color(.systemGray)))
                            .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2))
                            .offset(x: 8, y: 8)
                    }
                    .accessibilityHidden(true)
                VStack(spacing: ZSpacing.xs) {
                    Text("ZynSign is locked")
                        .font(.title3.weight(.semibold))
                    Text("Unlock to continue. Your certificates, profiles, and applications stay protected while ZynSign is locked.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    unlock()
                } label: {
                    Label("Unlock", systemImage: "faceid")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isAuthenticating)
                if isAuthenticating {
                    ProgressView()
                }
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(ZSpacing.xl)
            .frame(maxWidth: 360)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: ZRadius.xl))
            .padding(ZSpacing.xl)
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityElement(children: .contain)
    }

    private func unlock() {
        isAuthenticating = true
        message = nil
        Task {
            let outcome = await appLock.unlock()
            isAuthenticating = false
            if !outcome.isAuthenticated {
                message = outcome.message
            }
        }
    }
}

#Preview {
    AppLockOverlay()
        .environment(\.appLock, AppLockController(
            authenticator: LocalAuthenticationBiometricAuthenticator(),
            preferences: { ZynSignPreferences.shippedDefault }
        ))
}
