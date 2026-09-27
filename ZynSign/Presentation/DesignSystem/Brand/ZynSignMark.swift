import SwiftUI

// MARK: - ZynSign Brand Mark

/// The canonical ZynSign mark — the Z with integrated fountain-pen nib + signature swash on the indigo **Liquid Glass** tile.
///
/// This is the single source of truth for the mark's geometry and material. Every
/// in-app appearance of the logo (Settings, About, Home header, onboarding, empty
/// states) renders through this view. Its proportions are taken from
/// `Assets/Brand/Logo/logo-mark.svg` (128 viewBox, tile 120 at 4/4, rx 30) and from
/// `Assets/Brand/AppIcon/app-icon.svg` (1024 full-bleed). The mark is the bold white
/// Z whose diagonal is the pen barrel ending in a detailed fountain nib at the
/// lower-left (shoulder, breather hole, slit, collar ring) with the elegant cursive
/// swash — as in the reference `IMG_6007.jpeg` but re-imagined for **iOS 26 Liquid
/// Glass** (translucent indigo glass, specular top highlight, curved refraction band,
/// subtle inner border, continuous corner radius, full-bleed 1024 for App Store).
/// A change to the brand geometry happens here first, then the SVGs, then the
/// derived PNGs are re-rendered from the same numbers.
///
/// Rules:
/// - The Z+pen is white: bold top bar, long barrel with collar gap and ring, detailed
///   nib (shoulder taper, circular breather hole, centre slit), short bottom bar, and
///   the flowing swash with right loop — the same artwork that ships as `PenMark`
///   (transparent white Z+pen, `zpen_liquid_only_clean_1024`) in the asset catalog.
/// - The tile is **Liquid Glass**: gradient `#6D6AF0 → #4B48C4` (light) / `#7C79F5 → #5A57D6`
///   (dark) with a curved translucent refraction band (white 8–9%), a crisp top-edge
///   specular line (white 35–55%), and a soft inner glass border (white 14–18%),
///   matching `logo-mark.svg` / `logo-mark-dark.svg` and the 1024 `zpen_liquid_1024` master.
/// - The view is vector-tiled with a raster Z+pen supersampled 4× and Lanczos-downsampled
///   from the 1024 liquid master, so it stays crisp from 16 pt to 512 pt.
/// - `showsSealDot` is kept for source compatibility — the Z+pen has no seal dot.
struct ZynSignMark: View {

    /// Side length of the square mark.
    var size: CGFloat = 60

    /// Kept for API compatibility — the pen mark has no seal dot. Ignored.
    var showsSealDot: Bool = true

    /// Force the dark tile variant. When `nil` the variant follows `colorScheme`.
    var forceDarkVariant: Bool? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            tile
            pen
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
            // Curved refraction band — the glass lens highlight across the upper half
            .overlay(
                Ellipse()
                    .fill(Color.white.opacity(useDarkTile ? 0.08 : 0.09))
                    .frame(width: size * 1.6, height: size * 0.85)
                    .offset(y: -size * 0.38)
                    .blur(radius: size * 0.015)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            )
            // Crisp top-edge specular highlight — the thin glass sheen at the very top
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(useDarkTile ? 0.32 : 0.42), Color.white.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: size * 0.085)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .opacity(0.95)
            )
            // Subtle bottom-edge glow
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.clear, Color.white.opacity(0.07)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: size * 0.06)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            )
            // Inner glass border — the thin translucent edge that defines the glass thickness
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(useDarkTile ? 0.18 : 0.16), lineWidth: max(1, size * 0.01))
            )
            // Outer soft border for legibility on both light/dark canvases
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(useDarkTile ? 0.10 : 0.14), lineWidth: max(1, size * 0.012))
                    .blur(radius: 0.2)
            )
    }

    private var cornerRadius: CGFloat {
        // 30 / 128 ≈ 0.2344 — matches logo-mark.svg rx 30 within 128 viewBox
        size * 0.234375
    }

    // MARK: - Pen

    private var pen: some View {
        // The Z+pen artwork is supplied as a transparent PNG (white Z+pen on clear)
        // in the asset catalog at 1×/2×/3×. It is the same artwork that was rendered
        // from the 1024 master (Z top bar + diagonal pen barrel/collar/nib + bottom bar
        // + cursive swash) and used for every derived PNG in `Assets/Brand/`.
        Image("PenMark")
            .resizable()
            .scaledToFit()
            .padding(size * 0.06)
            .accessibilityHidden(true)
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
