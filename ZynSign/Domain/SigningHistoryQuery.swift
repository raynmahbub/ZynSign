import Foundation

/// How the signing history is narrowed and ordered.
///
/// The query is a value, and applying it is a pure function over the records
/// the journal holds: the history screen never edits the journal to filter it,
/// so what a user sees is always a projection of what is stored. An empty
/// query returns everything, most recent first — the journal's own order.
struct SigningHistoryQuery: Equatable, Sendable {

    /// Which operations are listed by outcome.
    enum OutcomeFilter: String, CaseIterable, Identifiable, Sendable {

        case any
        case succeeded
        case failed
        case cancelled

        var id: Self { self }

        var displayName: String {
            switch self {
            case .any: return "Any Outcome"
            case .succeeded: return "Succeeded"
            case .failed: return "Failed"
            case .cancelled: return "Cancelled"
            }
        }

        /// Whether an operation with `outcome` passes the filter.
        func includes(_ outcome: SigningRecord.Outcome) -> Bool {
            switch self {
            case .any: return true
            case .succeeded: return outcome == .succeeded
            case .failed: return outcome == .failed
            case .cancelled: return outcome == .cancelled
            }
        }
    }

    /// Which operations are listed by what verification concluded.
    enum VerificationFilter: String, CaseIterable, Identifiable, Sendable {

        case any
        case verified
        case needsAttention
        case notVerified

        var id: Self { self }

        var displayName: String {
            switch self {
            case .any: return "Any Verification"
            case .verified: return "Verified"
            case .needsAttention: return "Verification Problems"
            case .notVerified: return "Not Verified"
            }
        }

        /// Whether an operation whose verification concluded `status` (or
        /// never ran, when `status` is `nil`) passes the filter.
        func includes(_ status: ArtifactVerificationStatus?) -> Bool {
            switch self {
            case .any:
                return true
            case .verified:
                return status == .valid
            case .needsAttention:
                return status == .invalid || status == .warning
            case .notVerified:
                return status == nil || status == .unsupported
            }
        }
    }

    /// Which operations are listed by when they ran.
    enum DateFilter: String, CaseIterable, Identifiable, Sendable {

        case any
        case today
        case lastSevenDays
        case lastThirtyDays

        var id: Self { self }

        var displayName: String {
            switch self {
            case .any: return "Any Date"
            case .today: return "Today"
            case .lastSevenDays: return "Last 7 Days"
            case .lastThirtyDays: return "Last 30 Days"
            }
        }

        /// Whether `date` falls in the window, evaluated against `now`.
        func includes(_ date: Date, now: Date, calendar: Calendar) -> Bool {
            switch self {
            case .any:
                return true
            case .today:
                return calendar.isDate(date, inSameDayAs: now)
            case .lastSevenDays:
                guard let boundary = calendar.date(byAdding: .day, value: -7, to: now) else { return true }
                return date >= boundary && date <= now
            case .lastThirtyDays:
                guard let boundary = calendar.date(byAdding: .day, value: -30, to: now) else { return true }
                return date >= boundary && date <= now
            }
        }
    }

    /// How the history is ordered.
    enum SortOrder: String, CaseIterable, Identifiable, Sendable {

        case newest
        case oldest
        case applicationName
        case largestArtifact

        var id: Self { self }

        var displayName: String {
            switch self {
            case .newest: return "Newest"
            case .oldest: return "Oldest"
            case .applicationName: return "App Name"
            case .largestArtifact: return "Largest Artifact"
            }
        }
    }

    /// Text matched against the application's declared name, its bundle
    /// identifier, its declared version, and its build.
    var searchText: String = ""

    /// The outcome filter.
    var outcome: OutcomeFilter = .any

    /// The verification filter.
    var verification: VerificationFilter = .any

    /// The date filter.
    var date: DateFilter = .any

    /// The order records are listed in.
    var sort: SortOrder = .newest

    /// Whether the query narrows or reorders nothing.
    var isDefault: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && outcome == .any
            && verification == .any
            && date == .any
            && sort == .newest
    }

    /// The records the history shows for this query.
    func apply(to records: [SigningRecord], now: Date, calendar: Calendar = .current) -> [SigningRecord] {
        Self.ordered(
            records.filter { matches($0, now: now, calendar: calendar) },
            by: sort
        )
    }

    /// Whether one record passes every filter.
    func matches(_ record: SigningRecord, now: Date, calendar: Calendar = .current) -> Bool {
        guard Self.matches(record, searchText: searchText) else { return false }
        guard outcome.includes(record.outcome) else { return false }
        guard verification.includes(record.verificationStatus) else { return false }
        guard date.includes(record.startedAt, now: now, calendar: calendar) else { return false }
        return true
    }

    /// Whether `record` matches the text: a case-insensitive substring of the
    /// application's declared name, its bundle identifier, its declared
    /// version, or its build. An empty query matches everything.
    static func matches(_ record: SigningRecord, searchText: String) -> Bool {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let haystacks = [
            record.sourceDisplayName ?? "",
            record.sourceBundleIdentifier ?? "",
            record.shortVersion ?? "",
            record.buildVersion ?? "",
        ]
        return haystacks.contains { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    /// Orders records by `order`. Every order is deterministic: ties fall back
    /// to recency and then to the record's own identifier, so two listings of
    /// the same journal always agree.
    static func ordered(_ records: [SigningRecord], by order: SortOrder) -> [SigningRecord] {
        switch order {
        case .newest:
            return records.sorted(by: SigningRecord.sortByRecency)
        case .oldest:
            return records.sorted { lhs, rhs in
                if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
                return lhs.id.rawValue < rhs.id.rawValue
            }
        case .applicationName:
            return records.sorted { lhs, rhs in
                let lhsName = lhs.sourceDisplayName ?? lhs.sourceBundleIdentifier ?? ""
                let rhsName = rhs.sourceDisplayName ?? rhs.sourceBundleIdentifier ?? ""
                if lhsName.caseInsensitiveCompare(rhsName) != .orderedSame {
                    return lhsName.localizedStandardCompare(rhsName) == .orderedAscending
                }
                if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
                return lhs.id.rawValue < rhs.id.rawValue
            }
        case .largestArtifact:
            return records.sorted { lhs, rhs in
                switch (lhs.outputByteCount, rhs.outputByteCount) {
                case (.some(let lhsBytes), .some(let rhsBytes)) where lhsBytes != rhsBytes:
                    return lhsBytes > rhsBytes
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                default:
                    break
                }
                if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
                return lhs.id.rawValue < rhs.id.rawValue
            }
        }
    }
}
