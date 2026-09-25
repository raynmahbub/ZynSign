import Foundation

/// One on-device analytics event.
///
/// ZynSign keeps a small, local activity journal so Settings can show what
/// the app has been doing — counts and recency, on this device only. An
/// event carries a stable category, a stable slug, a timestamp, and an
/// outcome. It carries **nothing else**, by contract:
///
/// - No bundle identifiers, file names, or paths.
/// - No device, user, or installation identifiers of any kind.
/// - No profile, certificate, entitlement, or key material.
/// - No free-form text — `name` comes from a fixed call-site vocabulary.
///
/// Events never leave the device: there is no sender, no endpoint, and no
/// sync anywhere in the product. `AnalyticsPolicy` is the policy that says
/// so; this type is only the record shape.
struct LocalAnalyticsEvent: Codable, Equatable, Identifiable {

    /// The area of the app the event belongs to. Fixed set.
    enum Category: String, Codable, CaseIterable {
        case intake
        case library
        case certificate
        case signing
        case download
        case repository
        case delivery
        case maintenance

        /// One presentation-safe label. Fixed text.
        var displayName: String {
            switch self {
            case .intake: return "Import"
            case .library: return "Library"
            case .certificate: return "Certificates"
            case .signing: return "Signing"
            case .download: return "Downloads"
            case .repository: return "Repositories"
            case .delivery: return "Delivery"
            case .maintenance: return "Maintenance"
            }
        }
    }

    /// The event's identity within the journal.
    let id: UUID

    /// When the event was recorded.
    let date: Date

    /// The area the event belongs to.
    let category: Category

    /// The stable event slug, e.g. `sign.succeeded`. Call sites use fixed
    /// strings; nothing user-typed ever becomes a slug.
    let name: String

    /// Whether the action succeeded. Failure records carry no error detail.
    let succeeded: Bool

    /// Creates an event with a fresh identity and timestamp.
    init(date: Date = Date(), category: Category, name: String, succeeded: Bool) {
        self.id = UUID()
        self.date = date
        self.category = category
        self.name = name
        self.succeeded = succeeded
    }
}

/// Aggregate counts over a journal's contents.
struct LocalAnalyticsJournalCounts: Equatable {
    /// The total number of events held.
    let total: Int

    /// Events per category, for the summary rows.
    let byCategory: [LocalAnalyticsEvent.Category: Int]

    /// Counts of an empty journal.
    static let empty = LocalAnalyticsJournalCounts(total: 0, byCategory: [:])
}

/// The port the presentation layer reads and the environment records
/// through for the local activity journal.
///
/// Implementations keep every byte on-device. Nothing in this protocol can
/// transmit, and no implementation is permitted to add a way to.
protocol LocalAnalyticsRecording: AnyObject {

    /// Records one event. Implementations may prune to their capacity.
    func record(_ event: LocalAnalyticsEvent)

    /// The most recent events, newest first, up to `limit`.
    func recentEvents(limit: Int) -> [LocalAnalyticsEvent]

    /// Aggregate counts over everything currently held.
    func counts() -> LocalAnalyticsJournalCounts

    /// Discards every event. The journal continues recording afterwards
    /// while the journal preference is enabled.
    func clear()
}

/// An in-memory journal.
///
/// Used on non-iOS targets and in tests; it holds the same contract as the
/// file-backed journal with no persistence. A capacity of zero means
/// unbounded, which only tests should choose.
final class InMemoryLocalAnalyticsJournal: LocalAnalyticsRecording {

    private var events: [LocalAnalyticsEvent] = []
    private let capacity: Int
    private let lock = NSLock()

    init(capacity: Int = 500) {
        self.capacity = capacity
    }

    func record(_ event: LocalAnalyticsEvent) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
        if capacity > 0, events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
    }

    func recentEvents(limit: Int) -> [LocalAnalyticsEvent] {
        lock.lock()
        defer { lock.unlock() }
        return Array(events.suffix(max(0, limit)).reversed())
    }

    func counts() -> LocalAnalyticsJournalCounts {
        lock.lock()
        defer { lock.unlock() }
        var byCategory: [LocalAnalyticsEvent.Category: Int] = [:]
        for event in events { byCategory[event.category, default: 0] += 1 }
        return LocalAnalyticsJournalCounts(total: events.count, byCategory: byCategory)
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        events.removeAll()
    }
}
