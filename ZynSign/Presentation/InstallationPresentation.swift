import Foundation

/// Fixed-language rendering for the Installation Workspace: dates, states,
/// badges, and the spoken summaries VoiceOver reads.
///
/// Every string here is derived, not invented: a rendering names facts the
/// stores hold, in the interface's own voice, and never upgrades an
/// unknown to a pass or a failure.
enum InstallationPresentation {

    // MARK: - Dates

    /// "Today · 14:22" style. Falls back to the medium date when the
    /// timestamp is older than yesterday.
    static func timestamp(_ date: Date, relativeTo now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("HH:mm")
            return "Today · \(formatter.string(from: date))"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("HH:mm")
            return "Yesterday · \(formatter.string(from: date))"
        }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }

    /// The date-only form, for rows where the time would be noise.
    static func day(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
    }

    // MARK: - Readiness

    /// The badge kind a check state renders as.
    static func badgeKind(for state: InstallationCheckState) -> ZStatusBadge.Kind {
        switch state {
        case .passed: return .success
        case .attention: return .warning
        case .blocked: return .error
        case .notPerformed: return .neutral
        }
    }

    /// The badge kind a whole report renders as.
    static func badgeKind(for report: InstallationReadinessReport) -> ZStatusBadge.Kind {
        if report.blockedChecks.isEmpty && report.attentionChecks.isEmpty && report.notPerformedChecks.isEmpty {
            return .success
        }
        if report.blockedChecks.isEmpty { return .warning }
        return .error
    }

    /// The readiness headline: "Ready", "Ready with notes", "Not ready".
    static func readinessTitle(for report: InstallationReadinessReport) -> String {
        if report.blockedChecks.isEmpty && report.attentionChecks.isEmpty && report.notPerformedChecks.isEmpty {
            return "Ready"
        }
        if report.blockedChecks.isEmpty { return "Ready with notes" }
        return "Not ready"
    }

    /// What the workspace can offer for a report, in fixed language.
    static func readinessExplanation(for report: InstallationReadinessReport) -> String {
        if report.isReady {
            return "ZynSign's checks passed. Delivering is your step — acceptance is the platform's."
        }
        return "ZynSign's checks are not all clear. Resolve the blocked ones before delivering."
    }

    /// The one-sentence row the dashboard's "Ready to Install" line shows.
    static func readinessSummary(for reports: [InstallationReadinessReport]) -> String {
        let ready = reports.filter(\.isReady).count
        return "\(ready) of \(reports.count) ready"
    }

    // MARK: - Update state

    /// The badge kind an update state renders as.
    static func badgeKind(for state: InstallationUpdateState) -> ZStatusBadge.Kind {
        switch state {
        case .upToDate: return .success
        case .updateAvailable: return .info
        case .unknown: return .neutral
        }
    }

    /// The label an installed card shows for its update state.
    static func updateLabel(for state: InstallationUpdateState) -> String {
        switch state {
        case .upToDate: return "Up to date"
        case .updateAvailable(let candidate): return "Update available · \(candidate.versionDisplay)"
        case .unknown: return "No newer signed output"
        }
    }

    /// What the update state means, in fixed language, for the detail
    /// screen.
    static func updateExplanation(for state: InstallationUpdateState) -> String {
        switch state {
        case .upToDate:
            return "The newest signed output ZynSign holds is the one recorded as installed."
        case .updateAvailable:
            return "ZynSign holds a newer signed output than the one recorded as installed. Delivering it is your step."
        case .unknown:
            return "ZynSign has nothing newer to compare against, or the versions cannot be ordered. No claim is made either way."
        }
    }

    // MARK: - Relationship

    /// The badge kind a relationship step renders as.
    static func badgeKind(for state: InstallationRelationship.Node.State) -> ZStatusBadge.Kind {
        switch state {
        case .current: return .success
        case .attention: return .warning
        case .missing: return .neutral
        }
    }

    // MARK: - Channels and events

    /// The badge kind a delivery channel renders as. Channels are facts
    /// about the user's workflow, not outcomes, so nothing here is success.
    static func badgeKind(for channel: InstallationChannel) -> ZStatusBadge.Kind {
        switch channel {
        case .otaLink: return .info
        case .managedDistribution, .hostTool: return .neutral
        case .reportedAfterTheFact: return .neutral
        }
    }

    /// The sentence a history detail shows for what the entry does and does
    /// not claim.
    static let historyHonestyLine = "This entry records your confirmation, made through ZynSign. ZynSign did not observe the delivery and cannot see what the platform decided."

    /// The spoken announcement when an attempt is confirmed.
    static func confirmationAnnouncement(appName: String, kind: InstallationEventKind) -> String {
        "\(appName) recorded as \(kind.displayName.lowercased())."
    }

    /// The spoken summary of the dashboard's headline counts.
    static func dashboardAnnouncement(
        readyToInstall: Int,
        installed: Int,
        updatesAvailable: Int
    ) -> String {
        "Installation workspace. \(readyToInstall) ready to install, "
            + "\(installed) recorded as installed, "
            + "\(updatesAvailable) with updates available."
    }
}
