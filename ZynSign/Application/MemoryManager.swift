import Foundation

/// Something that can give memory back when asked.
///
/// Participants are caches and previews — things that can be rebuilt. A
/// participant never holds user state: the library, the queue, the
/// preferences, and the selection are not participants and are not
/// reachable from here, which is what makes trimming safe to do at any
/// moment.
protocol MemoryTrimmable: AnyObject, Sendable {

    /// A short name for the diagnostics log.
    var trimmableName: String { get }

    /// Releases memory appropriate to `level`. A warning should release
    /// what is cheap to rebuild; critical should release everything that
    /// can be rebuilt.
    func trimMemory(level: MemoryPressureLevel) async
}

/// Reports memory pressure from the platform.
protocol MemoryPressureObserving: Sendable {

    /// Starts delivering levels to `handler` until `stop()`. Delivery may
    /// happen on any thread.
    func start(_ handler: @escaping @Sendable (MemoryPressureLevel) -> Void)

    func stop()
}

/// Answers memory pressure by trimming the caches, and nothing else.
///
/// **What trimming touches.** Thumbnails in memory, cached entry tables,
/// cached inspection results, decoded preview images, and the store's
/// decoded manifests. Each is registered here by the composition root as a
/// `MemoryTrimmable`; each knows how to shrink itself; none holds anything
/// the user made or chose.
///
/// **What trimming preserves.** The library's records and index, the
/// queue, selections, scroll positions, the search text, and the
/// preferences are untouched, so a large IPA inspected a moment ago costs
/// memory only until the next warning and never costs the user their
/// place.
///
/// **How it is driven.** The platform observer reports a level; the
/// manager trims every participant at that level, records the event for
/// the Performance page, and returns to nominal once the platform says so.
/// `trim(level:)` can also be called directly — the Performance page's
/// "Trim Memory Now" does — so the behaviour is testable without pressure.
actor MemoryManager {

    private struct Participant {
        weak var object: (any MemoryTrimmable)?
    }

    private var participants: [ObjectIdentifier: Participant] = [:]
    private let observer: (any MemoryPressureObserving)?
    private let now: @Sendable () -> Date

    /// The most recent level the platform reported.
    private(set) var currentLevel: MemoryPressureLevel = .nominal

    /// How many trims ran this launch, and when the last one ran.
    private(set) var trimCount = 0
    private(set) var lastTrimAt: Date?
    private(set) var lastTrimLevel: MemoryPressureLevel?

    private var isObserving = false

    init(observer: (any MemoryPressureObserving)? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.observer = observer
        self.now = now
    }

    /// Registers `participant`. Held weakly: a participant that goes away
    /// is simply no longer trimmed.
    func register(_ participant: any MemoryTrimmable) {
        participants[ObjectIdentifier(participant)] = Participant(object: participant)
    }

    /// Stops trimming `participant`.
    func unregister(_ participant: any MemoryTrimmable) {
        participants[ObjectIdentifier(participant)] = nil
    }

    /// The names of the registered participants, for the diagnostics table.
    var participantNames: [String] {
        participants.values.compactMap { $0.object?.trimmableName }.sorted()
    }

    /// Starts reacting to the platform's pressure reports.
    func startObserving() {
        guard !isObserving, let observer else { return }
        isObserving = true
        observer.start { [weak self] level in
            guard let self else { return }
            Task { await self.pressureDidChange(to: level) }
        }
    }

    /// Stops reacting to the platform.
    func stopObserving() {
        guard isObserving else { return }
        isObserving = false
        observer?.stop()
    }

    /// Reacts to one platform report: trims at any level above nominal.
    func pressureDidChange(to level: MemoryPressureLevel) async {
        currentLevel = level
        guard level > .nominal else { return }
        await trim(level: level)
    }

    /// Trims every participant at `level`. Returns how many were trimmed.
    @discardableResult
    func trim(level: MemoryPressureLevel) async -> Int {
        var trimmed = 0
        for key in participants.keys {
            guard let object = participants[key]?.object else {
                participants[key] = nil
                continue
            }
            await object.trimMemory(level: level)
            trimmed += 1
        }
        trimCount += 1
        lastTrimAt = now()
        lastTrimLevel = level
        return trimmed
    }
}
