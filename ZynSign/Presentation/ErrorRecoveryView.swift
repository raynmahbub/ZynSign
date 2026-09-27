import SwiftUI

/// One failure, in the three answers every failure owes a user.
///
/// A message tells a reader what went wrong. It does not tell them what was
/// established, or what would help. This view shows all three, from
/// `ErrorRecoveryAdvice`, so every failure in ZynSign answers the same
/// questions in the same shape wherever it appears.
///
/// The view never adds facts: it renders advice built from the failure's own
/// typed vocabulary, and it shows nothing at all when there is no advice to
/// give.
struct ErrorRecoveryView: View {

    /// The answers to show.
    let advice: ErrorRecoveryAdvice

    /// Whether to lead with the summary. Off where the surrounding screen has
    /// already stated what happened.
    var showsWhatHappened: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            if showsWhatHappened {
                answerHeading("What happened")
                Text(advice.whatHappened)
            }
            answerHeading("What ZynSign verified")
            Text(advice.whatWasVerified)
            if !advice.nextSteps.isEmpty {
                answerHeading("What you can do next")
                ForEach(advice.nextSteps, id: \.self) { step in
                    Label(step, systemImage: "arrow.right.circle")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !advice.canRetry {
                Text("Trying the same thing again cannot change this outcome.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private func answerHeading(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
    }
}

/// Advice for a failure the caller holds as a category and a message, which
/// is how a queued job records one.
extension ErrorRecoveryView {

    /// Builds the view from a job failure: the category it recorded and the
    /// summary it wrote for the user.
    init(category: DiagnosticCategory, message: String, showsWhatHappened: Bool = true) {
        self.init(
            advice: ErrorRecoveryAdvisor.categoryAdvice(category, message: message),
            showsWhatHappened: showsWhatHappened
        )
    }

    /// Builds the view from any error, typed or not.
    init(error: Error, showsWhatHappened: Bool = true) {
        self.init(
            advice: ErrorRecoveryAdvisor.advice(for: error),
            showsWhatHappened: showsWhatHappened
        )
    }
}
