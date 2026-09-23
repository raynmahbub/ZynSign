import XCTest
@testable import ZynSign

/// Tests for the deterministic signing order a dependency graph produces.
///
/// The order is the property this suite exists for: a nested component is
/// always finalized before the container whose signature seals it, independent
/// components follow the documented bundle-relative path tie-breaker, and the
/// application is last because it depends on everything inside it. Two kinds
/// of graph are used. Structural graphs are what discovery builds — every
/// nested item's container is its parent. Hand-specified graphs carry their
/// dependencies explicitly, including for fixtures whose items have no parent
/// at all, so the tests show that the order comes from the graph rather than
/// from the structure the fixtures happen to have.
final class NestedCodeSigningOrderTests: XCTestCase {

    // MARK: - Helpers

    private func graph(
        items: [NestedCodeItem],
        dependencies: [NestedCodeDependency],
        root: NestedCodeItemID
    ) -> NestedCodeDependencyGraph {
        NestedCodeDependencyGraph(items: items, dependencies: dependencies, rootItemID: root)
    }

    private func order(_ graph: NestedCodeDependencyGraph) -> [NestedCodeItemID] {
        graph.orderedItemIDs()
    }

    private func assertCoherent(
        _ graph: NestedCodeDependencyGraph,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch graph.validated() {
        case .coherent:
            break
        case .rejected(let error):
            XCTFail("Expected a coherent graph, got \(error.description).", file: file, line: line)
        }
    }

    // MARK: - Chains

    /// A framework inside a framework inside the application: the innermost
    /// component is finalized first, its container next, the application last.
    func testStructuralChainOrdersTheInnermostFrameworkFirstAndTheApplicationLast() {
        let application = makeNestedCodeItem(kind: .application, location: "")
        let outer = makeNestedCodeItem(
            kind: .framework,
            location: "Frameworks/Outer.framework",
            parentID: application.id
        )
        let inner = makeNestedCodeItem(
            kind: .framework,
            location: "Frameworks/Outer.framework/Frameworks/Inner.framework",
            parentID: outer.id
        )

        let graph = NestedCodeDependencyGraph.structural(
            items: [application, outer, inner],
            rootItemID: application.id
        )

        assertCoherent(graph)
        XCTAssertEqual(order(graph), [inner.id, outer.id, application.id])
        XCTAssertEqual(graph.dependencies.count, 2)
        XCTAssertEqual(
            Set(graph.dependencies),
            [
                NestedCodeDependency(nestedCode: inner.id, container: outer.id),
                NestedCodeDependency(nestedCode: outer.id, container: application.id),
            ]
        )
    }

    /// `A depends on B, B depends on C → C, B, A`, stated as an explicit hand
    /// graph: the items carry no parent, so nothing but the declared
    /// dependencies can produce this order.
    func testHandSpecifiedChainOrdersCBeforeBAndBBeforeA() {
        let a = makeNestedCodeItem(kind: .framework, location: "Frameworks/A.framework")
        let b = makeNestedCodeItem(kind: .framework, location: "Frameworks/B.framework")
        let c = makeNestedCodeItem(kind: .framework, location: "Frameworks/C.framework")
        XCTAssertTrue([a, b, c].allSatisfy { $0.parentID == nil }, "The fixture must not supply structural edges.")

        let graph = graph(
            items: [a, b, c],
            dependencies: [
                NestedCodeDependency(nestedCode: b.id, container: a.id),
                NestedCodeDependency(nestedCode: c.id, container: b.id),
            ],
            root: a.id
        )

        assertCoherent(graph)
        XCTAssertEqual(order(graph), [c.id, b.id, a.id])
    }

    /// Independent `A` and `B` with `C` depending on both: `A` and `B` come in
    /// the documented path order, and `C` follows them.
    func testIndependentComponentsFollowTheDocumentedPathTieBreak() {
        let a = makeNestedCodeItem(kind: .framework, location: "Frameworks/A.framework")
        let b = makeNestedCodeItem(kind: .framework, location: "Frameworks/B.framework")
        let c = makeNestedCodeItem(kind: .framework, location: "Frameworks/C.framework")

        let graph = graph(
            items: [a, b, c],
            dependencies: [
                NestedCodeDependency(nestedCode: a.id, container: c.id),
                NestedCodeDependency(nestedCode: b.id, container: c.id),
            ],
            root: c.id
        )

        assertCoherent(graph)
        XCTAssertEqual(order(graph), [a.id, b.id, c.id])
    }

    /// The tie-breaker is the bundle-relative path, not the order the items
    /// happen to appear in: reversing the collection changes nothing.
    func testIndependentComponentsOrderIdenticallyWhateverOrderTheItemsArriveIn() {
        let a = makeNestedCodeItem(kind: .framework, location: "Frameworks/A.framework")
        let b = makeNestedCodeItem(kind: .framework, location: "Frameworks/B.framework")
        let c = makeNestedCodeItem(kind: .application, location: "")
        let dependencies = [
            NestedCodeDependency(nestedCode: a.id, container: c.id),
            NestedCodeDependency(nestedCode: b.id, container: c.id),
        ]

        let forward = graph(items: [c, a, b], dependencies: dependencies, root: c.id)
        let reversed = graph(items: [b, a, c], dependencies: Array(dependencies.reversed()), root: c.id)

        XCTAssertEqual(order(forward), [a.id, b.id, c.id])
        XCTAssertEqual(order(forward), order(reversed))
    }

