import Foundation

/// Which slice of the Installed Apps Library a list shows.
enum InstallationWorkspaceScope: String, CaseIterable, Hashable, Sendable {

    /// Every record the library holds.
    case all

    /// Records whose newest export is newer than the recorded install.
    case updatesAvailable

    /// Records whose latest event is within the recent window.
    case recent

    /// Records whose latest delivery was not re-verified recently, or whose
    /// linked artifact is no longer held — the records that deserve a look.
    case needsAttention

    /// The scope's name.
    var displayName: String {
        switch self {
        case .all: return "All Installed"
        case .updatesAvailable: return "Updates Available"
        case .recent: return "Recently Installed"
        case .needsAttention: return "Needs Attention"
        }
    }

    /// The recent window: one week.
    static let recentWindow: TimeInterval = 7 * 24 * 60 * 60

    /// Whether `record` belongs in the scope, given the update state and
    /// artifact facts the model already derived.
    func contains(
        _ record: InstalledApplicationRecord,
        updateState: InstallationUpdateState,
        artifactHeld: Bool,
        now: Date
    ) -> Bool {
        switch self {
        case .all:
            return true
        case .updatesAvailable:
            return updateState.offersUpdate
        case .recent:
            guard let installedAt = record.lastInstalledAt else { return false }
            return now.timeIntervalSince(installedAt) <= Self.recentWindow
        case .needsAttention:
            if !artifactHeld { return true }
            if case .updateAvailable(let candidate) = updateState,
               candidate.verificationStatus?.isPassing == false {
                return true
            }
            return false
        }
    }
}

/// How the Installed Apps Library is ordered.
enum InstallationWorkspaceOrder: String, CaseIterable, Hashable, Sendable {

    /// Most recently installed first. The default.
    case recentlyInstalled

    /// Alphabetical by the record's display name.
    case name

    /// Updates first, then most recently installed.
    case updateStatus

    /// The order's name.
    var displayName: String {
        switch self {
        case .recentlyInstalled: return "Recently Installed"
        case .name: return "Name"
        case .updateStatus: return "Update Status"
        }
    }

    /// Sorts `records` with the derived facts.
    func sorted(
        _ records: [InstalledApplicationRecord],
        updateStates: [InstalledApplicationIdentifier: InstallationUpdateState],
        now: Date
    ) -> [InstalledApplicationRecord] {
        switch self {
        case .recentlyInstalled:
            return records.sorted {
                switch ($0.lastInstalledAt, $1.lastInstalledAt) {
                case (.some(let lhs), .some(let rhs)): return lhs > rhs
                case (.some, .none): return true
                case (.none, .some): return false
                case (.none, .none): return $0.recordedAt > $1.recordedAt
                }
            }
        case .name:
            return records.sorted {
                $0.displayOrIdentifier.localizedCaseInsensitiveCompare($1.displayOrIdentifier) == .orderedAscending
            }
        case .updateStatus:
            return records.sorted { lhs, rhs in
                let lhsOffers = updateStates[lhs.id]?.offersUpdate ?? false
                let rhsOffers = updateStates[rhs.id]?.offersUpdate ?? false
                if lhsOffers != rhsOffers { return lhsOffers }
                switch (lhs.lastInstalledAt, rhs.lastInstalledAt) {
                case (.some(let lhsDate), .some(let rhsDate)): return lhsDate > rhsDate
                case (.some, .none): return true
                case (.none, .some): return false
                case (.none, .none): return lhs.recordedAt > rhs.recordedAt
                }
            }
        }
    }
}

/// A search-and-scope query over the Installed Apps Library.
///
/// The query is a pure projection: it filters and orders what the model
/// already holds in memory, never re-reading storage, so filtering stays
/// instant at hundreds of records.
struct InstallationWorkspaceQuery: Equatable, Hashable, Sendable {

    /// The scope in force.
    var scope: InstallationWorkspaceScope = .all

    /// The order in force.
    var order: InstallationWorkspaceOrder = .recentlyInstalled

    /// The search text. Matches the record's name and bundle identifier.
    var searchText: String = ""

    /// The flattened fact set one record's filtering reads.
    struct Facts: Equatable, Hashable, Sendable {
        let updateState: InstallationUpdateState
        let artifactHeld: Bool
    }

    /// Applies the query, most recently installed first unless the order
    /// says otherwise.
    func apply(
        to records: [InstalledApplicationRecord],
        facts: [InstalledApplicationIdentifier: Facts],
        now: Date
    ) -> [InstalledApplicationRecord] {
        var filtered = records
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty {
            filtered = filtered.filter { record in
                record.displayOrIdentifier.localizedCaseInsensitiveContains(trimmedSearch)
                    || record.bundleIdentifier.localizedCaseInsensitiveContains(trimmedSearch)
            }
        }
        if scope != .all {
            filtered = filtered.filter { record in
                let recordFacts = facts[record.id]
                return scope.contains(
                    record,
                    updateState: recordFacts?.updateState ?? .unknown,
                    artifactHeld: recordFacts?.artifactHeld ?? true,
                    now: now
                )
            }
        }
        let states = Dictionary(uniqueKeysWithValues: facts.map {
            ($0.key, $0.value.updateState)
        })
        return order.sorted(filtered, updateStates: states, now: now)
    }
}
