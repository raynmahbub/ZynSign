import Foundation

/// One kind of derived data ZynSign keeps to avoid recomputing it.
///
/// Every category is *derived*: it can be rebuilt from the library's own
/// packages and records, so removing it costs time and never information.
/// Imported applications are not a cache category and cannot be named
/// here — the cache machinery has no case for them and therefore no code
/// path that reaches them.
enum CacheCategory: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {

    /// Downsampled application icons, in the sizes the interface draws.
    case thumbnails

    /// Downsampled screenshot and asset previews.
    case screenshots

    /// Derived package metadata: provenance, the metadata index, cached
    /// inspection summaries.
    case metadata

    /// Diagnostic and benchmark records the Performance page reads.
    case diagnostics

    /// Scratch files left by finished or interrupted operations.
    case temporaryFiles

    var id: Self { self }

    /// The user-presentable name.
    var displayName: String {
        switch self {
        case .thumbnails: return "Thumbnails"
        case .screenshots: return "Screenshots"
        case .metadata: return "Metadata"
        case .diagnostics: return "Diagnostics"
        case .temporaryFiles: return "Temporary Files"
        }
    }

    /// What the category holds and what clearing it costs.
    var explanation: String {
        switch self {
        case .thumbnails:
            return "Icons resized for cards and rows. Cleared icons are regenerated the next time they are shown."
        case .screenshots:
            return "Resized screenshots and asset previews. Regenerated when a preview is opened again."
        case .metadata:
            return "Developer, team, and inspection summaries read from packages. Rebuilt in the background after clearing."
        case .diagnostics:
            return "Benchmark and optimization records shown on this page."
        case .temporaryFiles:
            return "Working copies and leftovers from finished operations. Only entries no running operation owns are removed."
        }
    }

    /// The SF Symbol shown beside the category.
    var symbolName: String {
        switch self {
        case .thumbnails: return "photo.on.rectangle"
        case .screenshots: return "rectangle.stack"
        case .metadata: return "doc.text.magnifyingglass"
        case .diagnostics: return "waveform.path.ecg"
        case .temporaryFiles: return "trash"
        }
    }
}

/// The budget one cache category is kept within.
///
/// A policy is applied automatically after work that grows a cache and on
/// demand from the Performance page. It never removes anything outside its
/// category and never removes an item younger than `minimumAge`, so a file
/// an operation wrote a moment ago is not swept out from under it.
struct CachePolicy: Equatable, Hashable, Sendable {

    /// The category the policy governs.
    let category: CacheCategory

    /// The most bytes the category may hold before the least recently used
    /// items are evicted. `nil` means unbounded.
    let byteBudget: Int?

    /// The most items the category may hold. `nil` means unbounded.
    let itemBudget: Int?

    /// Items untouched for longer than this are evicted regardless of the
    /// budgets. `nil` means never by age.
    let maximumAge: TimeInterval?

    /// Items younger than this are never evicted by a policy sweep.
    let minimumAge: TimeInterval

    init(
        category: CacheCategory,
        byteBudget: Int? = nil,
        itemBudget: Int? = nil,
        maximumAge: TimeInterval? = nil,
        minimumAge: TimeInterval = 60
    ) {
        self.category = category
        self.byteBudget = byteBudget.map { max(0, $0) }
        self.itemBudget = itemBudget.map { max(0, $0) }
        self.maximumAge = maximumAge.map { max(0, $0) }
        self.minimumAge = max(0, minimumAge)
    }

    /// The shipped policy for each category.
    static func standard(for category: CacheCategory) -> CachePolicy {
        switch category {
        case .thumbnails:
            return CachePolicy(category: category, byteBudget: 96 * 1_024 * 1_024, itemBudget: 6_000, maximumAge: 90 * 86_400)
        case .screenshots:
            return CachePolicy(category: category, byteBudget: 128 * 1_024 * 1_024, itemBudget: 2_000, maximumAge: 30 * 86_400)
        case .metadata:
            return CachePolicy(category: category, byteBudget: 32 * 1_024 * 1_024, itemBudget: nil, maximumAge: nil)
        case .diagnostics:
            return CachePolicy(category: category, byteBudget: 8 * 1_024 * 1_024, itemBudget: 500, maximumAge: 180 * 86_400)
        case .temporaryFiles:
            return CachePolicy(category: category, byteBudget: nil, itemBudget: nil, maximumAge: 3_600, minimumAge: 3_600)
        }
    }

