import SwiftUI

/// The Sideload Studio's palette.
///
/// The studio has a look of its own — deep indigo through violet into cyan,
/// on near-black — and it is defined once, here, so no screen invents a colour
/// of its own. It is deliberately not part of the theme catalogue: the studio
/// is a workshop, and it should read the same whether the rest of the app is
/// wearing Storefront or Graphite. The theme's accent still tints controls
/// inside it, which is how the screen stays part of the app.
enum ZStudioPalette {

    /// The card the studio leads with: midnight through indigo.
    static let hero = LinearGradient(
        colors: [Color(zStudioHex: 0x120B2E), Color(zStudioHex: 0x2B1B63), Color(zStudioHex: 0x3E2F8F)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// The wash behind a lease row that needs attention.
    static let urgentWash = LinearGradient(
        colors: [Color(zStudioHex: 0xFF6A3D).opacity(0.18), Color(zStudioHex: 0x8B5CF6).opacity(0.10)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// The accent the studio's own glyphs use when the theme's is not enough.
    static let accent = Color(zStudioHex: 0x8B5CF6)

    /// The secondary accent: the cyan end of the gradient.
    static let secondaryAccent = Color(zStudioHex: 0x22D3EE)

    /// Text drawn on the hero gradient.
    static let onHero = Color.white

    /// Secondary text drawn on the hero gradient.
    static let onHeroMuted = Color.white.opacity(0.72)

    /// The ring's track on the hero.
    static let heroTrack = Color.white.opacity(0.18)
}

private extension Color {
    /// Builds a colour from a packed `0xRRGGBB` value. The one conversion the
    /// design system is allowed to perform, because the tokens above are the
    /// only values it is ever given.
    init(zStudioHex value: UInt32) {
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}

// MARK: - Hero

/// The studio's headline card: what the journal says, and how long the next
/// build has.
///
/// It is the only surface in the app that draws a gradient of its own rather
/// than the theme's, which is why it names its stops here and nowhere else.
struct ZStudioHeroCard: View {

    /// The small word above the title.
    let eyebrow: String
    /// The big number or phrase: "3 days left".
    let headline: String
    /// One line under the headline.
    let detail: String
    /// Badges, drawn under the detail.
    let badges: [(text: String, tone: SideloadStatusTone)]
    /// The fraction of the next lease still to run, when it is known.
    let fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: ZSpacing.md) {
            HStack(alignment: .top, spacing: ZSpacing.md) {
                VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                    Text(eyebrow.uppercased())
                        .font(.caption2.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(ZStudioPalette.onHeroMuted)
                    Text(headline)
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .foregroundStyle(ZStudioPalette.onHero)
                        .minimumScaleFactor(0.8)
                        .lineLimit(2)
                }
                Spacer(minLength: ZSpacing.xs)
                ZStudioCountdownRing(fraction: fraction)
            }
            Text(detail)
                .font(.footnote)
                .foregroundStyle(ZStudioPalette.onHeroMuted)
                .fixedSize(horizontal: false, vertical: true)
            if !badges.isEmpty {
                HStack(spacing: ZSpacing.xs) {
                    ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                        ZStudioChip(badge.text, tone: badge.tone, onDark: true)
                    }
                }
            }
        }
        .padding(ZSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZStudioPalette.hero, in: RoundedRectangle(cornerRadius: ZRadius.xl, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ZRadius.xl, style: .continuous)
                .stroke(ZStudioPalette.onHero.opacity(0.10), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(eyebrow). \(headline). \(detail)")
    }
}

/// A ring showing how much of the next lease is left, with the days inside it.
struct ZStudioCountdownRing: View {

    /// 0…1 of the lease still to run; `nil` when the lease has no recorded
    /// lifetime, in which case the ring draws empty and says so.
    let fraction: Double?

    @Environment(\.appTheme) private var theme

    var body: some View {
        ZStack {
            Circle()
                .stroke(ZStudioPalette.heroTrack, lineWidth: 7)
            if let fraction {
                Circle()
                    .trim(from: 0, to: min(max(fraction, 0), 1))
                    .stroke(
                        AngularGradient(
                            colors: [theme.accent, ZStudioPalette.accent, ZStudioPalette.secondaryAccent],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            Image(systemName: fraction == nil ? "questionmark" : "hourglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ZStudioPalette.onHero)
        }
        .frame(width: 62, height: 62)
        .accessibilityHidden(true)
    }
}

// MARK: - Chips and badges

/// A compact studio chip. `onDark` adapts it for the hero gradient.
struct ZStudioChip: View {

    let text: String
    let tone: SideloadStatusTone
    let onDark: Bool

    init(_ text: String, tone: SideloadStatusTone, onDark: Bool = false) {
        self.text = text
        self.tone = tone
        self.onDark = onDark
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, ZSpacing.xs)
            .padding(.vertical, ZSpacing.xxs)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
    }

    private var tint: Color {
        switch tone {
        case .success: return ZColors.success
        case .warning: return ZColors.warning
        case .error: return ZColors.error
        case .neutral: return ZColors.neutral
        }
    }

    private var foreground: Color {
        onDark ? ZStudioPalette.onHero : tint
    }

    private var background: Color {
        onDark ? ZStudioPalette.onHero.opacity(0.16) : tint.opacity(0.14)
    }
}

/// The small `ZStatusBadge`-equivalent the studio rows use, taking the domain's
/// own tone instead of a presentation-chosen kind.
struct ZStudioStatusPill: View {

    let tone: SideloadStatusTone
    let text: String

    var body: some View {
        ZStatusBadge(text, kind: kind)
    }

    private var kind: ZStatusBadge.Kind {
        switch tone {
        case .success: return .success
        case .warning: return .warning
        case .error: return .error
        case .neutral: return .neutral
        }
    }
}

// MARK: - Account card

/// One account's card: what it issues, how long it lasts, and what it cannot
/// carry. Drawn in the studio's own look when it is the account in play.
struct ZStudioAccountCard: View {

    let account: SideloadAccount
    let usage: SideloadAccountUsage?
    let isActive: Bool

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            HStack(spacing: ZSpacing.xs) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isActive ? ZStudioPalette.accent : theme.accent)
                Text(account.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isActive {
                    ZStudioChip("In use", tone: .success)
                }
            }
            if let lifetime = account.profileLifetimeDays {
                Text(lifetime == 7 ? "7-day profile" : "\(lifetime)-day profile")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                Text("No profile")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(usage?.summary ?? account.summary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(ZSpacing.sm)
        .frame(width: 196, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ZRadius.card, style: .continuous)
                .fill(isActive ? AnyShapeStyle(ZStudioPalette.urgentWash) : AnyShapeStyle(ZColors.cardBackground))
        )
        .overlay {
            RoundedRectangle(cornerRadius: ZRadius.card, style: .continuous)
                .stroke(isActive ? ZStudioPalette.accent.opacity(0.55) : ZColors.subtleBorder, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch account {
        case .personalTeam: return "person.crop.circle.badge.clock"
        case .developerProgram: return "checkmark.seal.fill"
        case .enterpriseProgram: return "building.2.fill"
        case .adHoc: return "signature"
        }
    }
}

// MARK: - Lease row

/// One signed application and how long it has left.
struct ZStudioLeaseRow: View {

    let lease: SideloadLease
    let status: SideloadLeaseStatus
    let daysRemaining: Int?
    let fraction: Double?
    let now: Date
    let isBusy: Bool
    let action: (() -> Void)?

    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: ZSpacing.sm) {
            ZStudioLeaseRing(fraction: fraction, status: status, tint: theme.accent)
            VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                HStack(spacing: ZSpacing.xs) {
                    Text(lease.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    ZStudioStatusPill(tone: status.tone, text: status.title)
                }
                Text(lease.bundleIdentifier)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: ZSpacing.xxs)
            if let action {
                Button(action: action) {
                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(status == .expired ? "Sign" : "Re-sign")
                            .font(.caption.weight(.semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isBusy)
                .accessibilityLabel("\(status == .expired ? "Sign" : "Re-sign") \(lease.displayName)")
            }
        }
        .padding(.vertical, ZSpacing.xxs)
    }

    private var detail: String {
        guard let expiresAt = lease.expiresAt else {
            return "This run recorded no expiry, so the studio cannot plan a re-sign for it."
        }
        let ending = lease.ending?.title ?? "Expiry"
        let account = lease.account?.shortLabel ?? "Account not recorded"
        let date = SideloadStudioModel.formatted(expiresAt, now: now)
        if let daysRemaining {
            if status == .expired {
                return "\(ending) ended \(date) · \(account)"
            }
            return "\(ending) ends \(date) · \(daysRemaining) day\(daysRemaining == 1 ? "" : "s") left · \(account)"
        }
        return "\(ending) ends \(date) · \(account)"
    }
}

/// The lease's little ring: remaining share, or a dash when no lifetime was
/// recorded.
struct ZStudioLeaseRing: View {

    let fraction: Double?
    let status: SideloadLeaseStatus
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(.tertiarySystemFill), lineWidth: 4)
            if let fraction {
                Circle()
                    .trim(from: 0, to: min(max(fraction, 0), 1))
                    .stroke(status.tone == .error ? ZColors.error : tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(status.tone == .error ? ZColors.error : tint)
        }
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }

    private var symbol: String {
        switch status {
        case .current: return "checkmark"
        case .refreshDue: return "arrow.clockwise"
        case .expired: return "xmark"
        case .unrecorded: return "minus"
        }
    }
}
