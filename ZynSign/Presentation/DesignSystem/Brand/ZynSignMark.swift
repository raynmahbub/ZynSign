import SwiftUI

// MARK: - ZynSign Brand Mark

/// The canonical ZynSign mark — the bold Z over the seal dot on the indigo tile.
///
/// This is the single source of truth for the mark's geometry. Every in-app
/// appearance of the logo (Settings summary, About, Home welcome header, onboarding,
/// empty states) renders through this view. Its proportions are taken from
/// `Assets/Brand/Logo/logo-mark.svg` (128 viewBox, tile 120 at 4/4, rx 30, Z stroke 14,
/// diagonal bezier, seal dot at 100/94 r 6.5) and from `Assets/Brand/AppIcon/app-icon.svg`
/// (1024 full-bleed tile). A change to the brand geometry happens here first,
/// then the SVGs, then the derived PNGs are re-rendered from the same numbers.
///
/// Rules:
/// - The Z is a single continuous stroked path with round caps and joins — no
///   three-segment seams, no gaps at the diagonal joints.
/// - The tile gradient is the light variant `#6D6AF0 → #4B48C4` on light and
///   `#7C79F5 → #5A57D6` on dark, matching `logo-mark.svg` / `logo-mark-dark.svg`.
/// - The seal dot is `#30D158` and never scales independently of the tile.
/// - The view is vector — it draws at any size without rasterization artifacts.
struct ZynSignMark: View {

    /// Side length of the square mark.
    var size: CGFloat = 60

    /// Whether the seal dot is shown. The shipping mark always shows it.
    var showsSealDot: Bool = true

