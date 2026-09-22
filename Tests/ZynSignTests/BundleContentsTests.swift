import XCTest
@testable import ZynSign

/// Tests for the bundle structure the explorer derives from a package's
/// entry table.
///
/// Every table here is synthetic. The tests establish the boundary — only
/// entries inside the bundle, never the payload directory or a sibling —
/// the tree's completeness with and without recorded directories, the
/// deterministic ordering, the treatment of links and unsupported kinds,
/// and the fact that declared sizes are carried without any content being
/// read: there is no reader in these tests at all.
final class BundleContentsTests: XCTestCase {

    private let bundlePath = makePath("Payload/Example.app")

    private func inBundle(_ name: String) -> String {
        "Payload/Example.app/\(name)"
    }

    private func contents(
        _ table: [ArchiveEntry],
        executable: String? = nil
    ) -> BundleContents {
        BundleContents(entryTable: table, bundlePath: bundlePath, declaredExecutableName: executable)
    }

    private func path(_ rawValue: String) throws -> BundlePath {
        try XCTUnwrap(BundlePath(rawValue: rawValue), "Test used an invalid bundle path: \(rawValue)")
    }

    // MARK: - Enumeration

    func testEmptyBundleHasNoEntries() {
        let result = contents([
            makeEntry("Payload", kind: .directory),
            makeEntry("Payload/Example.app", kind: .directory),
        ])
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.entryCount, 0)
        XCTAssertEqual(result.rootEntries, [])
        XCTAssertEqual(result.entries(in: .root), [])
        XCTAssertEqual(result.childCount(of: .root), 0)
        XCTAssertEqual(result.bundleName, "Example.app")
        XCTAssertEqual(result.notableEntries, [])
        XCTAssertEqual(result.totalDeclaredByteCount, 0)
    }

    func testSingleFileBundle() throws {
        let result = contents([
            makeEntry("Payload", kind: .directory),
            makeEntry("Payload/Example.app", kind: .directory),
            makeEntry(inBundle("Info.plist"), uncompressedSize: 512, compressedSize: 300),
        ])
        XCTAssertFalse(result.isEmpty)
        XCTAssertEqual(result.entryCount, 1)
        let entry = try XCTUnwrap(result.rootEntries.first)
        XCTAssertEqual(entry.name, "Info.plist")
        XCTAssertEqual(entry.path, try path("Info.plist"))
        XCTAssertEqual(entry.kind, .regularFile)
        XCTAssertEqual(entry.declaredByteCount, 512)
        XCTAssertEqual(entry.role, .bundleInformation)
        XCTAssertEqual(result.entry(at: try path("Info.plist")), entry)
    }

    func testNestedDirectoriesAtSeveralDepths() throws {
        let result = contents([
            makeEntry("Payload", kind: .directory),
            makeEntry("Payload/Example.app", kind: .directory),
            makeEntry(inBundle("Frameworks"), kind: .directory),
            makeEntry(inBundle("Frameworks/A.framework"), kind: .directory),
            makeEntry(inBundle("Frameworks/A.framework/A"), uncompressedSize: 100),
            makeEntry(inBundle("Frameworks/A.framework/Resources"), kind: .directory),
            makeEntry(inBundle("Frameworks/A.framework/Resources/en.lproj"), kind: .directory),
            makeEntry(inBundle("Frameworks/A.framework/Resources/en.lproj/Localizable.strings"), uncompressedSize: 20),
            makeEntry(inBundle("Info.plist"), uncompressedSize: 5),
        ])
        XCTAssertEqual(result.entryCount, 7)
        XCTAssertEqual(result.rootEntries.map(\.name), ["Frameworks", "Info.plist"])
        XCTAssertEqual(result.entries(in: try path("Frameworks"))?.map(\.name), ["A.framework"])
        XCTAssertEqual(result.entries(in: try path("Frameworks/A.framework"))?.map(\.name), ["Resources", "A"])
        XCTAssertEqual(result.entries(in: try path("Frameworks/A.framework/Resources"))?.map(\.name), ["en.lproj"])
        XCTAssertEqual(
            result.entries(in: try path("Frameworks/A.framework/Resources/en.lproj"))?.map(\.path.rawValue),
            ["Frameworks/A.framework/Resources/en.lproj/Localizable.strings"]
        )
        XCTAssertEqual(result.childCount(of: try path("Frameworks/A.framework")), 2)
        XCTAssertEqual(result.totalDeclaredByteCount, 125)
    }

    func testDirectoriesTheContainerDidNotRecordAreImplied() throws {
        let result = contents([
            makeEntry(inBundle("Frameworks/A.framework/A"), uncompressedSize: 100),
            makeEntry(inBundle("Info.plist")),
        ])
        XCTAssertEqual(result.entryCount, 4)
        let frameworks = try XCTUnwrap(result.entry(at: try path("Frameworks")))
        XCTAssertEqual(frameworks.kind, .directory)
        XCTAssertNil(frameworks.declaredByteCount)
        XCTAssertEqual(frameworks.role, .frameworksDirectory)
        XCTAssertEqual(result.entries(in: try path("Frameworks"))?.map(\.name), ["A.framework"])
        XCTAssertEqual(result.entries(in: try path("Frameworks/A.framework"))?.map(\.name), ["A"])
        XCTAssertEqual(result.bundleName, "Example.app")
    }

    func testEmptyDirectoryIsListedAndAnswersEmpty() throws {
        let result = contents([
            makeEntry(inBundle("PlugIns"), kind: .directory),
            makeEntry(inBundle("Info.plist")),
        ])
        XCTAssertEqual(result.entries(in: try path("PlugIns")), [])
        XCTAssertEqual(result.childCount(of: try path("PlugIns")), 0)
    }

    func testUnknownAndNonDirectoryLocationsAnswerNil() throws {
        let result = contents([
            makeEntry(inBundle("Info.plist"), uncompressedSize: 5),
        ])
        XCTAssertNil(result.entries(in: try path("Frameworks")))
        XCTAssertNil(result.entries(in: try path("Info.plist")))
        XCTAssertNil(result.childCount(of: try path("Info.plist")))
        XCTAssertNil(result.entry(at: try path("Missing")))
        XCTAssertNil(result.entry(at: .root))
    }

    // MARK: - Ordering

    func testEntriesAreOrderedDirectoriesFirstThenByName() throws {
        let result = contents([
            makeEntry(inBundle("zeta.txt")),
            makeEntry(inBundle("Assets.car")),
            makeEntry(inBundle("beta"), kind: .directory),
            makeEntry(inBundle("Alpha"), kind: .directory),
            makeEntry(inBundle("alpha.txt")),
            makeEntry(inBundle("Zeta"), kind: .directory),
            makeEntry(inBundle("link"), kind: .symbolicLink),
            makeEntry(inBundle("_CodeSignature"), kind: .directory),
            makeEntry(inBundle("10.txt")),
            makeEntry(inBundle("9.txt")),
        ])
        XCTAssertEqual(
            result.rootEntries.map(\.name),
            ["Alpha", "Zeta", "_CodeSignature", "beta", "10.txt", "9.txt", "Assets.car", "alpha.txt", "link", "zeta.txt"]
        )
    }

    func testOrderingDoesNotDependOnTableOrder() throws {
        let table = [
            makeEntry("Payload", kind: .directory),
            makeEntry("Payload/Example.app", kind: .directory),
            makeEntry(inBundle("Info.plist"), uncompressedSize: 10),
            makeEntry(inBundle("Example"), uncompressedSize: 20),
            makeEntry(inBundle("Frameworks"), kind: .directory),
            makeEntry(inBundle("Frameworks/B.framework/B"), uncompressedSize: 30),
            makeEntry(inBundle("Frameworks/A.framework"), kind: .directory),
            makeEntry(inBundle("Frameworks/A.framework/A"), uncompressedSize: 40),
            makeEntry(inBundle("_CodeSignature/CodeResources"), uncompressedSize: 50),
            makeEntry(inBundle("Base.lproj/Main.storyboardc/Main.nib"), uncompressedSize: 60),
        ]
        let forward = contents(table, executable: "Example")
        let reversed = contents(Array(table.reversed()), executable: "Example")
        var generator = SeededGenerator(seed: 0x5EED)
        let shuffled = contents(table.shuffled(using: &generator), executable: "Example")

        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(forward, shuffled)
        XCTAssertEqual(forward.rootEntries, reversed.rootEntries)
        XCTAssertEqual(forward.notableEntries, shuffled.notableEntries)
        XCTAssertEqual(
            forward.rootEntries.map(\.name),
            ["Base.lproj", "Frameworks", "_CodeSignature", "Example", "Info.plist"]
        )
    }

    // MARK: - Boundary

    func testOnlyEntriesInsideTheBundleAreIncluded() throws {
        let result = contents([
            makeEntry("Payload", kind: .directory),
            makeEntry("Payload/Example.app", kind: .directory),
            makeEntry(inBundle("Info.plist"), uncompressedSize: 1),
            makeEntry("Payload/Other.app", kind: .directory),
            makeEntry("Payload/Other.app/Info.plist", uncompressedSize: 1_000),
            makeEntry("Payload/Example.app2/Info.plist", uncompressedSize: 1_000),
            makeEntry("Payload/Example.appendix", uncompressedSize: 1_000),
            makeEntry("Example.app/Info.plist", uncompressedSize: 1_000),
            makeEntry("iTunesMetadata.plist", uncompressedSize: 1_000),
            makeEntry("Symbols", kind: .directory),
            makeEntry("META-INF/com.apple.ZipMetadata.plist", uncompressedSize: 1_000),
        ])
        XCTAssertEqual(result.entryCount, 1)
        XCTAssertEqual(result.rootEntries.map(\.path.rawValue), ["Info.plist"])
        XCTAssertEqual(result.totalDeclaredByteCount, 1)
        XCTAssertEqual(result.omittedEntryCount, 0)
    }

    func testTheBundleDirectoryItselfIsNotAnEntry() throws {
        let result = contents([
            makeEntry("Payload/Example.app", kind: .directory),
            makeEntry(inBundle("Info.plist")),
        ])
        XCTAssertEqual(result.entryCount, 1)
        XCTAssertNil(result.entry(at: .root))
        XCTAssertFalse(result.rootEntries.contains { $0.name == "Example.app" })
    }

    func testEveryLocationIsRelativeAndInsideTheBundle() throws {
        let result = contents([
            makeEntry(inBundle("Frameworks/A.framework/Versions/Current/A"), uncompressedSize: 1),
            makeEntry(inBundle("Info.plist")),
            makeEntry(inBundle("_CodeSignature/CodeResources")),
        ])
        var stack: [BundlePath] = [.root]
        var visited = 0
        while let directory = stack.popLast() {
            for entry in result.entries(in: directory) ?? [] {
                visited += 1
                XCTAssertFalse(entry.path.isRoot)
                XCTAssertFalse(entry.path.rawValue.hasPrefix("/"))
                XCTAssertFalse(entry.path.rawValue.hasPrefix("Payload"))
                XCTAssertFalse(entry.path.components.contains(".."))
                XCTAssertTrue(entry.path.isWithin(.root))
                XCTAssertEqual(entry.path.parent, directory)
                if entry.isDirectory {
                    stack.append(entry.path)
                }
            }
        }
        XCTAssertEqual(visited, result.entryCount)
    }

    func testEntriesWithUnsafeNamesAreCountedNotListed() throws {
        let result = contents([
            makeEntry(inBundle("Info.plist")),
            makeRejectedEntry("Payload/Example.app/../../escape", uncompressedSize: 9),
            makeRejectedEntry("/Payload/Example.app/absolute", uncompressedSize: 9),
            makeRejectedEntry("Payload/Example.app/nul\0byte", uncompressedSize: 9),
        ])
        XCTAssertEqual(result.entryCount, 1)
        XCTAssertEqual(result.omittedEntryCount, 3)
        XCTAssertEqual(result.rootEntries.map(\.name), ["Info.plist"])
        XCTAssertEqual(result.totalDeclaredByteCount, 0)
    }

    func testDuplicateLocationsKeepTheFirstRecordedEntry() throws {
        let result = contents([
            makeEntry(inBundle("Info.plist"), uncompressedSize: 10),
            makeEntry(inBundle("Info.plist"), uncompressedSize: 99),
            makeEntry(inBundle("Frameworks/A.framework/A"), uncompressedSize: 1),
            makeEntry(inBundle("Frameworks"), kind: .directory),
        ])
        XCTAssertEqual(result.entryCount, 4)
        XCTAssertEqual(result.entry(at: try path("Info.plist"))?.declaredByteCount, 10)
        XCTAssertEqual(result.entry(at: try path("Frameworks"))?.kind, .directory)
        XCTAssertEqual(result.totalDeclaredByteCount, 11)
    }

    // MARK: - Kinds and metadata

    func testLinksAndUnsupportedEntriesAreListedWithTheirKindAndNotDescended() throws {
        let result = contents([
            makeEntry(inBundle("Info.plist"), uncompressedSize: 4),
            makeEntry(inBundle("Frameworks/Link"), kind: .symbolicLink, uncompressedSize: 12),
            makeEntry(inBundle("Frameworks/Device"), kind: .unsupported, uncompressedSize: 12),
        ])
        let link = try XCTUnwrap(result.entry(at: try path("Frameworks/Link")))
        XCTAssertEqual(link.kind, .symbolicLink)
        XCTAssertFalse(link.isDirectory)
        XCTAssertNil(link.declaredByteCount)
        XCTAssertNil(link.role)
        XCTAssertNil(result.entries(in: link.path))

        let unsupported = try XCTUnwrap(result.entry(at: try path("Frameworks/Device")))
        XCTAssertEqual(unsupported.kind, .unsupported)
        XCTAssertFalse(unsupported.isDirectory)
        XCTAssertNil(unsupported.declaredByteCount)
        XCTAssertNil(result.entries(in: unsupported.path))

        XCTAssertEqual(result.entries(in: try path("Frameworks"))?.map(\.name), ["Device", "Link"])
        XCTAssertEqual(result.totalDeclaredByteCount, 4)
    }

    func testDeclaredSizesAreCarriedForRegularFilesOnly() throws {
        let result = contents([
            makeEntry(inBundle("Info.plist"), uncompressedSize: 1_024, compressedSize: 512),
            makeEntry(inBundle("Frameworks"), kind: .directory, uncompressedSize: 4_096),
            makeEntry(inBundle("empty.txt"), uncompressedSize: 0),
        ])
        XCTAssertEqual(result.entry(at: try path("Info.plist"))?.declaredByteCount, 1_024)
        XCTAssertNil(result.entry(at: try path("Frameworks"))?.declaredByteCount)
        XCTAssertEqual(result.entry(at: try path("empty.txt"))?.declaredByteCount, 0)
        XCTAssertEqual(result.totalDeclaredByteCount, 1_024)
    }

    func testVeryLargeDeclaredSizesAreCarriedAndTheTotalSaturates() throws {
        let result = contents([
            makeEntry(inBundle("Huge.bin"), uncompressedSize: Int.max - 10),
            makeEntry(inBundle("Also.bin"), uncompressedSize: 5_000_000_000),
            makeEntry(inBundle("Info.plist"), uncompressedSize: 1),
        ])
        XCTAssertEqual(result.entry(at: try path("Huge.bin"))?.declaredByteCount, Int.max - 10)
        XCTAssertEqual(result.entry(at: try path("Also.bin"))?.declaredByteCount, 5_000_000_000)
        XCTAssertEqual(result.totalDeclaredByteCount, Int.max)
    }

    func testUnusualNamesAreCarriedVerbatim() throws {
        let longName = String(repeating: "n", count: 255)
        let result = contents([
            makeEntry(inBundle("Base Name.lproj/Ünïcødé 名前.strings")),
            makeEntry(inBundle(".hidden")),
            makeEntry(inBundle("trailing space ")),
            makeEntry(inBundle("emoji 📦.txt")),
            makeEntry(inBundle(longName)),
        ])
        XCTAssertEqual(
            result.rootEntries.map(\.name),
            ["Base Name.lproj", ".hidden", "emoji 📦.txt", longName, "trailing space "]
        )
        XCTAssertEqual(
            result.entries(in: try path("Base Name.lproj"))?.map(\.name),
            ["Ünïcødé 名前.strings"]
        )
    }

    // MARK: - Notable entries

    func testConventionalLocationsAreLabelled() throws {
        let result = contents([
            makeEntry(inBundle("Info.plist"), uncompressedSize: 1),
            makeEntry(inBundle("Example"), uncompressedSize: 2),
            makeEntry(inBundle("embedded.mobileprovision"), uncompressedSize: 3),
            makeEntry(inBundle("_CodeSignature"), kind: .directory),
            makeEntry(inBundle("_CodeSignature/CodeResources"), uncompressedSize: 4),
            makeEntry(inBundle("Frameworks"), kind: .directory),
            makeEntry(inBundle("PlugIns"), kind: .directory),
            makeEntry(inBundle("Extensions"), kind: .directory),
            makeEntry(inBundle("Assets.car"), uncompressedSize: 5),
        ], executable: "Example")

        XCTAssertEqual(
            result.notableEntries.map(\.path.rawValue),
            [
                "Info.plist",
                "Example",
                "embedded.mobileprovision",
                "_CodeSignature",
                "_CodeSignature/CodeResources",
                "Frameworks",
                "PlugIns",
                "Extensions",
            ]
        )
        XCTAssertEqual(
            result.notableEntries.map(\.role),
            [
                .bundleInformation,
                .executable,
                .embeddedProvisioningProfile,
                .codeSignatureDirectory,
                .codeResources,
                .frameworksDirectory,
                .plugInsDirectory,
                .extensionsDirectory,
            ]
        )
        XCTAssertNil(result.entry(at: try path("Assets.car"))?.role)
    }

    func testAbsentConventionalLocationsAreSimplyAbsent() throws {
        let result = contents([
            makeEntry(inBundle("Info.plist"), uncompressedSize: 1),
        ], executable: "Example")
        XCTAssertEqual(result.notableEntries.map(\.role), [.bundleInformation])
        XCTAssertNil(result.entry(at: try path("embedded.mobileprovision")))
        XCTAssertNil(result.entry(at: try path("_CodeSignature")))
        XCTAssertNil(result.entry(at: try path("Example")))
    }

    func testTheExecutableIsLabelledFromTheDeclaredNameOnly() throws {
        let table = [
            makeEntry(inBundle("Info.plist"), uncompressedSize: 1),
            makeEntry(inBundle("Example"), uncompressedSize: 2),
        ]
        XCTAssertEqual(contents(table, executable: "Example").entry(at: try path("Example"))?.role, .executable)
        XCTAssertNil(contents(table, executable: nil).entry(at: try path("Example"))?.role)
        XCTAssertNil(contents(table, executable: "Other").entry(at: try path("Example"))?.role)
        XCTAssertNil(contents(table, executable: "").entry(at: try path("Example"))?.role)
    }

    func testLabelsRequireTheConventionalDepthAndKind() throws {
        let result = contents([
            makeEntry(inBundle("Frameworks/A.framework/Info.plist"), uncompressedSize: 1),
            makeEntry(inBundle("Frameworks/A.framework/_CodeSignature"), kind: .directory),
            makeEntry(inBundle("Frameworks/A.framework/_CodeSignature/CodeResources")),
            makeEntry(inBundle("Extras/W.appex/embedded.mobileprovision")),
            makeEntry(inBundle("Info.plist"), kind: .directory),
            makeEntry(inBundle("info.plist"), uncompressedSize: 1),
            makeEntry(inBundle("Frameworks"), kind: .regularFile, uncompressedSize: 1),
            makeEntry(inBundle("embedded.mobileprovision"), kind: .symbolicLink),
            makeEntry(inBundle("CodeResources")),
        ], executable: "Example")

        XCTAssertEqual(result.notableEntries, [])
        XCTAssertNil(result.entry(at: try path("Frameworks/A.framework/Info.plist"))?.role)
        XCTAssertNil(result.entry(at: try path("Info.plist"))?.role)
        XCTAssertNil(result.entry(at: try path("info.plist"))?.role)
        XCTAssertNil(result.entry(at: try path("Frameworks"))?.role)
        XCTAssertNil(result.entry(at: try path("embedded.mobileprovision"))?.role)
        XCTAssertNil(result.entry(at: try path("CodeResources"))?.role)
        XCTAssertNil(result.entry(at: try path("Extras/W.appex/embedded.mobileprovision"))?.role)
    }

    func testValueEqualityAndHashingFollowContent() {
        let table = validPackageEntryTable()
        let first = contents(table, executable: "Example")
        let second = contents(table, executable: "Example")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.hashValue, second.hashValue)
        XCTAssertNotEqual(first, contents(table, executable: nil))
    }
}

/// A small deterministic generator, so a shuffled table is the same shuffle
/// on every run.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
