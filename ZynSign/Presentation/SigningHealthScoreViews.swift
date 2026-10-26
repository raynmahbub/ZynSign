import SwiftUI

/// The v1.0.0 pre-sign compatibility assessment, rendered for the signing
/// screen.
///
/// The card answers one question before the pipeline runs: given the identity,
/// provisioning profile and bundle the user has selected, is a signature
/// likely to be accepted, and why? It reads the same inputs the pipeline will
/// read and reasons about them; it never signs, never edits the package, and
/// never blocks the run. A low score is advice — `SigningView.canSign` does not
/// consult it.
///
/// The score is deliberately separate from `SigningHealthCard`, which reports
/// the always-on local diagnostics scan of the imported package. This card is
/// about the *configuration* the user is about to use.
struct SigningHealthScoreCard: View {

    /// The current assessment, or `nil` while one is being computed.
    let score: SigningHealthScore?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ZCard(variant: .material, cornerRadius: ZRadius.lg) {
            VStack(alignment: .leading, spacing: ZSpacing.sm) {
                Label("Signing Readiness", systemImage: "gauge.with.dots.needle.67percent")
                    .font(.headline)
                if let score {
                    summary(score)
                    findings(score)
                    Text("A prediction from the selected inputs. It does not run the pipeline, change the package, or establish iOS acceptance — you can still sign with a low score.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: ZSpacing.sm) {
                        ProgressView()
                        Text("Assessing the identity, profile and bundle…")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Assessing signing readiness")
                }
            }
        }
        .animation(ZMotion.interactive, value: score?.score)
    }

    @ViewBuilder
    private func summary(_ score: SigningHealthScore) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: ZSpacing.sm) { ring(score); label(score) }
            } else {
                HStack(alignment: .center, spacing: ZSpacing.md) {
                    ring(score)
                    label(score)
                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Signing readiness \(score.score) out of 100, \(score.band.displayName). \(score.band.headline).")
    }

    private func ring(_ score: SigningHealthScore) -> some View {
        ZProgressRing(progress: Double(score.score) / 100,
                      status: "Readiness",
                      tint: score.band.tint)
            .accessibilityHidden(true)
    }

    private func label(_ score: SigningHealthScore) -> some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            Text("\(score.score) / 100")
                .font(.title2.bold()).monospacedDigit()
            ZStatusBadge(score.band.displayName,
                         systemImage: score.band.symbol,
                         kind: score.band.badgeKind)
            Text(score.band.headline)
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func findings(_ score: SigningHealthScore) -> some View {
        let visible = Array(score.findings.prefix(3))
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: ZSpacing.xs) {
                ForEach(visible) { finding in
                    HStack(alignment: .firstTextBaseline, spacing: ZSpacing.xs) {
                        Image(systemName: finding.isRisk ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(finding.isRisk ? Color.orange : Color.green)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(finding.title).font(.subheadline)
                            Text(finding.detail)
                                .font(.footnote).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(finding.isRisk ? "Risk" : "Strength"): \(finding.title). \(finding.detail)")
                }
                if score.findings.count > visible.count {
                    Text("\(score.findings.count - visible.count) more finding\(score.findings.count - visible.count == 1 ? "" : "s")")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private extension SigningHealthScore.Band {

    /// The ring and icon tint for this band.
    var tint: Color {
        switch self {
        case .excellent, .good: return .green
        case .fair: return .orange
        case .poor, .risky: return .red
        }
    }

    /// The badge treatment for this band.
    var badgeKind: ZStatusBadge.Kind {
        switch self {
        case .excellent, .good: return .success
        case .fair: return .warning
        case .poor, .risky: return .error
        }
    }

    /// A symbol that carries the band without relying on colour alone.
    var symbol: String {
        switch self {
        case .excellent: return "checkmark.seal.fill"
        case .good: return "checkmark.circle.fill"
        case .fair: return "exclamationmark.circle"
        case .poor: return "exclamationmark.triangle"
        case .risky: return "xmark.octagon"
        }
    }
}