    /// The comparison is the path comparison, not a directory preference: a
    /// framework under `PlugIns` and one under `Frameworks` order by their
    /// recorded locations.
    func testTieBreakComparesBundleRelativeLocations() {
        let plugIns = makeNestedCodeItem(kind: .applicationExtension, location: "PlugIns/Widget.appex")
        let frameworks = makeNestedCodeItem(kind: .framework, location: "Frameworks/Frame.framework")
        let application = makeNestedCodeItem(kind: .application, location: "")
        let attributes = [
            NestedCodeDependency(nestedCode: plugIns.id, container: application.id),
            NestedCodeDependency(nestedCode: frameworks.id, container: application.id),
        ]

        let graph = self.graph(items: [application, plugIns, frameworks], dependencies: attributes, root: application.id)

        assertCoherent(graph)
        XCTAssertEqual(order(graph), [frameworks.id, plugIns.id, application.id])
    }

    // MARK: - Deep nesting

    func testDeepNestingOrdersEveryLevelBeforeItsContainer() {
        let application = makeNestedCodeItem(kind: .application, location: "")
        let levelOne = makeNestedCodeItem(
            kind: .framework,
            location: "Frameworks/One.framework",
            parentID: application.id
        )
        let levelTwo = makeNestedCodeItem(
            kind: .framework,
            location: "Frameworks/One.framework/Frameworks/Two.framework",
            parentID: levelOne.id
        )
        let levelThree = makeNestedCodeItem(
            kind: .framework,
            location: "Frameworks/One.framework/Frameworks/Two.framework/Frameworks/Three.framework",
            parentID: levelTwo.id
        )
        let library = makeNestedCodeItem(
            kind: .dynamicLibrary,
            location: "Frameworks/One.framework/Frameworks/Two.framework/Frameworks/Three.framework/Loose.dylib",
            parentID: levelThree.id
        )

        let graph = NestedCodeDependencyGraph.structural(
            items: [application, levelOne, levelTwo, levelThree, library],
            rootItemID: application.id
        )

        assertCoherent(graph)
        XCTAssertEqual(
            order(graph),
            [library.id, levelThree.id, levelTwo.id, levelOne.id, application.id]
        )
    }

    /// The application is last for every graph discovery builds, whatever the
    /// nested content looks like.
    func testTheApplicationIsAlwaysTheLastStepOfAStructuralGraph() {
        let application = makeNestedCodeItem(kind: .application, location: "")
        let framework = makeNestedCodeItem(
            kind: .framework,
            location: "Frameworks/Frame.framework",
            parentID: application.id
        )
        let extensionBundle = makeNestedCodeItem(
            kind: .applicationExtension,
            location: "PlugIns/Widget.appex",
            parentID: application.id
        )
        let library = makeNestedCodeItem(
            kind: .dynamicLibrary,
            location: "Frameworks/Loose.dylib",
            parentID: application.id
        )

        let graph = NestedCodeDependencyGraph.structural(
            items: [framework, extensionBundle, library, application],
            rootItemID: application.id
        )

        assertCoherent(graph)
        let ordered = order(graph)
        XCTAssertEqual(ordered.count, 4)
        XCTAssertEqual(ordered.last, application.id)
        XCTAssertEqual(ordered, [framework.id, library.id, extensionBundle.id, application.id])
    }

    // MARK: - Contradictions produce no order

    func testACyclicGraphHasNoOrderAndNamesItsCycle() {
        let a = makeNestedCodeItem(kind: .framework, location: "Frameworks/A.framework")
        let b = makeNestedCodeItem(kind: .framework, location: "Frameworks/B.framework")
        let graph = graph(
            items: [a, b],
            dependencies: [
                NestedCodeDependency(nestedCode: a.id, container: b.id),
                NestedCodeDependency(nestedCode: b.id, container: a.id),
            ],
            root: a.id
        )

        XCTAssertTrue(order(graph).isEmpty)
        XCTAssertEqual(Set(graph.unorderedItemIDs()), [a.id, b.id])
        guard case .rejected(let error) = graph.validated() else {
            return XCTFail("A cyclic graph must be rejected.")
        }
        XCTAssertEqual(error.reason, .dependencyCycle)
    }

    // MARK: - Edges are recorded once and in a stable order

    func testDuplicateEdgesAreRecordedOnce() {
        let a = makeNestedCodeItem(kind: .framework, location: "Frameworks/A.framework")
        let application = makeNestedCodeItem(kind: .application, location: "")
        let edge = NestedCodeDependency(nestedCode: a.id, container: application.id)

        let graph = self.graph(items: [application, a], dependencies: [edge, edge, edge], root: application.id)

        XCTAssertEqual(graph.dependencies, [edge])
    }

    func testStructuralGraphDerivesOneEdgePerNestedItem() {
        let application = makeNestedCodeItem(kind: .application, location: "")
        let framework = makeNestedCodeItem(
            kind: .framework,
            location: "Frameworks/Frame.framework",
            parentID: application.id
        )

        let graph = NestedCodeDependencyGraph.structural(
            items: [framework, application],
            rootItemID: application.id
        )

        XCTAssertEqual(graph.items.first?.id, application.id, "The application is the first node.")
        XCTAssertEqual(
            graph.dependencies,
            [NestedCodeDependency(nestedCode: framework.id, container: application.id)]
        )
    }
}
