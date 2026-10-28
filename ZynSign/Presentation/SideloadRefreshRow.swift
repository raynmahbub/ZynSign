import SwiftUI

/// Home's one-line answer to "is anything about to stop working?".
///
/// Sideloaded builds expire, and the person who sideloaded them has no way to
/// know when unless something tells them. This row is that tell: the build that
/// stops launching next, how long it has, and how many are already due — read
/// from the signing journal each time Home appears, and hidden entirely when
/// nothing has been signed, so a fresh library is never nagged.
///
/// It is a glance, not a console: the row opens the Sideload Studio, which owns
/// the queue, the accounts, and the reasoning.
struct SideloadRefreshRow: View {

    @Environment(\.appTheme) private var theme
    @StateObject private var model: SideloadStudioModel

    /// Opens the studio. Home owns its navigation stack, so it decides.
    private let onOpen: () -> Void

    init(environment: ApplicationEnvironment, onOpen: @escaping () -> Void) {
        _model = StateObject(wrappedValue: SideloadStudioModel(environment: environment))
        self.onOpen = onOpen
    }

    var body: some View {
        Group {
            if let glance {
                ZHomeAttentionRow(
                    symbol: glance.symbol,
                    title: glance.title,
                    subtitle: glance.subtitle,
                    count: glance.count,
                    tint: glance.tint
                ) {
                    onOpen()
                }
            }
        }
        .task { await model.load() }
    }

    /// What the row says, or `nil` when there is nothing to say yet.
    ///
    /// A library with nothing signed says nothing: an empty journal is not news,
    /// and a row that appears on first launch claiming "0 to re-sign" would be
    /// noise on the screen that should be teaching import.
    private var glance: (symbol: String, title: String, subtitle: String, count: Int?, tint: Color)? {
        guard let next = model.nextLease else { return nil }
        let due = model.plan.dueCount
        let expired = model.plan.expiredCount(at: model.lastReadAt ?? Date())
        let lead = next.account?.shortLabel ?? "Signed"

        if expired > 0 {
            return (
                "exclamationmark.triangle.fill",
                expired == 1 ? "A build has expired" : "\(expired) builds have expired",
                "\(next.displayName) stopped launching. Re-sign from the studio.",
                due,
                ZColors.error
            )
        }
        if due > 0 {
            return (
                "hourglass.bottomhalf.filled",
                model.headlineCountdown,
                "\(next.displayName) · \(lead) · re-sign before \(SideloadStudioModel.formatted(next.expiresAt, now: model.lastReadAt ?? Date()))",
                due,
                ZColors.warning
            )
        }
        return (
            "hourglass",
            model.headlineCountdown,
            "\(next.displayName) · \(lead) · all builds current",
            nil,
            theme.accent
        )
    }
}