    /// Force the dark tile variant. When `nil` the variant follows `colorScheme`.
    var forceDarkVariant: Bool? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            tile
            zShape
            if showsSealDot { sealDot }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }

    // MARK: - Tile

    private var useDarkTile: Bool {
        if let forceDarkVariant { return forceDarkVariant }
        return colorScheme == .dark
    }

    private var tileGradient: LinearGradient {
        if useDarkTile {
            LinearGradient(
                colors: [Color(red: 0x7C/255.0, green: 0x79/255.0, blue: 0xF5/255.0),
                         Color(red: 0x5A/255.0, green: 0x57/255.0, blue: 0xD6/255.0)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            LinearGradient(
                colors: [Color(red: 0x6D/255.0, green: 0x6A/255.0, blue: 0xF0/255.0),
                         Color(red: 0x4B/255.0, green: 0x48/255.0, blue: 0xC4/255.0)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var tile: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(tileGradient)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(useDarkTile ? 0.18 : 0.14), lineWidth: max(1, size * 0.012))
            )
    }

    private var cornerRadius: CGFloat {
        // 30 / 128 ≈ 0.2344 — matches logo-mark.svg rx 30 within 128 viewBox
        size * 0.234375
    }

    // MARK: - Z

    private var zShape: some View {
        // Single continuous path: M 38 42 H 90 C 76 56 60 70 40 86 H 90
        // Stroke 14 / 128, lineCap .round, lineJoin .round — seam-free.
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            // Reference is 128 × 128; scale uniformly (square canvas)
            let s = w / 128.0

            var path = Path()
            path.move(to: CGPoint(x: 38 * s, y: 42 * s))
            path.addLine(to: CGPoint(x: 90 * s, y: 42 * s))
            path.addCurve(
                to: CGPoint(x: 40 * s, y: 86 * s),
                control1: CGPoint(x: 76 * s, y: 56 * s),
                control2: CGPoint(x: 60 * s, y: 70 * s)
            )
            path.addLine(to: CGPoint(x: 90 * s, y: 86 * s))

            context.stroke(
                path,
                with: .color(.white),
                style: StrokeStyle(lineWidth: 14 * s, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: size, height: size)
    }

    private var sealDot: some View {
        Canvas { context, canvasSize in
            let s = canvasSize.width / 128.0
            let center = CGPoint(x: 100 * s, y: 94 * s)
            let radius = 6.5 * s
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            let dotPath = Path(ellipseIn: rect)
            context.fill(dotPath, with: .color(Color(red: 0x30/255.0, green: 0xD1/255.0, blue: 0x58/255.0)))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Lockup (mark + wordmark)

/// The lockup — mark followed by the "ZynSign" wordmark.
/// Used in banners and in places that need an immediate brand statement
/// (Home welcome header's companion, About header's companion, Settings summary).
struct ZynSignLockup: View {
    var markSize: CGFloat = 52
    var fontSize: CGFloat = 22
    var spacing: CGFloat = 10
    var forceDarkVariant: Bool? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: spacing) {
            ZynSignMark(size: markSize, forceDarkVariant: forceDarkVariant)
            Text("ZynSign")
                .font(.system(size: fontSize, weight: .bold, design: .default))
                .tracking(-0.6)
                .foregroundStyle(wordmarkColor)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("ZynSign")
    }

    private var wordmarkColor: Color {
        if let forceDarkVariant {
            return forceDarkVariant ? Color(red: 0xF5/255.0, green: 0xF5/255.0, blue: 0xF7/255.0) : Color(red: 0x1D/255.0, green: 0x1D/255.0, blue: 0x1F/255.0)
        }
        return colorScheme == .dark
            ? Color(red: 0xF5/255.0, green: 0xF5/255.0, blue: 0xF7/255.0)
            : Color(red: 0x1D/255.0, green: 0x1D/255.0, blue: 0x1F/255.0)
    }
}

// MARK: - Banner (for previews / about hero)

/// A banner-style header that mirrors `Assets/Brand/Banner/banner-*.svg` layout
/// at a smaller SwiftUI scale — used only for in-app previews where an SVG
/// banner cannot be shown.
struct ZynSignBanner: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = colorScheme == .dark
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isDark ? Color(red: 0x15/255.0, green: 0x15/255.0, blue: 0x1D/255.0) : Color(red: 0xF5/255.0, green: 0xF5/255.0, blue: 0xF7/255.0))
            HStack(spacing: 16) {
                ZynSignMark(size: 64, forceDarkVariant: isDark)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ZynSign")
                        .font(.system(size: 28, weight: .bold))
                        .tracking(-0.8)
                        .foregroundStyle(isDark ? Color(red: 0xF5/255.0, green: 0xF5/255.0, blue: 0xF7/255.0) : Color(red: 0x1D/255.0, green: 0x1D/255.0, blue: 0x1F/255.0))
                    Text("Professional iOS sideloading platform")
                        .font(.footnote)
                        .foregroundStyle(isDark ? Color(red: 0xA1/255.0, green: 0xA1/255.0, blue: 0xAA/255.0) : Color(red: 0x6E/255.0, green: 0x6E/255.0, blue: 0x73/255.0))
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
        .frame(height: 96)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(isDark ? 0.08 : 0.10), lineWidth: 1)
        )
        .accessibilityHidden(true)
    }
}

// MARK: - Legacy alias

/// Compatibility alias — the old `ZynSignAppMark(size:)` used in Settings and About.
/// Now renders the authentic brand mark.
typealias ZynSignAppMark = ZynSignMark

// MARK: - Previews

#Preview("Mark — Light 60") {
    ZynSignMark(size: 60)
        .padding()
        .background(Color(.systemGroupedBackground))
}

#Preview("Mark — Dark 60") {
    ZynSignMark(size: 60)
        .preferredColorScheme(.dark)
        .padding()
        .background(Color(.systemGroupedBackground))
}

#Preview("Mark — 32 (favicon)") {
    HStack(spacing: 16) {
        ZynSignMark(size: 32)
        ZynSignMark(size: 20)
        ZynSignMark(size: 16)
    }
    .padding()
}

#Preview("Lockup 52") {
    ZynSignLockup(markSize: 52, fontSize: 24)
        .padding()
}

#Preview("Banner") {
    ZynSignBanner()
        .padding()
}
