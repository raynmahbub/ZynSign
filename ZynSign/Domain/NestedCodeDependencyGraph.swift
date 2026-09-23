/// The dependency graph one signing plan rests on, and the deterministic
/// signing order derived from it.
///
/// The graph is the reason a plan's order is trustworthy rather than
/// alphabetical. Discovery contributes exactly one kind of edge — a nested
/// item depends on its container, because a container's signature seals the
/// code inside it and cannot be written before that code is finalized — and
/// the order falls out of the graph rather than out of a directory listing.
/// Nothing here invents runtime dependencies between sibling components: the
/// bundle structure does not establish them, and a signing order must not
/// claim knowledge the structure does not carry.
///
/// ## Determinism
///
/// Two rules make the graph and the order reproducible.
///
/// Nodes and edges are compared by their bundle-relative locations, the same
/// comparison the archive layer already uses on path values. Every collection
/// this type produces is sorted by that comparison before it is returned, so
/// two runs over the same bundle produce byte-identical plans whatever order
/// the container recorded its entries in.
///
/// Among nodes whose dependencies are all satisfied, the order always takes
/// the one that compares smallest. That is the documented tie-breaker for
/// independent components: not enumeration order, not insertion order, and not
/// an ordering that could differ between runs.
struct NestedCodeDependencyGraph: Equatable {

    /// The application's item identity. It is a node like any other, and its
    /// structure — every nested item depends on it — is what places it last.
    let rootItemID: NestedCodeItemID

    /// Every node, application first and nested items ordered by location.
    let items: [NestedCodeItem]

    /// Every edge, ordered deterministically.
    let dependencies: [NestedCodeDependency]

    /// Records a graph.
    init(
        items: [NestedCodeItem],
        dependencies: [NestedCodeDependency],
        rootItemID: NestedCodeItemID
    ) {
        self.rootItemID = rootItemID
        self.items = items
        self.dependencies = NestedCodeDependencyGraph.sortedDependencies(dependencies)
    }

    /// Builds the graph the bundle structure establishes: every nested item
    /// depends on the container whose directory holds it.
    ///
    /// Ordering and comparison happen here so that the plan a caller receives
    /// never depends on the order discovery happened to visit items in.
    static func structural(items: [NestedCodeItem], rootItemID: NestedCodeItemID) -> NestedCodeDependencyGraph {
        var ordered = items.sorted { precedes($0.id, $1.id) }
        if let rootIndex = ordered.firstIndex(where: { $0.id == rootItemID }) {
            let root = ordered.remove(at: rootIndex)
            ordered.insert(root, at: 0)
        }
        let dependencies = ordered.compactMap { item -> NestedCodeDependency? in
            guard let parentID = item.parentID else { return nil }
            return NestedCodeDependency(nestedCode: item.id, container: parentID)
        }
        return NestedCodeDependencyGraph(
            items: ordered,
            dependencies: dependencies,
            rootItemID: rootItemID
        )
    }

    // MARK: - Validation

    /// Validates the graph, reporting the first problem found.
    ///
    /// The checks run in a fixed order so that one graph always produces the
    /// same finding: duplicate nodes, duplicate executable locations, paths
    /// that cannot lie inside the managed bundle, self-dependencies,
    /// dependencies on missing nodes, conflicting bundle identifiers, and
    /// cycles. A cyclic graph is rejected rather than ordered, because any
    /// order for it would place one component after something that must be
    /// finalized before it.
    func validated() -> NestedCodeGraphValidation {
        if let error = duplicateItemError() { return .rejected(error) }
        if let error = duplicateExecutablePathError() { return .rejected(error) }
        if let error = pathError() { return .rejected(error) }
        if let error = selfDependencyError() { return .rejected(error) }
        if let error = missingDependencyError() { return .rejected(error) }
        if let error = conflictingBundleIdentifierError() { return .rejected(error) }
        if let error = cycleError() { return .rejected(error) }
        return .coherent
    }

    // MARK: - Ordering

    /// The deterministic signing order, or an empty array when no order
    /// exists because the graph is cyclic or refers to missing nodes.
    ///
    /// Callers validate first; this method is total so that an unvalidated
    /// graph can never be ordered by accident.
    func orderedItemIDs() -> [NestedCodeItemID] {
        let prerequisites = Self.prerequisites(of: dependencies)
        var emitted: Set<NestedCodeItemID> = []
        var order: [NestedCodeItemID] = []
        order.reserveCapacity(items.count)

        while order.count < items.count {
            let ready = items.map(\.id).filter { id in
                guard !emitted.contains(id) else { return false }
                return (prerequisites[id] ?? []).allSatisfy { emitted.contains($0) }
            }
            guard let next = ready.min(by: Self.precedes) else { return [] }
            emitted.insert(next)
            order.append(next)
        }
        return order
    }

    /// The nodes that remain when no further node can be emitted, which is
    /// the cycle a rejected graph contains.
    func unorderedItemIDs() -> [NestedCodeItemID] {
        let ordered = Set(orderedItemIDs())
        return items.map(\.id).filter { !ordered.contains($0) }
    }

    // MARK: - Comparison

