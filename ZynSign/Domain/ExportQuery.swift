import Foundation

/// How the Export Center's artifact list is narrowed and ordered.
///
/// Like the signing history's query, this is a value and applying it is a pure
/// function over the entries the catalog holds: the list screen never edits
/// the catalog to filter it. Availability is not a filter here — an artifact
/// whose file is missing is still part of the user's history of signed
/// output, and hiding it would hide the fact that it is gone. What availability
/// changes is which actions the row offers.
struct ExportQuery: Equatable, Sendable {

    /// Which artifacts are listed by what verification concluded.
    enum VerificationFilter: String, CaseIterable, Identifiable, Sendable {

        case any
        case valid
        case problems
        case notVerified

        var id: Self { self }

        var displayName: String {
            switch self {
            case .any: return "Any Verification"
            case .valid: return "Verified"
            case .problems: return "Verification Problems"
            case .notVerified: return "Not Verified"
            }
        }

        /// Whether an artifact whose verification concluded `status` passes
        /// the filter.
        func includes(_ status: ArtifactVerificationStatus) -> Bool {
            switch self {
            case .any: return true
            case .valid: return status == .valid
            case .problems: return status == .invalid || status == .warning
            case .notVerified: return status == .unsupported
            }
        }
    }

    /// Which artifacts are listed by whether the file is still held.
    enum AvailabilityFilter: String, CaseIterable, Identifiable, Sendable {

        case any
        case available
        case unavailable

        var id: Self { self }

        var displayName: String {
            switch self {
            case .any: return "Any Availability"
            case .available: return "Available"
            case .unavailable: return "Unavailable"
            }
        }

        /// Whether an entry with `availability` passes the filter.
        func includes(_ availability: ExportAvailability) -> Bool {
            switch self {
            case .any: return true
            case .available: return availability.isAvailable
            case .unavailable: return !availability.isAvailable
            }
        }
    }

    /// Which artifacts are listed by when they were exported.
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

    /// How the artifacts are ordered.
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
    /// identifier, its declared version, its build, and the artifact's file
    /// name — the reference a user copies out of the Export Center.
    var searchText: String = ""

    /// The verification filter.
    var verification: VerificationFilter = .any

    /// The availability filter.
    var availability: AvailabilityFilter = .any

    /// The date filter.
    var date: DateFilter = .any

    /// The order artifacts are listed in.
    var sort: SortOrder = .newest

    /// Whether the query narrows or reorders nothing.
    var isDefault: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && verification == .any
            && availability == .any
            && date == .any
            && sort == .newest
    }

    /// The entries the Export Center shows for this query.
    func apply(to entries: [ExportEntry], now: Date, calendar: Calendar = .current) -> [ExportEntry] {
        Self.ordered(
            entries.filter { matches($0, now: now, calendar: calendar) },
            by: sort
        )
    }

    /// Whether one entry passes every filter.
    func matches(_ entry: ExportEntry, now: Date, calendar: Calendar = .current) -> Bool {
        guard Self.matches(entry, searchText: searchText) else { return false }
        guard verification.includes(entry.record.verificationStatus) else { return false }
        guard availability.includes(entry.availability) else { return false }
        guard date.includes(entry.record.createdAt, now: now, calendar: calendar) else { return false }
        return true
    }

    /// Whether `entry` matches the text: a case-insensitive substring of the
    /// application's declared name, its bundle identifier, its declared
    /// version, its build, or the artifact's file name. An empty query matches
    /// everything.
    static func matches(_ entry: ExportEntry, searchText: String) -> Bool {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let record = entry.record
        let haystacks = [
            record.applicationName ?? "",
            record.bundleIdentifier,
            record.shortVersion ?? "",
            record.buildVersion ?? "",
            record.fileName,
        ]
        return haystacks.contains { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    /// Orders entries by `order`. Every order is deterministic: ties fall back
    /// to recency and then to the record's own identifier, so two listings of
    /// the same catalog always agree.
    static func ordered(_ entries: [ExportEntry], by order: SortOrder) -> [ExportEntry] {
        switch order {
        case .newest:
            return entries.sorted { lhs, rhs in
                if lhs.record.createdAt != rhs.record.createdAt {
                    return lhs.record.createdAt > rhs.record.createdAt
                }
                return lhs.record.id.rawValue < rhs.record.id.rawValue
            }
        case .oldest:
            return entries.sorted { lhs, rhs in
                if lhs.record.createdAt != rhs.record.createdAt {
                    return lhs.record.createdAt < rhs.record.createdAt
                }
                return lhs.record.id.rawValue < rhs.record.id.rawValue
            }
        case .applicationName:
            return entries.sorted { lhs, rhs in
                let lhsName = lhs.record.displayName
                let rhsName = rhs.record.displayName
                if lhsName.caseInsensitiveCompare(rhsName) != .orderedSame {
                    return lhsName.localizedStandardCompare(rhsName) == .orderedAscending
                }
                if lhs.record.createdAt != rhs.record.createdAt {
                    return lhs.record.createdAt > rhs.record.createdAt
                }
                return lhs.record.id.rawValue < rhs.record.id.rawValue
            }
        case .largestArtifact:
            return entries.sorted { lhs, rhs in
                if lhs.record.byteCount != rhs.record.byteCount {
                    return lhs.record.byteCount > rhs.record.byteCount
                }
                if lhs.record.createdAt != rhs.record.createdAt {
                    return lhs.record.createdAt > rhs.record.createdAt
                }
                return lhs.record.id.rawValue < rhs.record.id.rawValue
            }
        }
    }
}
