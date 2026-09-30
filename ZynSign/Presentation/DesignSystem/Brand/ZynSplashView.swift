import SwiftUI

/// ZynSign launch splash — a brief, quiet Liquid Glass Z·Pen transition.
///
/// Shown once per cold launch from `ZynSignApp` over `RootView` until the
/// first deferred startup work is underway. It reuses the canonical
/// `ZynSignMark` (Liquid Glass tile + transparent white Z·Pen) so the mark
/// the user sees at launch is pixel-identical to every later surface.
///
/// The whole timeline is 360 ms in and 180 ms out (180 ms + 120 ms under
/// Reduce Motion), and **every animation inside it has to finish inside it**.
/// That is the point of this file's shape: a launch layer that is removed while
/// a sub-animation is still mid-flight is seen as a jump, because the frame
/// behind it is the real UI, still laying itself out.
///
/// So there is no looping glow, no shimmer sweep, and no launch haptics — the
/// mark fades up, the wordmark and version follow within the window, and the
/// exit is one fade owned by this view alone (`ZynSignApp` removes the layer
/// without animating it a second time).
///
/// The splash is VoiceOver-hidden (live launch, not content) and auto-dismisses
/// after the window or on tap.
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
                    // Ambient halo behind the tile — the liquid glow, at rest:
                    // a looping pulse can never finish inside a 360 ms window,
                    // and a loop that is cut off mid-swing is the jump.
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
                .animation(.easeOut(duration: 0.22), value: wordmarkAppeared)
                .animation(.easeOut(duration: 0.22).delay(0.06), value: taglineAppeared)
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
                    .animation(.easeOut(duration: 0.2).delay(0.1), value: taglineAppeared)
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
        .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.18), value: dismissing)
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
                .scaleEffect(logoAppeared ? 1 : (reduceMotion ? 1 : 0.82))
                .offset(y: logoAppeared ? 0 : (reduceMotion ? 0 : 14))
                .opacity(logoAppeared ? 1 : 0)
                .blur(radius: logoAppeared ? 0 : (reduceMotion ? 0 : 10))
                .animation(.easeOut(duration: 0.24), value: logoAppeared)
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
        // Keep the launch transition short and quiet: the app is ready behind
        // this view, so the splash should never feel like a loading screen.
        // A single low-amplitude fade is smoother on older devices than the
        // previous sequence of shimmer, glow, and repeated haptics.
        withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.2)) {
            logoAppeared = true
            wordmarkAppeared = true
            taglineAppeared = true
        }
        try? await Task.sleep(for: .milliseconds(reduceMotion ? 180 : 360))
        dismiss()
    }

    /// Fades out, then tells the app to drop the layer.
    ///
    /// The sleep matches the fade's own duration exactly, so the layer is
    /// removed on the frame it reaches zero opacity — never a frame early (a
    /// half-faded splash disappears and the root view snaps in) and never a
    /// frame late (an invisible layer keeps eating hit-tests).
    private func dismiss() {
        guard !dismissing else { return }
        dismissing = true
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
