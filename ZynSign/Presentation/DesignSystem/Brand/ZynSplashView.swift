import SwiftUI

/// ZynSign launch splash — a brief, quiet Liquid Glass Z·Pen transition.
///
/// Shown once per cold launch from `ZynSignApp` over `RootView` until the
/// first deferred startup work is underway. It reuses the canonical
/// `ZynSignMark` (Liquid Glass tile + transparent white Z·Pen) so the mark
/// the user sees at launch is pixel-identical to every later surface.
///
/// The whole timeline is designed for fluid, 60/120fps smooth presentation
/// and exit without layout jank or shader recompilation stutter.
struct ZynSplashView: View {
    var onFinished: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @State private var logoAppeared = false
    @State private var wordmarkAppeared = false
    @State private var taglineAppeared = false
    @State private var dismissing = false

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        ZStack {
            // MARK: Background — liquid ambience
            splashBackground

            // MARK: Center content
            VStack(spacing: 22) {
                // Logo with ambient glow
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    (isDark ? ZynBrand.indigoDarkTop : ZynBrand.indigoTop).opacity(isDark ? 0.28 : 0.22),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 20,
                                endRadius: 160
                            )
                        )
                        .frame(width: 260, height: 260)
                        .blur(radius: 18)
                        .opacity(logoAppeared ? 1 : 0)
                        .animation(.easeOut(duration: reduceMotion ? 0.15 : 0.28), value: logoAppeared)

                    // The canonical mark — Liquid Glass tile + white Z·Pen
                    splashMark
                }

                // Wordmark
                VStack(spacing: 6) {
                    Text("ZynSign")
                        .font(.system(size: 36, weight: .bold, design: .default))
                        .tracking(-1.1)
                        .foregroundStyle(isDark ? Color.white : ZynBrand.ink)
                        .opacity(wordmarkAppeared ? 1 : 0)
                        .offset(y: wordmarkAppeared ? 0 : 8)
                        .animation(.easeOut(duration: reduceMotion ? 0.15 : 0.26).delay(reduceMotion ? 0 : 0.04), value: wordmarkAppeared)

                    Text("On-device signing, made Apple-quality.")
                        .font(.system(size: 14, weight: .medium, design: .default))
                        .foregroundStyle(isDark ? Color.white.opacity(0.68) : ZynBrand.mutedLight)
                        .opacity(taglineAppeared ? 1 : 0)
                        .offset(y: taglineAppeared ? 0 : 4)
                        .animation(.easeOut(duration: reduceMotion ? 0.15 : 0.26).delay(reduceMotion ? 0 : 0.08), value: taglineAppeared)
                }
            }
            .padding(.horizontal, 32)

            // Version footer
            VStack {
                Spacer()
                let info = ApplicationInfo.current()
                Text("\(info.marketingVersion) (\(info.buildVersion))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(isDark ? Color.white.opacity(0.32) : Color.primary.opacity(0.28))
                    .opacity(taglineAppeared ? 1 : 0)
                    .animation(.easeOut(duration: reduceMotion ? 0.15 : 0.24).delay(reduceMotion ? 0 : 0.1), value: taglineAppeared)
                    .padding(.bottom, 28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            // Solid fallback for the window background while the splash is up
            (isDark ? Color(red: 0x0E/255.0, green: 0x0E/255.0, blue: 0x13/255.0) : ZynBrand.paper)
                .ignoresSafeArea()
        )
        .opacity(dismissing ? 0 : 1)
        .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.24), value: dismissing)
        .accessibilityHidden(true)
        .onTapGesture {
            guard !dismissing else { return }
            dismiss()
        }
        .task {
            await runTimeline()
        }
    }

    // MARK: - Mark

    @ViewBuilder
    private var splashMark: some View {
        let markSize: CGFloat = 116
        ZStack {
            ZynSignMark(size: markSize, forceDarkVariant: isDark)
                .scaleEffect(logoAppeared ? 1 : (reduceMotion ? 1 : 0.88))
                .offset(y: logoAppeared ? 0 : (reduceMotion ? 0 : 10))
                .opacity(logoAppeared ? 1 : 0)
                .animation(.spring(response: 0.35, dampingFraction: 0.82), value: logoAppeared)
                // Subtle drop shadow for depth against the background
                .shadow(color: Color.black.opacity(isDark ? 0.22 : 0.14), radius: 24, x: 0, y: 12)
                .shadow(color: (isDark ? ZynBrand.indigoDarkTop : ZynBrand.indigoTop).opacity(0.18), radius: 32, x: 0, y: 8)
        }
        .frame(width: markSize, height: markSize)
    }

    // MARK: - Background

    private var splashBackground: some View {
        ZStack {
            // Base
            LinearGradient(
                colors: isDark
                    ? [Color(red: 0x1A/255.0, green: 0x15/255.0, blue: 0x2B/255.0), Color(red: 0x0E/255.0, green: 0x0E/255.0, blue: 0x14/255.0)]
                    : [ZynBrand.paper, Color(red: 0xE8/255.0, green: 0xE6/255.0, blue: 0xFF/255.0)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // Large ambient glows — as in banners, but blurred for launch
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            (isDark ? ZynBrand.indigoDarkTop : ZynBrand.indigoTop).opacity(isDark ? 0.22 : 0.16),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 60,
                        endRadius: 420
                    )
                )
                .frame(width: 820, height: 820)
                .offset(x: -180, y: -260)
                .blur(radius: 12)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            (isDark ? ZynBrand.indigoDarkBottom : ZynBrand.indigoBottom).opacity(isDark ? 0.16 : 0.12),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 80,
                        endRadius: 480
                    )
                )
                .frame(width: 760, height: 760)
                .offset(x: 200, y: 380)
                .blur(radius: 14)
        }
    }

    // MARK: - Short launch transition

    private func runTimeline() async {
        // Trigger states smoothly
        logoAppeared = true
        wordmarkAppeared = true
        taglineAppeared = true

        try? await Task.sleep(for: .milliseconds(reduceMotion ? 200 : 380))
        dismiss()
    }

    /// Fades out, then tells the app to drop the layer.
    private func dismiss() {
        guard !dismissing else { return }
        dismissing = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 150 : 240))
            onFinished()
        }
    }
}

#Preview("Splash — Light") {
    ZynSplashView {}
}

#Preview("Splash — Dark") {
    ZynSplashView {}
        .preferredColorScheme(.dark)
}

#Preview("Splash — Light") {
    ZynSplashView {}
}

#Preview("Splash — Dark") {
    ZynSplashView {}
        .preferredColorScheme(.dark)
}
