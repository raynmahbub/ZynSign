import XCTest
@testable import ZynSign

/// Tests for the checks a dependency graph must pass before it can be ordered.
///
/// Every case here is a graph that contradicts itself, and every one must be
/// reported with its own reason rather than resolved by choosing. The graphs
/// are built directly, because that is how a contradiction is stated: some of
/// them — a duplicate node, a dependency on a node that does not exist — cannot
/// arise from a bundle structure at all, and discovery must refuse them just
/// the same.
final class NestedCodeGraphValidationTests: XCTestCase {

    // MARK: - Helpers

    private func graph(
        items: [NestedCodeItem],
        dependencies: [NestedCodeDependency] = [],
        root: NestedCodeItemID
    ) -> NestedCodeDependencyGraph {
        NestedCodeDependencyGraph(items: items, dependencies: dependencies, rootItemID: root)
    }

    private func rejection(
        _ graph: NestedCodeDependencyGraph,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> NestedCodeDiscoveryError? {
        guard case .rejected(let error) = graph.validated() else {
            XCTFail("Expected the graph to be rejected.", file: file, line: line)
            return nil
        }
        return error
    }

    /// The failure reason of a graph that a validated graph must expose, or
    /// `nil` when the graph was accepted.
    private func reason(_ graph: NestedCodeDependencyGraph) -> NestedCodeFailure? {
        if case .rejected(let error) = graph.validated() {
            return error.reason
        }
        return nil
    }

    // MARK: - Coherent graphs

    func testAStructuralGraphIsCoherent() {
        let application = makeNestedCodeItem(kind: .application, location: "")
        let framework = makeNestedCodeItem(
            kind: .framework,
            location: "Frameworks/Frame.framework",
            parentID: application.id
        )

        let graph = NestedCodeDependencyGraph.structural(
            items: [application, framework],
            rootItemID: application.id
        )

        XCTAssertEqual(graph.validated(), .coherent)
        XCTAssertTrue(graph.validated().isCoherent)
    }

    // MARK: - Duplicate nodes and paths

    func testTheSameItemTwiceIsRejectedAsADuplicateNode() throws {
        let framework = makeNestedCodeItem(kind: .framework, location: "Frameworks/Frame.framework")
        let application = makeNestedCodeItem(kind: .application, location: "")

        let error = try XCTUnwrap(rejection(graph(
            items: [application, framework, framework],
            root: application.id
        )))
        XCTAssertEqual(error.reason, .duplicateItem)
        XCTAssertEqual(error.path, framework.id.location)
        XCTAssertEqual(error.reason.category, .invalidInput)
    }

    func testTwoItemsNamingOneExecutableAreRejected() throws {
        let first = makeNestedCodeItem(
            kind: .framework,
            location: "Frameworks/First.framework",
            executablePath: "Shared/One.dylib"
        )
        let second = makeNestedCodeItem(
            kind: .framework,
            location: "Frameworks/Second.framework",
            executablePath: "Shared/One.dylib"
        )
        let application = makeNestedCodeItem(kind: .application, location: "")

        let error = try XCTUnwrap(rejection(graph(
            items: [application, first, second],
            root: application.id
        )))
        XCTAssertEqual(error.reason, .duplicateExecutablePath)
        XCTAssertEqual(error.path, makeBundlePath("Shared/One.dylib"))
    }

    // MARK: - Self-dependency and cycles

    func testAnItemThatDependsOnItselfIsRejected() throws {
        let framework = makeNestedCodeItem(kind: .framework, location: "Frameworks/Frame.framework")
        let application = makeNestedCodeItem(kind: .application, location: "")

        let error = try XCTUnwrap(rejection(graph(
            items: [application, framework],
            dependencies: [NestedCodeDependency(nestedCode: framework.id, container: framework.id)],
            root: application.id
        )))
        XCTAssertEqual(error.reason, .selfDependency)
        XCTAssertEqual(error.path, framework.id.location)
    }

    func testACycleIsRejectedRatherThanOrdered() throws {
        let first = makeNestedCodeItem(kind: .framework, location: "Frameworks/First.framework")
        let second = makeNestedCodeItem(kind: .framework, location: "Frameworks/Second.framework")
        let application = makeNestedCodeItem(kind: .application, location: "")

        let graph = graph(
            items: [application, first, second],
            dependencies: [
                NestedCodeDependency(nestedCode: first.id, container: second.id),
                NestedCodeDependency(nestedCode: second.id, container: first.id),
            ],
            root: application.id
        )

        let error = try XCTUnwrap(rejection(graph))
        XCTAssertEqual(error.reason, .dependencyCycle)
        XCTAssertTrue(error.detail.contains("Frameworks/First.framework"))
        XCTAssertTrue(error.detail.contains("Frameworks/Second.framework"))
        // A cyclic graph has no order, and discovery never invents one.
        XCTAssertTrue(graph.orderedItemIDs().isEmpty)
        XCTAssertEqual(Set(graph.unorderedItemIDs()), [first.id, second.id])
    }

    /// A cycle in the nested structure is a cycle even though every edge is a
    /// container edge: discovery never resolves it by falling back on an
    /// arbitrary order.
    func testANestedContainerCycleIsRejected() throws {
        let outer = makeNestedCodeItem(kind: .framework, location: "Frameworks/Outer.framework")
        let inner = makeNestedCodeItem(
            kind: .framework,
            location: "Frameworks/Outer.framework/Frameworks/Inner.framework",
            parentID: outer.id
        )
        // The hand-built graph makes the outer framework the child of the
        // framework it contains, which no valid bundle describes.
        let graph = graph(
            items: [outer, inner],
            dependencies: [
                NestedCodeDependency(nestedCode: inner.id, container: outer.id),
                NestedCodeDependency(nestedCode: outer.id, container: inner.id),
            ],
            root: outer.id
        )

        let error = try XCTUnwrap(rejection(graph))
        XCTAssertEqual(error.reason, .dependencyCycle)
    }

    // MARK: - Missing dependencies

    func testADependencyOnAMissingItemIsRejected() throws {
        let framework = makeNestedCodeItem(kind: .framework, location: "Frameworks/Frame.framework")
        let application = makeNestedCodeItem(kind: .application, location: "")
        let absent = NestedCodeItemID(kind: .framework, location: makeBundlePath("Frameworks/Absent.framework"))

        let error = try XCTUnwrap(rejection(graph(
            items: [application, framework],
            dependencies: [NestedCodeDependency(nestedCode: framework.id, container: absent)],
            root: application.id
        )))
        XCTAssertEqual(error.reason, .missingDependency)
        XCTAssertEqual(error.path, absent.location)
    }

    /// A parent identity that names no item becomes an edge to a node the
    /// graph does not contain, and is reported as such.
    func testAParentIdentityThatNamesNoItemIsRejected() throws {
        let application = makeNestedCodeItem(kind: .application, location: "")
        let orphanParent = NestedCodeItemID(kind: .framework, location: makeBundlePath("Frameworks/Absent.framework"))
        let orphan = makeNestedCodeItem(
            kind: .framework,
            location: "Frameworks/Orphan.framework",
            parentID: orphanParent
        )

        let graph = NestedCodeDependencyGraph.structural(items: [application, orphan], rootItemID: application.id)

        XCTAssertEqual(reason(graph), .missingDependency)
    }

    // MARK: - Locations

    /// An executable that is not inside its own container contradicts the
    /// model, and is reported as an invalid path rather than planned around.
    func testAnExecutableOutsideItsContainerIsRejected() throws {
        let framework = makeNestedCodeItem(
            kind: .framework,
            location: "Frameworks/Frame.framework",
            executablePath: "Frameworks/Elsewhere.dylib"
        )
        let application = makeNestedCodeItem(kind: .application, location: "")

        let error = try XCTUnwrap(rejection(graph(items: [application, framework], root: application.id)))
        XCTAssertEqual(error.reason, .invalidPath)
        XCTAssertEqual(error.path, makeBundlePath("Frameworks/Elsewhere.dylib"))
    }

    /// The path vocabulary itself refuses to express a location above the
    /// managed bundle, so a traversal or an absolute path cannot be stated,
    /// let alone planned for.
    func testABundlePathCannotExpressALocationOutsideTheBundle() {
        XCTAssertNil(BundlePath(rawValue: "../Example.app/Frameworks"))
        XCTAssertNil(BundlePath(rawValue: "/Frameworks"))
        XCTAssertNil(BundlePath(rawValue: "Frameworks/../../Elsewhere"))
        XCTAssertNil(BundlePath(components: ["Frameworks", ".."]))
        XCTAssertNil(BundlePath(components: ["Frameworks", ""]))
        XCTAssertEqual(BundlePath(components: [])?.isRoot, true)
    }

    // MARK: - Declared identities

    func testTwoItemsDeclaringOneBundleIdentifierAreRejected() throws {
        let first = makeNestedCodeItem(
            kind: .framework,
            location: "Frameworks/First.framework",
            bundleIdentifier: "com.example.synthetic.shared"
        )
        let second = makeNestedCodeItem(
            kind: .framework,
            location: "Frameworks/Second.framework",
            bundleIdentifier: "com.example.synthetic.shared"
        )
        let application = makeNestedCodeItem(kind: .application, location: "")

        let error = try XCTUnwrap(rejection(graph(
            items: [application, first, second],
            root: application.id
        )))
        XCTAssertEqual(error.reason, .conflictingBundleIdentifier)
        XCTAssertTrue(error.detail.contains("com.example.synthetic.shared"))
    }

    func testItemsDeclaringDifferentIdentifiersAreCoherent() {
        let first = makeNestedCodeItem(
            kind: .framework,
            location: "Frameworks/First.framework",
            bundleIdentifier: "com.example.synthetic.first"
        )
        let second = makeNestedCodeItem(
            kind: .framework,
            location: "Frameworks/Second.framework",
            bundleIdentifier: "com.example.synthetic.second"
        )
        let application = makeNestedCodeItem(kind: .application, location: "")

        XCTAssertEqual(graph(items: [application, first, second], root: application.id).validated(), .coherent)
    }

    // MARK: - The checks are ordered and stable

    func testTheFirstContradictionIsAlwaysTheSameOne() throws {
        let framework = makeNestedCodeItem(kind: .framework, location: "Frameworks/Frame.framework")
        let application = makeNestedCodeItem(kind: .application, location: "")

        // A graph that is both a duplicate node and self-dependent reports the
        // duplicate-node contradiction, because the checks run in a fixed
        // order.
        let error = try XCTUnwrap(rejection(graph(
            items: [application, framework, framework],
            dependencies: [NestedCodeDependency(nestedCode: framework.id, container: framework.id)],
            root: application.id
        )))
        XCTAssertEqual(error.reason, .duplicateItem)
    }
}
