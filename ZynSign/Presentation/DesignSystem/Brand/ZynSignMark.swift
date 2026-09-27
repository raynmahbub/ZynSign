import SwiftUI

// MARK: - ZynSign Brand Mark

/// The canonical ZynSign mark — the white Z·Pen on the indigo Liquid Glass tile.
///
/// Every in-app appearance of the logo (launch splash, Home header, Settings,
/// About, onboarding, empty states) renders through this view, so the mark the
/// user sees in the app is the one on the home screen.
///
/// Source of truth: `Assets/Brand/Source/zpen-mark-1024.png` (white Z·Pen on
/// transparent). `Scripts/generate_brand_assets.py` renders the app icon, the
/// `PenMark` image set this view draws, and every brand SVG/PNG from that one
/// file. The numbers below — palette, corner ratio, glyph fill — are the same
/// numbers the script uses; change them in both places or in neither.
///
/// - Tile: `#6D6AF0 → #4B48C4` (light) / `#7C79F5 → #5A57D6` (dark), continuous
///   corners at 22.37 % of the side (the iOS icon curve), a soft lens highlight
///   and a hairline top specular.
/// - Glyph: `PenMark` scaled to fit with 6 % padding — the artwork is authored
///   so the Z·Pen lands at 66 % of the tile height, exactly as in the app icon.
struct ZynSignMark: View {

    /// Side length of the square mark.
    var size: CGFloat = 60

    /// Force the dark tile variant. When `nil` the variant follows `colorScheme`.
    var forceDarkVariant: Bool? = nil

    @Environment(\.colorScheme) private var colorScheme

    /// Corner radius as a fraction of the side — shared with the splash shimmer clip.
    static let cornerRatio: CGFloat = 0.2237

    var body: some View {
        ZStack {
            tile
            Image("PenMark")
                .resizable()
                .scaledToFit()
                .padding(size * 0.06)
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .accessibilityHidden(true)
    }

    // MARK: - Tile

    private var useDarkTile: Bool {
        if let forceDarkVariant { return forceDarkVariant }
        return colorScheme == .dark
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * Self.cornerRatio, style: .continuous)
    }

    private var tileGradient: LinearGradient {
        LinearGradient(
            colors: useDarkTile ? [ZynBrand.indigoDarkTop, ZynBrand.indigoDarkBottom]
                                : [ZynBrand.indigoTop, ZynBrand.indigoBottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var tile: some View {
        shape
            .fill(tileGradient)
            // Lens highlight — the soft glass sheen across the upper half.
            .overlay(
                Ellipse()
                    .fill(Color.white.opacity(0.10))
                    .frame(width: size * 1.7, height: size * 1.3)
                    .offset(y: -size * 0.75)
                    .blur(radius: size * 0.06)
            )
            // Top specular hairline.
            .overlay(
                LinearGradient(colors: [Color.white.opacity(0.30), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: size * 0.05)
                    .frame(maxHeight: .infinity, alignment: .top)
            )
            // Inner glass edge.
            .overlay(
                shape.strokeBorder(Color.white.opacity(useDarkTile ? 0.18 : 0.16), lineWidth: max(1, size * 0.01))
            )
            .clipShape(shape)
    }
}

// MARK: - Brand palette

/// Brand colours shared by the mark, the splash, and the lockups.
/// Mirrors `Scripts/generate_brand_assets.py` and `Assets/README.md`.
enum ZynBrand {
    static let indigoTop = Color(red: 0x6D/255.0, green: 0x6A/255.0, blue: 0xF0/255.0)
    static let indigoBottom = Color(red: 0x4B/255.0, green: 0x48/255.0, blue: 0xC4/255.0)
    static let indigoDarkTop = Color(red: 0x7C/255.0, green: 0x79/255.0, blue: 0xF5/255.0)
    static let indigoDarkBottom = Color(red: 0x5A/255.0, green: 0x57/255.0, blue: 0xD6/255.0)
    static let ink = Color(red: 0x1D/255.0, green: 0x1D/255.0, blue: 0x1F/255.0)
    static let paper = Color(red: 0xF5/255.0, green: 0xF5/255.0, blue: 0xF7/255.0)
    static let surfaceDark = Color(red: 0x15/255.0, green: 0x15/255.0, blue: 0x1D/255.0)
    static let mutedLight = Color(red: 0x6E/255.0, green: 0x6E/255.0, blue: 0x73/255.0)
    static let mutedDark = Color(red: 0xA1/255.0, green: 0xA1/255.0, blue: 0xAA/255.0)
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
        (forceDarkVariant ?? (colorScheme == .dark)) ? ZynBrand.paper : ZynBrand.ink
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
                .fill(isDark ? ZynBrand.surfaceDark : ZynBrand.paper)
            HStack(spacing: 16) {
                ZynSignMark(size: 64, forceDarkVariant: isDark)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ZynSign")
                        .font(.system(size: 28, weight: .bold))
                        .tracking(-0.8)
                        .foregroundStyle(isDark ? ZynBrand.paper : ZynBrand.ink)
                    Text("On-device iOS signing, made Apple-quality.")
                        .font(.footnote)
                        .foregroundStyle(isDark ? ZynBrand.mutedDark : ZynBrand.mutedLight)
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

/// `ZynSignAppMark(size:)` is the older call-site name; it is the same view.
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
