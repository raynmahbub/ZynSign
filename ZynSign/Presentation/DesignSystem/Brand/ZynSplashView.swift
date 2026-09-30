import SwiftUI

/// ZynSign launch splash — a brief, quiet Liquid Glass Z·Pen transition.
///
/// Shown once per cold launch from `ZynSignApp` over `RootView` until the
/// first deferred startup work is underway. It reuses the canonical
/// `ZynSignMark` (Liquid Glass tile + transparent white Z·Pen) so the mark
/// the user sees at launch is pixel-identical to every later surface.
///
/// Animation (when Reduce Motion is off):
///  - Logo: initial scale 0.82 + y 14 + blur 12 → spring to 1.0 with bouncy liquid feel
///  - Glass shimmer: a diagonal white sweep across the tile (masked to the rounded rect)
///  - Wordmark + tagline: staged fade + slide up
///  - Ambient glow: pulsing blurred halo behind the mark
///  - Haptics: light → medium → selection → success across the timeline
///
/// The splash uses a short fade and no launch haptics so it does not delay
/// the first useful frame or compete with startup work.
///
/// The splash is VoiceOver-hidden (live launch, not content) and auto-dismisses
/// after a short transition or on tap.
struct ZynSplashView: View {
    var onFinished: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @State private var logoAppeared = false
    @State private var wordmarkAppeared = false
    @State private var taglineAppeared = false
    @State private var shimmerActive = false
    @State private var dismissing = false
    @State private var glowPulse = false

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        ZStack {
            // MARK: Background — liquid ambience
            splashBackground

            // MARK: Center content
            VStack(spacing: 22) {
                // Logo with ambient glow
                ZStack {
                    // Pulsing halo behind the tile — the liquid glow
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
                        .scaleEffect(glowPulse ? 1.08 : 0.92)
                        .opacity(logoAppeared ? 1 : 0)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: glowPulse)

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
                        .offset(y: wordmarkAppeared ? 0 : 10)
                    Text("On-device signing, made Apple-quality.")
                        .font(.system(size: 14, weight: .medium, design: .default))
                        .foregroundStyle(isDark ? Color.white.opacity(0.68) : ZynBrand.mutedLight)
                        .opacity(taglineAppeared ? 1 : 0)
                        .offset(y: taglineAppeared ? 0 : 6)
                }
                .animation(reduceMotion ? .easeOut(duration: 0.25) : .spring(response: 0.5, dampingFraction: 0.82), value: wordmarkAppeared)
                .animation(reduceMotion ? .easeOut(duration: 0.25).delay(0.12) : .spring(response: 0.5, dampingFraction: 0.82).delay(0.12), value: taglineAppeared)
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
                    .animation(.easeOut(duration: 0.4).delay(reduceMotion ? 0.2 : 0.9), value: taglineAppeared)
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
        .scaleEffect(dismissing ? (reduceMotion ? 1 : 0.96) : 1)
        .blur(radius: dismissing ? (reduceMotion ? 0 : 6) : 0)
        .animation(reduceMotion ? .easeOut(duration: 0.28) : .spring(response: 0.45, dampingFraction: 0.86), value: dismissing)
        .accessibilityHidden(true)
        .onTapGesture {
            guard !dismissing else { return }
            ZHaptics.tap()
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
                .scaleEffect(logoAppeared ? 1 : (reduceMotion ? 1 : 0.82))
                .offset(y: logoAppeared ? 0 : (reduceMotion ? 0 : 14))
                .opacity(logoAppeared ? 1 : 0)
                .blur(radius: logoAppeared ? 0 : (reduceMotion ? 0 : 10))
                .animation(
                    reduceMotion
                        ? .easeOut(duration: 0.32)
                        : .spring(response: 0.88, dampingFraction: 0.68),
                    value: logoAppeared
                )
                // Glass shimmer sweep — diagonal highlight sliding across the tile
                .overlay {
                    if !reduceMotion {
                        shimmerOverlay(size: markSize)
                            .clipShape(RoundedRectangle(cornerRadius: markSize * ZynSignMark.cornerRatio, style: .continuous))
                            .allowsHitTesting(false)
                    }
                }
                // Subtle drop shadow for depth against the background
                .shadow(color: Color.black.opacity(isDark ? 0.22 : 0.14), radius: 24, x: 0, y: 12)
                .shadow(color: (isDark ? ZynBrand.indigoDarkTop : ZynBrand.indigoTop).opacity(0.18), radius: 32, x: 0, y: 8)
        }
        .frame(width: markSize, height: markSize)
    }

    private func shimmerOverlay(size: CGFloat) -> some View {
        // A thin diagonal white band that sweeps from -1 to +1
        let bandWidth: CGFloat = size * 0.42
        return GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            LinearGradient(
                colors: [
                    Color.white.opacity(0),
                    Color.white.opacity(0.0),
                    Color.white.opacity(0.55),
                    Color.white.opacity(0.0),
                    Color.white.opacity(0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(width: bandWidth, height: h * 1.6)
            .rotationEffect(.degrees(18))
            .offset(x: shimmerActive ? w + bandWidth : -bandWidth - 24, y: -h * 0.3)
            .blur(radius: 1.2)
            .opacity(shimmerActive ? 1 : 0)
        }
        .allowsHitTesting(false)
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
        // Keep the launch transition short and quiet: the app is ready behind
        // this view, so the splash should never feel like a loading screen.
        // A single low-amplitude fade is smoother on older devices than the
        // previous sequence of shimmer, glow, and repeated haptics.
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.2)) {
            logoAppeared = true
            wordmarkAppeared = true
            taglineAppeared = true
            glowPulse = true
            shimmerActive = !reduceMotion
        }
        try? await Task.sleep(for: .milliseconds(reduceMotion ? 180 : 360))
        dismiss()
    }

    private func dismiss() {
        guard !dismissing else { return }
        dismissing = true
        // Remove the launch layer as soon as its brief fade is complete.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 120 : 180))
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
