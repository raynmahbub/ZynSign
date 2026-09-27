import Foundation

/// One place derived data is kept, as the cache manager sees it.
///
/// A store answers for exactly one category. It can describe what it
/// holds, list its items for the eviction planner, remove named items,
/// and remove everything. It cannot reach anything outside its category:
/// a thumbnail store cannot see metadata, and no store of any category can
/// see the library's artifacts, because none is ever given their location.
protocol CacheStoring: Sendable {

    var cacheCategory: CacheCategory { get }

    /// What the store holds right now.
    func cacheStatistics() async -> CacheStatistics

    /// The store's items, for the planner.
    func cacheItems() async -> [CacheItemDescriptor]

    /// Removes the items named by `keys`.
    func removeCacheItems(named keys: [String]) async -> CacheCleanupReport

    /// Removes everything the store holds.
    func removeAllCacheItems() async -> CacheCleanupReport
}

/// Applies cache policies, reports cache statistics, and runs cleanups.
///
/// **Policies.** One `CachePolicy` per category, the shipped defaults
/// unless the composition root supplies others. `enforcePolicies()` asks
/// each store for its items, hands them to the planner, and removes what
/// the planner names. It runs after work that grows a cache and from
/// `PerformanceEngine.optimize()`.
///
/// **Cleanups.** `clear(_:)` empties one category on request. The
/// Performance page confirms first; the manager does not.
///
/// **What it cannot do.** There is no category for imported applications,
/// no store is constructed over their directory, and the manager has no
/// method that takes a path — so no cleanup here can remove a package the
/// user imported.
actor CacheManager {

    private var stores: [CacheCategory: any CacheStoring] = [:]
    private var policies: [CacheCategory: CachePolicy]
    private let now: @Sendable () -> Date

    /// The last time each category was swept by policy.
    private(set) var lastEnforcement: [CacheCategory: Date] = [:]

    /// The cleanups run this launch, most recent first, bounded.
    private(set) var recentReports: [CacheCleanupReport] = []

    init(policies: [CachePolicy] = CachePolicy.standard, now: @escaping @Sendable () -> Date = { Date() }) {
        var byCategory: [CacheCategory: CachePolicy] = [:]
        for policy in policies {
            byCategory[policy.category] = policy
        }
        for category in CacheCategory.allCases where byCategory[category] == nil {
            byCategory[category] = .standard(for: category)
        }
        self.policies = byCategory
        self.now = now
    }

    /// Registers the store for its category, replacing any previous one.
    func register(_ store: any CacheStoring) {
        stores[store.cacheCategory] = store
    }

    /// The policy for `category`.
    func policy(for category: CacheCategory) -> CachePolicy {
        policies[category] ?? .standard(for: category)
    }

    /// Replaces the policy for its category.
    func setPolicy(_ policy: CachePolicy) {
        policies[policy.category] = policy
    }

    /// The categories a store is registered for.
    var registeredCategories: [CacheCategory] {
        CacheCategory.allCases.filter { stores[$0] != nil }
    }

    /// Statistics for every category, in category order. A category with
    /// no store reports empty.
    func statistics() async -> [CacheStatistics] {
        var result: [CacheStatistics] = []
        for category in CacheCategory.allCases {
            if let store = stores[category] {
                result.append(await store.cacheStatistics())
            } else {
                result.append(.empty(category))
            }
        }
        return result
    }

    /// Sweeps `category` by its policy. Returns what was removed.
    @discardableResult
    func enforcePolicy(for category: CacheCategory) async -> CacheCleanupReport {
        guard let store = stores[category] else { return CacheCleanupReport(category: category) }
        let items = await store.cacheItems()
        let keys = CacheEvictionPlanner.plan(items, policy: policy(for: category), now: now())
        lastEnforcement[category] = now()
        guard !keys.isEmpty else { return CacheCleanupReport(category: category) }
        let report = await store.removeCacheItems(named: keys)
        record(report)
        return report
    }

    /// Sweeps every category. Returns the reports that removed something.
    @discardableResult
    func enforcePolicies() async -> [CacheCleanupReport] {
        var reports: [CacheCleanupReport] = []
        for category in CacheCategory.allCases {
            let report = await enforcePolicy(for: category)
            if report.removedAnything {
                reports.append(report)
            }
        }
        return reports
    }

    /// Empties `category`.
    @discardableResult
    func clear(_ category: CacheCategory) async -> CacheCleanupReport {
        guard let store = stores[category] else { return CacheCleanupReport(category: category) }
        let report = await store.removeAllCacheItems()
        record(report)
        return report
    }

    /// Empties every category.
    @discardableResult
    func clearAll() async -> [CacheCleanupReport] {
        var reports: [CacheCleanupReport] = []
        for category in CacheCategory.allCases where stores[category] != nil {
            reports.append(await clear(category))
        }
        return reports
    }

    private func record(_ report: CacheCleanupReport) {
        recentReports.insert(report, at: 0)
        if recentReports.count > 20 {
            recentReports.removeLast(recentReports.count - 20)
        }
    }
}

/// A `CacheStoring` over the thumbnail cache, one per category the cache
/// accounts for.
struct ThumbnailCacheStore: CacheStoring {

    let cacheCategory: CacheCategory
    let cache: ThumbnailCache

    func cacheStatistics() async -> CacheStatistics {
        await cache.statistics(for: cacheCategory)
    }

    func cacheItems() async -> [CacheItemDescriptor] {
        await cache.diskDescriptors(for: cacheCategory)
    }

    func removeCacheItems(named keys: [String]) async -> CacheCleanupReport {
        await cache.removeDiskEntries(named: keys, category: cacheCategory)
    }

    func removeAllCacheItems() async -> CacheCleanupReport {
        await cache.removeAll(category: cacheCategory)
    }
}
