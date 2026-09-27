import SwiftUI

// MARK: - Dashboard building blocks
//
// The cards a command-center screen is made of. They take plain values —
// strings, counts, a score — never a Domain type, so the Smart Workspace,
// a future Trust Center and a widget extension can all be assembled from
// the same parts. Every card is one accessibility element with a header
// trait on its title, a ≥ 44 pt hit target on its action, and no motion of
// its own.

/// The frame every dashboard card shares: symbol + title header, optional
/// trailing action, content below. Padding, radius and background come
/// from the tokens, so all cards on a screen line up.
struct ZDashboardCard<Content: View>: View {
    let title: String
    let symbol: String
    var actionTitle: String? = nil
    var action: () -> Void = {}
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(ZTypography.cardTitle)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let actionTitle {
                    Button(actionTitle, action: action)
                        .font(ZTypography.footnote)
                        .zComfortableHitTarget()
                }
            }
            content
        }
        .padding()
        .zynCardBackground(cornerRadius: ZRadius.lg)
    }
}

/// A one-line "open something" row: leading symbol, title, chevron.
struct ZDashboardLinkRow: View {
    let title: String
    let symbol: String
    var detail: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: ZSpacing.sm) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(ZTypography.subheadline)
                    if let detail {
                        Text(detail).font(ZTypography.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .zComfortableHitTarget()
        .accessibilityElement(children: .combine)
    }
}

/// The screen's opening: greeting as the page title, the mark, a one-line
/// inventory. Uses the header material so it reads as chrome, not a card.
struct GreetingCard: View {
    let greeting: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            Text(greeting)
                .font(ZTypography.largeTitle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: ZSpacing.sm) {
                ZynSignMark(size: 40)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(ZTypography.headline)
                    Text(subtitle).font(ZTypography.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .accessibilityElement(children: .combine)
        }
        .padding()
        .zynHeaderBackground()
    }
}

/// A prominent single action — an indigo symbol well, a title, a hint.
/// The card is a label; wrap it in the `Button` or `NavigationLink` that
/// owns the navigation so the hit target is the whole row.
struct QuickActionCard: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack(spacing: ZSpacing.md) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(LinearGradient(colors: [ZynBrand.indigoTop, ZynBrand.indigoBottom], startPoint: .top, endPoint: .bottom))
                .clipShape(RoundedRectangle(cornerRadius: ZRadius.card, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(ZTypography.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A 0–100 score with a verdict and the checks behind it. Each row states
/// its result in a word as well as a colour and a symbol.
struct HealthCard: View {

    enum Outcome: Sendable {
        case passed, warning, failed

        var symbol: String {
            switch self {
            case .passed: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .failed: return "xmark.octagon.fill"
            }
        }

        var color: Color {
            switch self {
            case .passed: return ZColors.success
            case .warning: return ZColors.warning
            case .failed: return ZColors.error
            }
        }

        var word: String {
            switch self {
            case .passed: return "passed"
            case .warning: return "passed with a warning"
            case .failed: return "failed"
            }
        }
    }

    struct Row: Identifiable, Sendable {
        let id: String
        let title: String
        let note: String
        let outcome: Outcome
    }

    let score: Int
    let verdict: String
    let subject: String
    let tint: Color
    let rows: [Row]
    var footnote: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: ZSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: ZSpacing.sm) {
                Text("\(score)")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verdict).font(.subheadline.weight(.semibold))
                    Text(subject).font(ZTypography.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Health \(score) out of 100, \(verdict), for \(subject)")

            ForEach(rows) { row in
                HStack(spacing: ZSpacing.sm) {
                    Image(systemName: row.outcome.symbol)
                        .foregroundStyle(row.outcome.color)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    Text(row.title).font(.footnote.weight(.medium))
                    Spacer(minLength: ZSpacing.sm)
                    Text(row.note).font(ZTypography.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(row.title): \(row.outcome.word). \(row.note)")
            }

            if let footnote {
                Text(footnote).font(ZTypography.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Identity inventory in one line: how many, how many expiring.
struct IdentityCard: View {
    let total: Int
    let expiring: Int
    let action: () -> Void

    var body: some View {
        ZDashboardLinkRow(
            title: total == 0
                ? "No identities yet"
                : expiring == 0 ? "\(total) identities · all current"
                                : "\(expiring) of \(total) identities expiring soon",
            symbol: expiring == 0 ? "checkmark.seal" : "exclamationmark.triangle",
            action: action
        )
    }
}

/// Download queue in one line.
struct DownloadCard: View {
    let active: Int
    let action: () -> Void

    var body: some View {
        ZDashboardLinkRow(
            title: active == 0 ? "Open Downloads" : "\(active) download\(active == 1 ? "" : "s") in progress",
            symbol: active == 0 ? "arrow.down.circle" : "arrow.down.circle.fill",
            action: action
        )
    }
}

/// A short list of rows with hairline dividers between them — the body of
/// a "Recent" card. `row` builds each row; the card owns the separators.
struct RecentListCard<Item, ID: Hashable, Row: View>: View {
    let items: [Item]
    let id: KeyPath<Item, ID>
    var dividerInset: CGFloat = 68
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items, id: id) { item in
                row(item)
                if let last = items.last, item[keyPath: id] != last[keyPath: id] {
                    Divider().padding(.leading, dividerInset)
                }
            }
        }
    }
}
