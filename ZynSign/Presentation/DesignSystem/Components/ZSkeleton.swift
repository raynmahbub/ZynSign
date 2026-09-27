import SwiftUI

/// Shimmer skeleton — replaces bare `ProgressView` spins in lists, cards, and grids.
///
/// Usage: `ZSkeleton(rows: 3)` or specialized skeletons like `ZSkeletonAppRow()`,
/// `ZSkeletonCertificateRow()`, etc. while `isLoading`.
struct ZSkeleton: View {
    let rows: Int
    @State private var phase: CGFloat = 0

    init(rows: Int = 3) { self.rows = rows }

    var body: some View {
        VStack(spacing: ZSpacing.sm) {
            ForEach(0..<rows, id: \.self) { _ in
                RoundedRectangle(cornerRadius: ZRadius.sm)
                    .fill(Color(.tertiarySystemFill))
                    .frame(height: 64)
                    .overlay { shimmer }
                    .clipShape(RoundedRectangle(cornerRadius: ZRadius.sm))
            }
        }
        .redacted(reason: .placeholder)
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }

    private var shimmer: some View {
        LinearGradient(
            colors: [.clear, .white.opacity(0.4), .clear],
            startPoint: .leading, endPoint: .trailing
        )
        .offset(x: phase * 200 - 100)
        .blendMode(.overlay)
    }
}

/// Shimmering skeleton matching an application library row (app icon, title, subtitle, badge).
struct ZSkeletonAppRow: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        HStack(spacing: ZSpacing.md) {
            RoundedRectangle(cornerRadius: ZRadius.icon, style: .continuous)
                .fill(Color(.tertiarySystemFill))
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: ZRadius.xs)
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 140, height: 16)

                RoundedRectangle(cornerRadius: ZRadius.xs)
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 100, height: 12)
            }

            Spacer()

            Capsule()
                .fill(Color(.tertiarySystemFill))
                .frame(width: 60, height: 22)
        }
        .padding(.vertical, 4)
        .overlay { shimmer }
        .redacted(reason: .placeholder)
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }

    private var shimmer: some View {
        LinearGradient(
            colors: [.clear, .white.opacity(0.3), .clear],
            startPoint: .leading, endPoint: .trailing
        )
        .offset(x: phase * 300 - 150)
        .blendMode(.overlay)
    }
}

/// Shimmering skeleton matching a certificate item row.
struct ZSkeletonCertificateRow: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        HStack(spacing: ZSpacing.md) {
            Circle()
                .fill(Color(.tertiarySystemFill))
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: ZRadius.xs)
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 160, height: 16)

                RoundedRectangle(cornerRadius: ZRadius.xs)
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 110, height: 12)
            }

            Spacer()

            Capsule()
                .fill(Color(.tertiarySystemFill))
                .frame(width: 50, height: 20)
        }
        .padding(.vertical, 4)
        .overlay { shimmer }
        .redacted(reason: .placeholder)
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }

    private var shimmer: some View {
        LinearGradient(
            colors: [.clear, .white.opacity(0.3), .clear],
            startPoint: .leading, endPoint: .trailing
        )
        .offset(x: phase * 300 - 150)
        .blendMode(.overlay)
    }
}

/// Shimmering skeleton matching a provisioning profile row.
struct ZSkeletonProfileRow: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        HStack(spacing: ZSpacing.md) {
            RoundedRectangle(cornerRadius: ZRadius.sm, style: .continuous)
                .fill(Color(.tertiarySystemFill))
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: ZRadius.xs)
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 150, height: 16)

                RoundedRectangle(cornerRadius: ZRadius.xs)
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 90, height: 12)
            }

            Spacer()

            Capsule()
                .fill(Color(.tertiarySystemFill))
                .frame(width: 65, height: 20)
        }
        .padding(.vertical, 4)
        .overlay { shimmer }
        .redacted(reason: .placeholder)
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }

    private var shimmer: some View {
        LinearGradient(
            colors: [.clear, .white.opacity(0.3), .clear],
            startPoint: .leading, endPoint: .trailing
        )
        .offset(x: phase * 300 - 150)
        .blendMode(.overlay)
    }
}

/// Shimmering grid of application cards.
struct ZSkeletonAppGrid: View {
    let count: Int

    init(count: Int = 6) { self.count = count }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: ZSpacing.sm)], spacing: ZSpacing.sm) {
            ForEach(0..<count, id: \.self) { _ in
                VStack(spacing: ZSpacing.xs) {
                    RoundedRectangle(cornerRadius: ZRadius.icon, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                        .frame(width: 64, height: 64)

                    RoundedRectangle(cornerRadius: ZRadius.xs)
                        .fill(Color(.tertiarySystemFill))
                        .frame(width: 70, height: 12)

                    RoundedRectangle(cornerRadius: ZRadius.xs)
                        .fill(Color(.tertiarySystemFill))
                        .frame(width: 45, height: 10)
                }
                .padding(ZSpacing.sm)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: ZRadius.card))
            }
        }
        .redacted(reason: .placeholder)
    }
}

/// Card-wrapped skeleton for empty `List` replacements.
struct ZSkeletonCard: View {
    var body: some View {
        ZCard { ZSkeleton(rows: 4) }
    }
}