    /// The shipped policies, one per category.
    static var standard: [CachePolicy] {
        CacheCategory.allCases.map { standard(for: $0) }
    }
}

/// One item a cache holds, as the eviction planner sees it: a key, a size,
/// and when it was last used. The planner never sees the bytes.
struct CacheItemDescriptor: Equatable, Hashable, Sendable {
    let key: String
    let byteCount: Int
    let lastAccess: Date

    init(key: String, byteCount: Int, lastAccess: Date) {
        self.key = key
        self.byteCount = max(0, byteCount)
        self.lastAccess = lastAccess
    }
}

/// What one category holds right now.
struct CacheStatistics: Equatable, Hashable, Sendable, Identifiable {
    let category: CacheCategory
    let byteCount: Int
    let itemCount: Int

    /// Items currently held in memory as well as on disk, when the cache
    /// has a memory tier. Zero otherwise.
    let memoryItemCount: Int

    /// Bytes the memory tier holds, when there is one.
    let memoryByteCount: Int

    var id: CacheCategory { category }

    init(category: CacheCategory, byteCount: Int, itemCount: Int, memoryItemCount: Int = 0, memoryByteCount: Int = 0) {
        self.category = category
        self.byteCount = max(0, byteCount)
        self.itemCount = max(0, itemCount)
        self.memoryItemCount = max(0, memoryItemCount)
        self.memoryByteCount = max(0, memoryByteCount)
    }

    static func empty(_ category: CacheCategory) -> CacheStatistics {
        CacheStatistics(category: category, byteCount: 0, itemCount: 0)
    }
}

/// What one cleanup removed.
struct CacheCleanupReport: Equatable, Hashable, Sendable {
    let category: CacheCategory
    let removedItemCount: Int
    let freedByteCount: Int
    let skippedItemCount: Int

    init(category: CacheCategory, removedItemCount: Int = 0, freedByteCount: Int = 0, skippedItemCount: Int = 0) {
        self.category = category
        self.removedItemCount = max(0, removedItemCount)
        self.freedByteCount = max(0, freedByteCount)
        self.skippedItemCount = max(0, skippedItemCount)
    }

    /// Whether the cleanup removed anything.
    var removedAnything: Bool { removedItemCount > 0 }
}

/// Decides what a policy sweep removes. Pure and deterministic, so the rule
/// is testable without a filesystem.
///
/// Order of removal: first everything older than the policy's maximum age,
/// then — while the category is still over either budget — the least
/// recently used items. Items younger than the policy's minimum age are
/// never chosen; if only such items remain the category is left over
/// budget rather than having fresh work destroyed.
enum CacheEvictionPlanner {

    /// The keys to remove, least valuable first.
    static func plan(
        _ items: [CacheItemDescriptor],
        policy: CachePolicy,
        now: Date
    ) -> [String] {
        var remaining = items.sorted { lhs, rhs in
            if lhs.lastAccess != rhs.lastAccess { return lhs.lastAccess < rhs.lastAccess }
            return lhs.key < rhs.key
        }
        var evicted: [String] = []
        let protectedAfter = now.addingTimeInterval(-policy.minimumAge)

        func isProtected(_ item: CacheItemDescriptor) -> Bool {
            item.lastAccess > protectedAfter
        }

        if let maximumAge = policy.maximumAge {
            let expiredBefore = now.addingTimeInterval(-maximumAge)
            let expired = remaining.filter { $0.lastAccess < expiredBefore && !isProtected($0) }
            if !expired.isEmpty {
                let keys = Set(expired.map(\.key))
                evicted.append(contentsOf: expired.map(\.key))
                remaining.removeAll { keys.contains($0.key) }
            }
        }

        var bytes = remaining.reduce(0) { $0 + $1.byteCount }
        var count = remaining.count

        func overBudget() -> Bool {
            if let byteBudget = policy.byteBudget, bytes > byteBudget { return true }
            if let itemBudget = policy.itemBudget, count > itemBudget { return true }
            return false
        }

        var index = 0
        while overBudget() && index < remaining.count {
            let candidate = remaining[index]
            if isProtected(candidate) {
                index += 1
                continue
            }
            evicted.append(candidate.key)
            bytes -= candidate.byteCount
            count -= 1
            remaining.remove(at: index)
        }
        return evicted
    }
}
