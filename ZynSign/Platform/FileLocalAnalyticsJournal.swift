import Foundation

/// The file-backed local activity journal.
///
/// Events are appended as JSON Lines to one file inside the application
/// container — a location the system does not purge and no other app can
/// read. The whole journal is bounded by `capacity`: when the bound is
/// exceeded the oldest events fall off the front, and nothing is archived,
/// rotated, or copied anywhere.
///
/// Failure behaviour is deliberate: a line that cannot be decoded is
/// skipped rather than fatal, so one damaged line costs one event and the
/// journal keeps working. Every write is atomic — a crash mid-append
/// leaves either the old file or the new file, never a partial mixture.
///
/// The journal never transmits anything: it has no sender, no session, and
/// no URL, and it cannot gain one without a policy change in
/// `AnalyticsPolicy` and an ADR.
final class FileLocalAnalyticsJournal: LocalAnalyticsRecording {

    /// Where the journal file lives.
    private let location: URL

    /// The maximum number of events held.
    private let capacity: Int

    /// Guards read-modify-write cycles.
    private let lock = NSLock()

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private lazy var decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Creates a journal at `location` with the given capacity. The file
    /// and its directory are created on first record, not at init, so
    /// constructing a journal never touches the disk.
    init(location: URL, capacity: Int = AnalyticsPolicy.journalCapacity) {
        self.location = location
        self.capacity = max(1, capacity)
    }

    /// The conventional journal location: `Application
    /// Support/ZynSignAnalytics/events.jsonl` inside the app container.
    static func defaultLocation() -> URL {
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("ZynSignAnalytics", isDirectory: true)
            .appendingPathComponent("events.jsonl", isDirectory: false)
    }

    func record(_ event: LocalAnalyticsEvent) {
        lock.lock()
        defer { lock.unlock() }
        var events = readEvents()
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
        writeEvents(events)
    }

    func recentEvents(limit: Int) -> [LocalAnalyticsEvent] {
        lock.lock()
        defer { lock.unlock() }
        return Array(readEvents().suffix(max(0, limit)).reversed())
    }

    func counts() -> LocalAnalyticsJournalCounts {
        lock.lock()
        defer { lock.unlock() }
        let events = readEvents()
        var byCategory: [LocalAnalyticsEvent.Category: Int] = [:]
        for event in events { byCategory[event.category, default: 0] += 1 }
        return LocalAnalyticsJournalCounts(total: events.count, byCategory: byCategory)
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: location)
    }

    // MARK: - File mechanics

    /// Reads every decodable event, oldest first. A missing file is an
    /// empty journal; a damaged line is one lost event, never a failure.
    private func readEvents() -> [LocalAnalyticsEvent] {
        guard let data = try? Data(contentsOf: location), !data.isEmpty else { return [] }
        var events: [LocalAnalyticsEvent] = []
        for lineData in data.split(separator: 0x0A) {
            if let event = try? decoder.decode(LocalAnalyticsEvent.self, from: lineData) {
                events.append(event)
            }
        }
        return events
    }

    /// Writes the whole journal atomically, creating the directory on
    /// first use.
    private func writeEvents(_ events: [LocalAnalyticsEvent]) {
        let directory = location.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var data = Data()
            data.reserveCapacity(events.count * 128)
            for event in events {
                data.append(try encoder.encode(event))
                data.append(0x0A)
            }
            try data.write(to: location, options: .atomic)
        } catch {
            // A failed write leaves the previous file intact — the journal
            // loses one event rather than failing an operation the user
            // is waiting on. Nothing here is worth raising into the UI.
        }
    }
}
