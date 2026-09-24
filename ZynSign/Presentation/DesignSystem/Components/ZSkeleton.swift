import SwiftUI

/// Shimmer skeleton — replaces bare `ProgressView` spins in lists.
///
/// Usage: `ZSkeleton(rows: 3)` while `isLoading`; otherwise show real content.
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
        .shimmerPhase(phase)
        .onAppear { withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1 } }
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

// Helper to avoid iOS 17 shimmer duplication
private struct ShimmerPhaseModifier: ViewModifier {
    let phase: CGFloat
    func body(content: Content) -> some View { content }
}
private extension View {
    func shimmerPhase(_ phase: CGFloat) -> some View { modifier(ShimmerPhaseModifier(phase: phase)) }
}

/// Card-wrapped skeleton for empty `List` replacements
struct ZSkeletonCard: View {
    var body: some View {
        ZCard { ZSkeleton(rows: 4) }
    }
}
