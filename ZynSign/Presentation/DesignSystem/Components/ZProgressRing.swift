import SwiftUI

/// Circular progress ring for the Smart Sign status machine.
///
/// Usage: `ZProgressRing(progress: 0.6, status: "Signing")`
/// Progress 0…1, indeterminate when nil.
struct ZProgressRing: View {
    let progress: Double?
    let status: String
    let tint: Color

    init(progress: Double? = nil, status: String, tint: Color = .accentColor) {
        self.progress = progress.map { min(max($0, 0), 1) }
        self.status = status
        self.tint = tint
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(.tertiarySystemFill), lineWidth: 6)
                .frame(width: 56, height: 56)
            if let progress {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 56, height: 56)
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: progress)
                Text("\(Int(progress * 100))%")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            } else {
                ProgressView()
                    .tint(tint)
                    .frame(width: 56, height: 56)
            }
        }
        .accessibilityLabel("\(status) \(progress.map { "\(Int($0*100)) percent" } ?? "")")
        .overlay {
            // Status label below ring is added by caller; this view is just the ring.
            EmptyView()
        }
    }
}

/// Horizontal status machine — Idle → Preparing → Analyzing → Signing → Verifying → Completed
struct ZSigningStatusMachine: View {
    enum Step: String, CaseIterable, Identifiable {
        case idle = "Idle"
        case preparing = "Preparing"
        case analyzing = "Analyzing"
        case signing = "Signing"
        case verifying = "Verifying"
        case completed = "Completed"
        var id: String { rawValue }
    }

    let current: Step
    let failed: Bool

    init(current: Step, failed: Bool = false) {
        self.current = current; self.failed = failed
    }

    var body: some View {
        HStack(spacing: ZSpacing.xs) {
            ForEach(Step.allCases.filter { $0 != .idle }) { step in
                let isActive = step == current
                let isPast = index(of: step) < index(of: current) && !failed
                let isFailed = failed && step == current
                VStack(spacing: 4) {
                    Circle()
                        .fill(color(for: step, active: isActive, past: isPast, failed: isFailed))
                        .frame(width: isActive ? 10 : 8, height: isActive ? 10 : 8)
                        .overlay { if isActive { Circle().stroke(color(for: step, active: isActive, past: isPast, failed: isFailed).opacity(0.3), lineWidth: 4).frame(width: 18, height: 18) } }
                    Text(step.rawValue)
                        .font(.caption2.weight(isActive ? .bold : .regular))
                        .foregroundStyle(isActive ? .primary : .secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                if step != .completed {
                    Rectangle()
                        .fill(isPast ? Color.accentColor.opacity(0.5) : Color(.separator))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.vertical, ZSpacing.xs)
    }

    private func index(of step: Step) -> Int { Step.allCases.firstIndex(of: step) ?? 0 }
    private func color(for step: Step, active: Bool, past: Bool, failed: Bool) -> Color {
        if failed && active { return .red }
        if past || active { return .accentColor }
        return Color(.tertiaryLabel)
    }
}

/// Convenience init from pipeline stage string
extension ZSigningStatusMachine.Step {
    static func from(pipelineStage: String?) -> Self {
        guard let s = pipelineStage?.lowercased() else { return .preparing }
        if s.contains("integrity") || s.contains("profile") { return .preparing }
        if s.contains("discovery") { return .analyzing }
        if s.contains("extraction") || s.contains("nested") || s.contains("sealing") || s.contains("executable") { return .signing }
        if s.contains("packaging") || s.contains("verification") { return .verifying }
        return .signing
    }
    static func from(result: SignApplicationResult?) -> Self {
        if result == nil { return .idle }
        if result?.status == .signed { return .completed }
        if let stage = result?.failure?.stage.rawValue { return from(pipelineStage: stage) }
        return .verifying
    }
}
