import SwiftUI

/// ZynSign launch splash — Liquid Glass Z+pen with fluid animation and haptics.
///
/// Shown once per cold launch from `ZynSignApp` over `RootView` until the
/// first deferred startup work is underway. It reuses the canonical
/// `ZynSignMark` (Liquid Glass tile + transparent white Z+pen) so the mark
/// the user sees at launch is pixel-identical to every later surface.
///
/// Animation (when Reduce Motion is off):
///  - Logo: initial scale 0.82 + y 14 + blur 12 → spring to 1.0 with bouncy liquid feel
///  - Glass shimmer: a diagonal white sweep across the tile (masked to the rounded rect)
///  - Wordmark + tagline: staged fade + slide up
///  - Ambient glow: pulsing blurred halo behind the mark
///  - Haptics: light → medium → selection → success across the timeline
///
/// When Reduce Motion is on the splash collapses to a quick cross-fade with
/// no spring, no shimmer, and reduced haptics.
///
/// The splash is VoiceOver-hidden (live launch, not content) and auto-dismisses
/// after ~1.9s (1.1s with reduce motion) or on tap.
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
                                    (isDark ? Color(red: 0x7C/255.0, green: 0x79/255.0, blue: 0xF5/255.0) : Color(red: 0x6D/255.0, green: 0x6A/255.0, blue: 0xF0/255.0)).opacity(isDark ? 0.28 : 0.22),
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

                    // The canonical mark — Liquid Glass tile + white Z+pen
                    splashMark
                }

                // Wordmark
                VStack(spacing: 6) {
                    Text("ZynSign")
                        .font(.system(size: 36, weight: .bold, design: .default))
                        .tracking(-1.1)
                        .foregroundStyle(isDark ? Color.white : Color(red: 0x1D/255.0, green: 0x1D/255.0, blue: 0x1F/255.0))
                        .opacity(wordmarkAppeared ? 1 : 0)
                        .offset(y: wordmarkAppeared ? 0 : 10)
                    Text("On-device signing, made Apple-quality.")
                        .font(.system(size: 14, weight: .medium, design: .default))
                        .foregroundStyle(isDark ? Color.white.opacity(0.68) : Color(red: 0x6E/255.0, green: 0x6E/255.0, blue: 0x73/255.0))
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
            (isDark ? Color(red: 0x0E/255.0, green: 0x0E/255.0, blue: 0x13/255.0) : Color(red: 0xF5/255.0, green: 0xF5/255.0, blue: 0xF7/255.0))
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
        .onChange(of: reduceMotion) { _, _ in
            // If the user toggles Reduce Motion mid-splash, finish quickly.
        }
    }

    // MARK: - Mark

    @ViewBuilder
    private var splashMark: some View {
        let markSize: CGFloat = 116
        ZStack {
            ZynSignMark(size: markSize, forceDarkVariant: isDark ? true : false)
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
                            .clipShape(RoundedRectangle(cornerRadius: markSize * 0.234375, style: .continuous))
                            .allowsHitTesting(false)
                    }
                }
                // Subtle drop shadow for depth against the background
                .shadow(color: Color.black.opacity(isDark ? 0.22 : 0.14), radius: 24, x: 0, y: 12)
                .shadow(color: (isDark ? Color(red: 0x7C/255.0, green: 0x79/255.0, blue: 0xF5/255.0) : Color(red: 0x6D/255.0, green: 0x6A/255.0, blue: 0xF0/255.0)).opacity(0.18), radius: 32, x: 0, y: 8)
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
                    : [Color(red: 0xF5/255.0, green: 0xF5/255.0, blue: 0xF7/255.0), Color(red: 0xE8/255.0, green: 0xE6/255.0, blue: 0xFF/255.0)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // Large ambient glows — as in banners, but blurred for launch
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            (isDark ? Color(red: 0x7C/255.0, green: 0x79/255.0, blue: 0xF5/255.0) : Color(red: 0x6D/255.0, green: 0x6A/255.0, blue: 0xF0/255.0)).opacity(isDark ? 0.22 : 0.16),
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
                            (isDark ? Color(red: 0x5A/255.0, green: 0x57/255.0, blue: 0xD6/255.0) : Color(red: 0x4B/255.0, green: 0x48/255.0, blue: 0xC4/255.0)).opacity(isDark ? 0.16 : 0.12),
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

    // MARK: - Timeline with haptics

    private func runTimeline() async {
        // Reduce Motion fast path
        if reduceMotion {
            logoAppeared = true
            wordmarkAppeared = true
            taglineAppeared = true
            glowPulse = true
            try? await Task.sleep(nanoseconds: 700_000_000)
            dismiss()
            return
        }

        // 0.0 — light tick as the window appears
        ZHaptics.impact(.light)

        // 0.08 — logo pops
        try? await Task.sleep(nanoseconds: 80_000_000)
        withAnimation { logoAppeared = true }
        glowPulse = true
        // Shimmer starts shortly after the logo lands
        try? await Task.sleep(nanoseconds: 180_000_000)
        shimmerActive = true
        ZHaptics.impact(.medium)

        // 0.35 — wordmark rises
        try? await Task.sleep(nanoseconds: 120_000_000)
        withAnimation { wordmarkAppeared = true }
        ZHaptics.selection()

        // 0.55 — tagline
        try? await Task.sleep(nanoseconds: 180_000_000)
        withAnimation { taglineAppeared = true }

        // Let the shimmer sweep complete, then settle
        try? await Task.sleep(nanoseconds: 600_000_000)
        // second soft pulse
        ZHaptics.selection()

        // Hold for readability — total ~1.9s before dismiss
        try? await Task.sleep(nanoseconds: 520_000_000)
        dismiss()
    }

    private func dismiss() {
        guard !dismissing else { return }
        dismissing = true
        ZHaptics.success()
        // Give the dismiss animation time before removing the view
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: reduceMotion ? 280_000_000 : 460_000_000)
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

#Preview("Splash — Reduce Motion") {
    ZynSplashView {}
        .environment(\.accessibilityReduceMotion, true)
}
