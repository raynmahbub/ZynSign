import Foundation

/// The words and numbers the signing queue experience uses.
///
/// One place turns job state into sentences, durations, estimates, and
/// stage rows, so the same job reads the same way wherever it is shown — a
/// dashboard card, the detail screen, or an announcement — and so the
/// mapping can be tested without a running queue.
///
/// Everything composed here describes what the queue *observed*: the stage
/// a run reached, the time it took, the evidence it delivered. Estimates
/// are labelled as estimates and only produced where an honest one exists;
/// nothing here invents progress the pipeline did not report, and nothing
/// claims a signed container is trusted, authorized, or installable.
enum SigningQueueRendering {

    // MARK: - Durations

    /// A compact duration: `42s`, `3m 12s`, `1h 02m`. Negative or
    /// non-finite intervals read as zero — a clock is a fact, and a
    /// nonsense fact is presented as the smallest honest one.
    static func durationText(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval > 0 else { return "0s" }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .brief
        let units: NSCalendar.Unit
        if interval >= 3600 {
            units = [.hour, .minute]
        } else if interval >= 60 {
            units = [.minute, .second]
        } else {
            units = [.second]
        }
        formatter.allowedUnits = units
        return formatter.string(from: interval) ?? "0s"
    }

    /// How long a job has been running (active) or took to settle, in the
    /// compact form. A waiting job has no duration yet.
    static func elapsedText(for job: SigningQueue.Job, now: Date) -> String? {
        switch job.state {
        case .running:
            guard let startedAt = job.startedAt else { return nil }
            return durationText(now.timeIntervalSince(startedAt))
        case .completed, .failed, .cancelled:
            guard let startedAt = job.startedAt, let finishedAt = job.finishedAt else { return nil }
            return durationText(finishedAt.timeIntervalSince(startedAt))
        case .queued:
            return nil
        }
    }

    // MARK: - Estimated remaining work

    /// The "estimated remaining work" line for a job card.
    ///
    /// - A waiting job reads as its place in line: what remains is other
    ///   people's work, and the queue says so exactly.
    /// - A running job gets a time estimate only where an honest one
    ///   exists: the weighted stage fraction has moved off zero and the run
    ///   has been going long enough for the extrapolation to mean
    ///   something. Before that, the stage position is the estimate —
    ///   "Stage 2 of 7" is honest where "~3 min" would be a guess dressed
    ///   as arithmetic.
    /// - A settled job reads as what it took or where it stopped.
    static func remainingWorkText(
        for job: SigningQueue.Job,
        waitingPosition: Int?,
        now: Date
    ) -> String? {
        switch job.state {
        case .queued:
            guard let position = waitingPosition else { return "Waiting" }
            switch position {
            case 0: return "Runs next"
            case 1: return "Runs after 1 job"
            default: return "Runs after \(position) jobs"
            }
        case .running:
            let stageNumber = (job.progress?.stage.order ?? 0) + 1
            let stageCount = SigningJobStage.workStageCount
            let fraction = job.fractionCompleted
            if let startedAt = job.startedAt, fraction > 0 {
                let elapsed = now.timeIntervalSince(startedAt)
                if elapsed >= 3, fraction >= 0.03 {
                    let estimatedTotal = elapsed / fraction
                    let remaining = estimatedTotal - elapsed
                    if remaining > 1 {
                        return "~\(durationText(remaining)) left · stage \(stageNumber) of \(stageCount)"
                    }
                }
            }
            return "Stage \(stageNumber) of \(stageCount)"
        case .completed:
            if let text = elapsedText(for: job, now: now) {
                return "Took \(text)"
            }
            return "Completed"
        case .failed(let failure):
            return "Stopped at \(failure.stage.displayName)"
        case .cancelled:
            return "Cancelled"
        }
    }

    // MARK: - Live progress rows

    /// One row of the live stage list: a stage, where the job stands
    /// relative to it, and the fraction to draw when one is known.
    struct StageRow: Equatable {

        /// Where a row stands relative to the job.
        enum Status: Equatable {
            /// The stage finished.
            case complete
            /// The stage is running now.
            case current
            /// The stage stopped the run.
            case stopped
            /// The stage has not been reached.
            case pending
        }

        let stage: SigningJobStage
        let status: Status

        /// The within-stage fraction to draw, when the stage reported
        /// countable work. `nil` means indeterminate — the honest state for
        /// the stages the pipeline reports by boundary alone.
        let stageFraction: Double?

        /// The overall fraction the whole run had reached when this stage
        /// completed — the value the card's progress bar shows.
        var isDeterminate: Bool { stageFraction != nil }
    }

    /// The stage rows for one job: every work stage, each marked complete,
    /// current, stopped, or pending from the stage the job actually
    /// reached. A settled failure stops the list at its stage; a completed
    /// job shows every stage done; a waiting job shows everything pending.
    static func stageRows(for job: SigningQueue.Job) -> [StageRow] {
        let workStages = SigningJobStage.ordered.filter { $0 != .completed }
        let reached: SigningJobStage?
        switch job.state {
        case .queued:
            reached = nil
        case .running:
            reached = job.progress?.stage
        case .completed:
            reached = .completed
        case .failed(let failure):
            reached = failure.stage
        case .cancelled:
            reached = job.progress?.stage
        }
        // A failure or a cancellation stops the list at the stage reached;
        // the view styles the row from the job's own state.
        let stoppedHere = job.state.failure != nil || job.state == .cancelled
        return workStages.map { stage in
            guard let reached else {
                return StageRow(stage: stage, status: .pending, stageFraction: nil)
            }
            if reached == .completed || stage.order < reached.order {
                return StageRow(stage: stage, status: .complete, stageFraction: 1)
            }
            if stage == reached {
                if stoppedHere {
                    return StageRow(stage: stage, status: .stopped, stageFraction: job.progress?.stageFraction)
                }
                if job.state.completion != nil {
                    return StageRow(stage: stage, status: .complete, stageFraction: 1)
                }
                return StageRow(
                    stage: stage,
                    status: .current,
                    stageFraction: job.progress?.isDeterminate == true ? job.progress?.stageFraction : nil
                )
            }
            return StageRow(stage: stage, status: .pending, stageFraction: nil)
        }
    }

    // MARK: - Accessibility

    /// The sentence a job card is read as: name, state, stage, priority,
    /// progress, and remaining work — everything the card shows visually,
    /// in the order a person would summarize it aloud.
    static func accessibilityDescription(
        for job: SigningQueue.Job,
        waitingPosition: Int?,
        now: Date
    ) -> String {
        var parts: [String] = [job.applicationName]
        switch job.state {
        case .queued:
            parts.append("waiting")
            parts.append("\(job.priority.displayName) priority")
        case .running:
            if job.cancellationRequested {
                parts.append("cancelling")
            } else {
                parts.append(job.progress?.stage.displayName ?? "starting")
                parts.append("\(Int((job.fractionCompleted * 100).rounded())) percent")
            }
        case .completed:
            parts.append("completed")
        case .failed(let failure):
            parts.append("failed at \(failure.stage.displayName)")
        case .cancelled:
            parts.append("cancelled")
        }
        if let remaining = remainingWorkText(for: job, waitingPosition: waitingPosition, now: now) {
            parts.append(remaining)
        }
        if job.attemptCount > 1 {
            parts.append("attempt \(job.attemptCount)")
        }
        return parts.joined(separator: ", ")
    }

    /// The announcement spoken when a notice arrives, phrased the way a
    /// person would say it aloud.
    static func announcement(for notice: SigningQueueNotice) -> String {
        "\(notice.title). \(notice.message)"
    }
}
