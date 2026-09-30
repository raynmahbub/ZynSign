import XCTest
@testable import ZynSign

/// Tests for the tweak library's domain model: kind inference, placement
/// policy, and the staging plan's validation rules.
final class TweakLibraryDomainTests: XCTestCase {

    // MARK: - Kind inference

    func testKindInferenceFollowsTheExtension() {
        XCTAssertEqual(TweakKind.infer(fromFileName: "loader.dylib"), .dynamicLibrary)
        XCTAssertEqual(TweakKind.infer(fromFileName: "patch.DYLIB"), .dynamicLibrary)
        XCTAssertEqual(TweakKind.infer(fromFileName: "bundle.deb"), .debPackage)
        XCTAssertEqual(TweakKind.infer(fromFileName: "Kit.framework"), .framework)
        XCTAssertEqual(TweakKind.infer(fromFileName: "Share.appex"), .appExtension)
        XCTAssertEqual(TweakKind.infer(fromFileName: "Resources.bundle"), .resourceBundle)
        XCTAssertEqual(TweakKind.infer(fromFileName: "notes.txt"), .other)
        XCTAssertEqual(TweakKind.infer(fromFileName: "archive"), .other)
    }

    // MARK: - Placement policy

    func testPlacementPolicyPlacesExecutablePayloadsAndRefusesArchives() {
        XCTAssertEqual(TweakPlacement.policy(for: .dynamicLibrary), .frameworks)
        XCTAssertEqual(TweakPlacement.policy(for: .framework), .frameworks)
        XCTAssertEqual(TweakPlacement.policy(for: .appExtension), .plugins)
        XCTAssertEqual(TweakPlacement.policy(for: .resourceBundle), .bundleRoot)
        XCTAssertEqual(TweakPlacement.policy(for: .debPackage), .unsupported)
        XCTAssertEqual(TweakPlacement.policy(for: .other), .unsupported)
    }

    func testPlacementDirectoriesMatchTheBundleModel() {
        XCTAssertEqual(TweakPlacement.frameworks.relativeDirectory, "Frameworks")
        XCTAssertEqual(TweakPlacement.plugins.relativeDirectory, "PlugIns")
        XCTAssertEqual(TweakPlacement.bundleRoot.relativeDirectory, "")
        XCTAssertNil(TweakPlacement.unsupported.relativeDirectory)
    }

    // MARK: - Plan validation

    private func descriptor(name: String, size: Int, kind: TweakKind = .dynamicLibrary) -> TweakDescriptor {
        TweakDescriptor(name: name, fileName: name + ".dylib", kind: kind, byteSize: size, sha256Hex: "00")
    }

    func testEmptySelectionRefuses() {
        guard case .failure(let refusal) = TweakInjectionPlan.makePlan(selection: []) else {
            return XCTFail("An empty selection must refuse.")
        }
        XCTAssertEqual(refusal, .empty)
    }

    func testSelectionOrderIsDeterministic() throws {
        let plan = try planOrThrow(TweakInjectionPlan.makePlan(selection: [
            descriptor(name: "zeta", size: 10),
            descriptor(name: "alpha", size: 10),
        ]))
        XCTAssertEqual(plan.entries.map(\.name), ["alpha", "zeta"])
    }

    func testEntryLimitRefuses() {
        let many = (0...TweakInjectionPlan.maximumEntries).map { descriptor(name: "tweak-\($0)", size: 1) }
        guard case .failure(.tooManyEntries(let count, let limit)) = TweakInjectionPlan.makePlan(selection: many) else {
            return XCTFail("A selection beyond the entry bound must refuse.")
        }
        XCTAssertEqual(count, many.count)
        XCTAssertEqual(limit, TweakInjectionPlan.maximumEntries)
    }

    func testByteLimitRefuses() {
        let heavy = [
            descriptor(name: "big", size: TweakInjectionPlan.maximumTotalBytes),
            descriptor(name: "bigger", size: 1),
        ]
        guard case .failure(.tooLarge(let total, let limit)) = TweakInjectionPlan.makePlan(selection: heavy) else {
            return XCTFail("A selection beyond the byte bound must refuse.")
        }
        XCTAssertEqual(total, TweakInjectionPlan.maximumTotalBytes + 1)
        XCTAssertEqual(limit, TweakInjectionPlan.maximumTotalBytes)
    }

    func testManifestEntriesCarryThePlacementDirectory() throws {
        let plan = try planOrThrow(TweakInjectionPlan.makePlan(selection: [
            descriptor(name: "lib", size: 10, kind: .dynamicLibrary),
            descriptor(name: "ext", size: 10, kind: .appExtension),
        ]))
        let byName = Dictionary(uniqueKeysWithValues: plan.manifestEntries.map { ($0.name, $0) })
        XCTAssertEqual(byName["lib"]?.targetDirectory, "Frameworks")
        XCTAssertEqual(byName["ext"]?.targetDirectory, "PlugIns")
        XCTAssertEqual(byName["lib"]?.sha256Hex, "00")
    }

    func testUnstageableEntriesAreReported() throws {
        let plan = try planOrThrow(TweakInjectionPlan.makePlan(selection: [
            descriptor(name: "lib", size: 10, kind: .dynamicLibrary),
            descriptor(name: "deb", size: 10, kind: .debPackage),
        ]))
        XCTAssertFalse(plan.isFullyStageable)
        XCTAssertEqual(plan.unstageableEntries.map(\.name), ["deb"])
    }

    private func planOrThrow(_ result: Result<TweakInjectionPlan, TweakInjectionPlan.Refusal>) throws -> TweakInjectionPlan {
        switch result {
        case .success(let plan): return plan
        case .failure(let refusal):
            XCTFail("Expected a plan, got refusal: \(refusal.message)")
            throw CancellationError()
        }
    }
}