    /// The documented ordering comparison: bundle-relative location first,
    /// then kind, both compared the way the archive layer compares path
    /// values. Two distinct item identities always compare differently,
    /// because a location carries at most one kind of item.
    static func precedes(_ lhs: NestedCodeItemID, _ rhs: NestedCodeItemID) -> Bool {
        if lhs.location.rawValue != rhs.location.rawValue {
            return lhs.location.rawValue < rhs.location.rawValue
        }
        return lhs.kind.rawValue < rhs.kind.rawValue
    }

    // MARK: - Internals

    private static func sortedDependencies(_ dependencies: [NestedCodeDependency]) -> [NestedCodeDependency] {
        var unique: [NestedCodeDependency] = []
        for dependency in dependencies.sorted(by: dependencyPrecedes) where !unique.contains(dependency) {
            unique.append(dependency)
        }
        return unique
    }

    private static func dependencyPrecedes(_ lhs: NestedCodeDependency, _ rhs: NestedCodeDependency) -> Bool {
        if lhs.nestedCode != rhs.nestedCode {
            return precedes(lhs.nestedCode, rhs.nestedCode)
        }
        return precedes(lhs.container, rhs.container)
    }

    private static func prerequisites(
        of dependencies: [NestedCodeDependency]
    ) -> [NestedCodeItemID: [NestedCodeItemID]] {
        var prerequisites: [NestedCodeItemID: [NestedCodeItemID]] = [:]
        for dependency in dependencies {
            prerequisites[dependency.container, default: []].append(dependency.nestedCode)
        }
        return prerequisites
    }

    private func duplicateItemError() -> NestedCodeDiscoveryError? {
        var seen: Set<NestedCodeItemID> = []
        for item in items where !seen.insert(item.id).inserted {
            return NestedCodeDiscoveryError(
                .duplicateItem,
                at: item.id.location,
                detail: "Item '\(item.id)' appears more than once in the dependency graph."
            )
        }
        return nil
    }

    private func duplicateExecutablePathError() -> NestedCodeDiscoveryError? {
        var byPath: [BundlePath: NestedCodeItemID] = [:]
        for item in items {
            guard let executablePath = item.executablePath else { continue }
            if let existing = byPath[executablePath], existing != item.id {
                return NestedCodeDiscoveryError(
                    .duplicateExecutablePath,
                    at: executablePath,
                    detail: "Items '\(existing)' and '\(item.id)' both name '\(executablePath.rawValue)' as their executable."
                )
            }
            byPath[executablePath] = item.id
        }
        return nil
    }

    private func pathError() -> NestedCodeDiscoveryError? {
        for item in items {
            if item.id != rootItemID, !item.bundlePath.isWithin(.root) {
                return NestedCodeDiscoveryError(
                    .invalidPath,
                    at: item.id.location,
                    detail: "Item '\(item.id)' is not inside the managed application bundle."
                )
            }
            guard let executablePath = item.executablePath else { continue }
            guard executablePath.isWithin(item.bundlePath) else {
                return NestedCodeDiscoveryError(
                    .invalidPath,
                    at: executablePath,
                    detail: "The executable at '\(executablePath.rawValue)' is not inside its container '\(item.bundlePath.rawValue)'."
                )
            }
        }
        return nil
    }

    private func selfDependencyError() -> NestedCodeDiscoveryError? {
        for dependency in dependencies where dependency.nestedCode == dependency.container {
            return NestedCodeDiscoveryError(
                .selfDependency,
                at: dependency.nestedCode.location,
                detail: "Item '\(dependency.nestedCode)' depends on itself."
            )
        }
        return nil
    }

    private func missingDependencyError() -> NestedCodeDiscoveryError? {
        let known = Set(items.map(\.id))
        for dependency in dependencies {
            for endpoint in [dependency.nestedCode, dependency.container] where !known.contains(endpoint) {
                return NestedCodeDiscoveryError(
                    .missingDependency,
                    at: endpoint.location,
                    detail: "A dependency names '\(endpoint)', which the plan does not contain."
                )
            }
        }
        return nil
    }

    private func conflictingBundleIdentifierError() -> NestedCodeDiscoveryError? {
        var byIdentifier: [String: NestedCodeItemID] = [:]
        for item in items {
            guard let identifier = item.identity?.bundleIdentifier else { continue }
            let key = identifier.rawValue
            if let existing = byIdentifier[key], existing != item.id {
                return NestedCodeDiscoveryError(
                    .conflictingBundleIdentifier,
                    at: item.id.location,
                    detail: "Items '\(existing)' and '\(item.id)' both declare the bundle identifier '\(key)'."
                )
            }
            byIdentifier[key] = item.id
        }
        return nil
    }

    private func cycleError() -> NestedCodeDiscoveryError? {
        let unordered = unorderedItemIDs()
        guard !unordered.isEmpty else { return nil }
        let names = unordered.map { $0.location.rawValue }.joined(separator: ", ")
        return NestedCodeDiscoveryError(
            .dependencyCycle,
            at: unordered.first?.location,
            detail: "The dependency graph contains a cycle through: \(names)."
        )
    }
}

/// The outcome of validating one dependency graph.
enum NestedCodeGraphValidation: Equatable {

    /// The graph is coherent and can be ordered.
    case coherent

    /// The graph contradicts itself; no plan may be produced from it.
    case rejected(NestedCodeDiscoveryError)

    /// Whether the graph is coherent.
    var isCoherent: Bool {
        if case .coherent = self {
            return true
        }
        return false
    }
}
