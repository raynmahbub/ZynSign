import Foundation

/// A bounded, thread-safe, least-recently-used cache for values derived
/// from an artifact's bytes.
///
/// Every inspection in ZynSign starts by reading an archive's entry table,
/// and many go on to derive the same things from it — the bundle root,
/// the Info.plist, the component list. The bytes behind an artifact
/// identifier never change (an import mints a fresh identifier), so a
/// value derived from them is valid for as long as the file is unchanged;
/// the cache therefore keys every value by the identifier *and* a stamp of
/// the file (size and modification date) so a replaced or damaged file is
/// a miss, never a stale hit.
///
/// The cache is a class with a lock rather than an actor so synchronous
/// archive code — which runs off the main actor already — can consult it
/// without suspending, and so it can hold values that are not `Sendable`
/// without the caller crossing an isolation boundary to reach them.
final class InspectionResultCache<Value>: @unchecked Sendable {

    /// The identity of one cached value.
    struct Key: Hashable, Sendable {
        let artifactID: ArtifactIdentifier
        let stamp: String
        let aspect: String
    }

    private struct Entry {
        let value: Value
        let cost: Int
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    private var totalCost = 0

    /// The most entries held.
    let itemBudget: Int

    /// The most summed cost held. Cost is caller-defined — entry counts,
    /// byte counts — and only has to be consistent within one cache.
    let costBudget: Int

    private(set) var hitCount = 0
    private(set) var missCount = 0

    init(itemBudget: Int = 64, costBudget: Int = 250_000) {
        self.itemBudget = max(1, itemBudget)
        self.costBudget = max(1, costBudget)
    }

    /// How many values are held.
    var count: Int {
        lock.withLock { entries.count }
    }

    /// The value for `key`, marking it recently used.
    func value(for key: Key) -> Value? {
        lock.withLock {
            guard let entry = entries[key] else {
                missCount += 1
                return nil
            }
            hitCount += 1
            touch(key)
            return entry.value
        }
    }

    /// Stores `value` under `key` at `cost`, evicting least recently used
    /// values as needed. A value costlier than the whole budget is not
    /// stored.
    func insert(_ value: Value, for key: Key, cost: Int) {
        let cost = max(0, cost)
        guard cost <= costBudget else { return }
        lock.withLock {
            if let existing = entries[key] {
                totalCost -= existing.cost
            } else {
                order.append(key)
            }
            entries[key] = Entry(value: value, cost: cost)
            totalCost += cost
            touch(key)
            while (entries.count > itemBudget || totalCost > costBudget), let oldest = order.first {
                removeLocked(oldest)
            }
        }
    }

    /// The value for `key`, computing and storing it on a miss.
    func value(for key: Key, cost: (Value) -> Int, compute: () throws -> Value) rethrows -> Value {
        if let cached = value(for: key) {
            return cached
        }
        let computed = try compute()
        insert(computed, for: key, cost: cost(computed))
        return computed
    }

    /// Forgets every value for `artifactID`.
    func forget(artifactID: ArtifactIdentifier) {
        lock.withLock {
            for key in order where key.artifactID == artifactID {
                removeLocked(key)
            }
        }
    }

    /// Forgets everything.
    func removeAll() {
        lock.withLock {
            entries.removeAll()
            order.removeAll()
            totalCost = 0
        }
    }

    /// Shrinks to `fraction` of the cost budget, least recently used first.
    func trim(toFraction fraction: Double) {
        let target = Int(Double(costBudget) * min(1, max(0, fraction)))
        lock.withLock {
            while totalCost > target, let oldest = order.first {
                removeLocked(oldest)
            }
        }
    }

    private func touch(_ key: Key) {
        if let index = order.firstIndex(of: key), index != order.count - 1 {
            order.remove(at: index)
            order.append(key)
        }
    }

    private func removeLocked(_ key: Key) {
        if let existing = entries.removeValue(forKey: key) {
            totalCost -= existing.cost
        }
        order.removeAll { $0 == key }
    }
}

/// Produces the stamp that identifies the current bytes behind an
/// artifact, so cached derivations are tied to exactly those bytes.
protocol ArtifactStampProviding: Sendable {

    /// A short string that changes whenever the artifact's file changes,
    /// or `nil` when the artifact cannot be found — in which case nothing
    /// is cached for it.
    func stamp(for artifact: ArtifactIdentifier) -> String?
}

/// An `ArtifactArchiveReaderProvider` that serves entry tables from a
/// shared cache, so the many read-only inspectors that start by scanning
/// the same archive scan it once.
///
/// Only the entry table is cached; content reads still go to the archive,
/// within the same bounds as before. The wrapped reader is otherwise
/// untouched: it still refuses unsafe names, still enforces its limits,
/// and is still closed by its caller. A miss reads the table through the
/// underlying reader and stores it under the artifact's current stamp.
struct CachingArtifactArchiveReaderProvider: ArtifactArchiveReaderProvider {

    /// The provider that actually opens archives.
    let underlying: any ArtifactArchiveReaderProvider

    /// The shared entry-table cache. One per composition, so every
    /// inspector benefits from every other's scans.
    let entryTables: InspectionResultCache<[ArchiveEntry]>

    /// Stamps the file behind each artifact.
    let stamps: any ArtifactStampProviding

    init(
        underlying: any ArtifactArchiveReaderProvider,
        entryTables: InspectionResultCache<[ArchiveEntry]>,
        stamps: any ArtifactStampProviding
    ) {
        self.underlying = underlying
        self.entryTables = entryTables
        self.stamps = stamps
    }

    func archiveReader(for artifact: ArtifactIdentifier) throws -> any ArchiveReader {
        let reader = try underlying.archiveReader(for: artifact)
        guard let stamp = stamps.stamp(for: artifact) else {
            return reader
        }
        return EntryTableCachingReader(
            wrapped: reader,
            cache: entryTables,
            key: InspectionResultCache<[ArchiveEntry]>.Key(artifactID: artifact, stamp: stamp, aspect: "entry-table")
        )
    }
}

/// A reader that answers `readEntryTable()` from the shared cache and
/// forwards everything else.
private final class EntryTableCachingReader: ArchiveReader {

    private let wrapped: any ArchiveReader
    private let cache: InspectionResultCache<[ArchiveEntry]>
    private let key: InspectionResultCache<[ArchiveEntry]>.Key

    init(wrapped: any ArchiveReader, cache: InspectionResultCache<[ArchiveEntry]>, key: InspectionResultCache<[ArchiveEntry]>.Key) {
        self.wrapped = wrapped
        self.cache = cache
        self.key = key
    }

    func readEntryTable() throws -> [ArchiveEntry] {
        try cache.value(for: key, cost: { $0.count }) {
            try wrapped.readEntryTable()
        }
    }

    func containsEntry(at path: ArchivePath) throws -> Bool {
        try wrapped.containsEntry(at: path)
    }

    func entryKind(at path: ArchivePath) throws -> ArchiveEntryKind? {
        try wrapped.entryKind(at: path)
    }

    func readEntryData(at path: ArchivePath, maximumBytes: Int) throws -> Data {
        try wrapped.readEntryData(at: path, maximumBytes: maximumBytes)
    }

    func readEntryPrefix(at path: ArchivePath, maximumBytes: Int) throws -> Data {
        try wrapped.readEntryPrefix(at: path, maximumBytes: maximumBytes)
    }

    func close() {
        wrapped.close()
    }
}
