import Foundation
import XCTest
@testable import ZynSign

/// Resource sealing and the CodeResources document: deterministic hashing and
/// ordering, symlink and exclusion policy, bounds, nested-code seals, plist
/// serialization and parsing, and the digest destined for CodeDirectory
/// special slot 3.
///
/// The resource and document digest expectations were computed independently
/// on a host over the documented canonical form and are recorded as literals.
final class CodeResourcesTests: XCTestCase {

    private let digest = CryptoKitMessageDigest()
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zynsign-coderesources-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if temporaryDirectory != nil {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    private func path(_ rawValue: String) throws -> BundlePath {
        try XCTUnwrap(BundlePath(rawValue: rawValue), "Test path must be a valid bundle path")
    }

    private func sha256(_ data: Data) throws -> Data {
        try digest.digest(data, algorithm: .sha256).bytes
    }

    private func dataFromHex(_ text: String) -> Data {
        let characters = Array(text.filter { !$0.isWhitespace })
        var bytes = Data()
        for offset in stride(from: 0, to: characters.count, by: 2) {
            guard offset + 1 < characters.count,
                  let byte = UInt8(String(characters[offset...offset + 1]), radix: 16) else {
                continue
            }
            bytes.append(byte)
        }
        return bytes
    }

    /// A store whose listing is fully scripted, so listing order, directory
    /// entries, and duplicate listings can be exercised deterministically.
    private final class ScriptedResourceStore: ResourceContentStore {
        let listing: [ResourceListingEntry]
        let files: [BundlePath: Data]
        private(set) var readPaths: [BundlePath] = []

        init(listing: [ResourceListingEntry], files: [BundlePath: Data]) {
            self.listing = listing
            self.files = files
        }

        func listEntries() throws -> [ResourceListingEntry] { listing }

        func readResource(at path: BundlePath) throws -> Data {
            readPaths.append(path)
            guard let data = files[path] else {
                throw ResourceSealError.resourceUnavailable(path)
            }
            return data
        }
    }

    // MARK: - Deterministic resource hashing (independently computed vectors)

    func testResourceDigestsMatchIndependentVectors() throws {
        let alpha = try path("a.txt")
        let binary = try path("nested/deep/b.bin")
        let hidden = try path(".hidden")
        let unicode = try path("unicode-😀.txt")
        let store = MemoryResourceContentStore(files: [
            alpha: Data("alpha\n".utf8),
            binary: Data(repeating: 0xFF, count: 10),
            hidden: Data("h".utf8),
            unicode: Data("hello 😀".utf8),
        ])
        let document = try CodeResourcesGenerator(messageDigest: digest)
            .generate(from: store)

        let byPath: [String: FileResourceSeal] = {
            var map: [String: FileResourceSeal] = [:]
            for case .file(let seal) in document.files2 { map[seal.path.rawValue] = seal }
            return map
        }()
        XCTAssertEqual(byPath["a.txt"]?.hash2,
                       dataFromHex("b6a98d9ce9a2d9149288fa3df42d377c3e42737afdcdaf714e33c0a100b51060"))
        XCTAssertEqual(byPath["nested/deep/b.bin"]?.hash2,
                       dataFromHex("0083af118d18a63c6bb552f21d0c4ee78741f988ecd319d3cd06cb6c85a68a63"))
        XCTAssertEqual(byPath[".hidden"]?.hash2,
                       dataFromHex("aaa9402664f1a41f40ebbc52c9993eb66aeb366602958fdfaa283b71e64db123"))
        XCTAssertEqual(byPath["unicode-😀.txt"]?.hash2,
                       dataFromHex("701734ab010f0b6dbb1cd1ce3c474b226d1abff267affc16c2bfd6ba1bb52396"))
    }

    func testDocumentOrderIsAscendingPathBytesRegardlessOfListingOrder() throws {
        let alpha = try path("a.txt")
        let binary = try path("nested/deep/b.bin")
        let store = MemoryResourceContentStore(files: [
            binary: Data([0x00]),
            alpha: Data([0x01]),
        ])
        let document = try CodeResourcesGenerator(messageDigest: digest)
            .generate(from: store)
        XCTAssertEqual(document.files2.map(\.path.rawValue), ["a.txt", "nested/deep/b.bin"])

        // The same tree listed in the opposite order yields the same document
        // bytes, because the generator imposes its own order.
        let reversedStore = ScriptedResourceStore(
            listing: [
                ResourceListingEntry(path: binary, kind: .file, byteCount: 1),
                ResourceListingEntry(path: alpha, kind: .file, byteCount: 1),
            ],
            files: [binary: Data([0x00]), alpha: Data([0x01])]
        )
        let reversedDocument = try CodeResourcesGenerator(messageDigest: digest)
            .generate(from: reversedStore)
        XCTAssertEqual(try document.serialized(), try reversedDocument.serialized())
    }

    // MARK: - Policy

    func testDirectoriesAreStructuralAndNeverRead() throws {
        let file = try path("a.txt")
        let store = ScriptedResourceStore(
            listing: [
                ResourceListingEntry(path: try path("nested"), kind: .directory),
                ResourceListingEntry(path: file, kind: .file, byteCount: 1),
            ],
            files: [file: Data([0x00])]
        )
        let document = try CodeResourcesGenerator(messageDigest: digest)
            .generate(from: store)
        XCTAssertEqual(document.files2.count, 1)
        XCTAssertEqual(store.readPaths, [file])
    }

    func testExcludedPathsAreOmittedAndNeverRead() throws {
        let keep = try path("keep.txt")
        let drop = try path("secret.txt")
        let store = ScriptedResourceStore(
            listing: [
                ResourceListingEntry(path: keep, kind: .file, byteCount: 1),
                ResourceListingEntry(path: drop, kind: .file, byteCount: 1),
            ],
            files: [keep: Data([0x00]), drop: Data([0xFF])]
        )
        let document = try CodeResourcesGenerator(messageDigest: digest)
            .generate(
                from: store,
                configuration: ResourceSealingConfiguration(excludedPaths: [drop])
            )
        XCTAssertEqual(document.files2.map(\.path.rawValue), ["keep.txt"])
        XCTAssertEqual(document.omitted, [OmittedResource(path: drop, reason: .excludedByConfiguration)])
        XCTAssertEqual(store.readPaths, [keep])

        // Omissions are provenance, never serialized into the document.
        let parsed = try CodeResourcesParser.parse(try document.serialized())
        XCTAssertTrue(parsed.omitted.isEmpty)
        XCTAssertFalse(String(decoding: try document.serialized(), as: UTF8.self).contains("secret.txt"))
    }

    func testSymlinkPolicyFailsClosedByDefaultAndExcludesOnRequest() throws {
        let file = try path("a.txt")
        let link = try path("link")
        let store = MemoryResourceContentStore(files: [file: Data([0x00])], symbolicLinks: [link])

        // Default: fail closed.
        XCTAssertThrowsError(
            try CodeResourcesGenerator(messageDigest: digest).generate(from: store)
        ) { error in
            XCTAssertEqual(error as? ResourceSealError, .symbolicLinkRejected(link))
        }

        // Explicit exclusion: recorded, never followed, never hashed.
        let document = try CodeResourcesGenerator(messageDigest: digest)
            .generate(
                from: store,
                configuration: ResourceSealingConfiguration(symlinkPolicy: .exclude)
            )
        XCTAssertEqual(document.files2.map(\.path.rawValue), ["a.txt"])
        XCTAssertEqual(document.omitted, [OmittedResource(path: link, reason: .symbolicLinkExcluded)])
    }

    func testBoundsAreEnforced() throws {
        let first = try path("a.txt")
        let second = try path("b.txt")

        // Resource count.
        let countBound = ResourceSealingConfiguration(
            limits: ResourceSealingLimits(
                maximumResourceCount: 1,
                maximumResourceByteCount: 16,
                maximumTotalSealedByteCount: 16
            )
        )
        XCTAssertThrowsError(
            try CodeResourcesGenerator(messageDigest: digest)
                .generate(from: MemoryResourceContentStore(files: [first: Data([0]), second: Data([0])]),
                          configuration: countBound)
        ) { error in
            XCTAssertEqual(error as? ResourceSealError, .resourceCountExceeded)
        }

        // Per-resource size (declared up front).
        let sizeBound = ResourceSealingConfiguration(
            limits: ResourceSealingLimits(
                maximumResourceCount: 10,
                maximumResourceByteCount: 2,
                maximumTotalSealedByteCount: 16
            )
        )
        XCTAssertThrowsError(
            try CodeResourcesGenerator(messageDigest: digest)
                .generate(from: MemoryResourceContentStore(files: [first: Data([0, 1, 2])]),
                          configuration: sizeBound)
        ) { error in
            XCTAssertEqual(error as? ResourceSealError, .resourceTooLarge(first))
        }

        // Cumulative size.
        let totalBound = ResourceSealingConfiguration(
            limits: ResourceSealingLimits(
                maximumResourceCount: 10,
                maximumResourceByteCount: 4,
                maximumTotalSealedByteCount: 3
            )
        )
        XCTAssertThrowsError(
            try CodeResourcesGenerator(messageDigest: digest)
                .generate(from: MemoryResourceContentStore(files: [first: Data([0, 1]), second: Data([2, 3])]),
                          configuration: totalBound)
        ) { error in
            XCTAssertEqual(error as? ResourceSealError, .totalSealedBytesExceeded)
        }

        // Duplicate listings are refused, not merged.
        let duplicateStore = ScriptedResourceStore(
            listing: [
                ResourceListingEntry(path: first, kind: .file, byteCount: 1),
                ResourceListingEntry(path: first, kind: .file, byteCount: 1),
            ],
            files: [first: Data([0x00])]
        )
        XCTAssertThrowsError(
            try CodeResourcesGenerator(messageDigest: digest).generate(from: duplicateStore)
        ) { error in
            XCTAssertEqual(error as? ResourceSealError, .duplicateResourcePath(first))
        }
    }

    // MARK: - Nested code

    func testNestedCodeSealsAreCallerSuppliedAndCollisionChecked() throws {
        let file = try path("Resources/img.png")
        let nested = try path("PlugIns/Ext.appex/Ext")
        // The nested binary's code-directory digest: SHA-256 over a 32-byte
        // code directory blob. The seal keeps its first 20 bytes.
        let fakeCodeDirectory = Data((0..<32).map(UInt8.init))
        let codeDirectoryDigest = try digest.digest(fakeCodeDirectory, algorithm: .sha256)
        let expectedCodeDirectoryHash = codeDirectoryDigest.bytes.prefix(20)

        let store = MemoryResourceContentStore(files: [file: Data("icon-png-bytes\u{00}\u{01}".utf8)])
        let seal = try NestedCodeResourceSeal(path: nested, codeDirectoryDigest: codeDirectoryDigest)
        // The documented cdhash form, independently computed on a host.
        XCTAssertEqual(seal.codeDirectoryHash, expectedCodeDirectoryHash)
        XCTAssertEqual(seal.codeDirectoryHash.base64EncodedString(), "Yw3NKWbEM2aRElRIu7JbT/QSpJw=")
        let document = try CodeResourcesGenerator(messageDigest: digest)
            .generate(from: store, nestedCode: [seal])

        XCTAssertEqual(document.files2.count, 2)
        guard case .nestedCode(let nestedSeal)? = document.files2.first(where: { $0.path == nested }) else {
            return XCTFail("Expected the nested-code entry to be present")
        }
        XCTAssertEqual(nestedSeal.path, nested)
        XCTAssertEqual(nestedSeal.codeDirectoryHash, expectedCodeDirectoryHash)

        // A nested seal colliding with a sealed file is refused.
        XCTAssertThrowsError(
            try CodeResourcesGenerator(messageDigest: digest)
                .generate(from: store, nestedCode: [
                    try NestedCodeResourceSeal(path: file, codeDirectoryDigest: codeDirectoryDigest)
                ])
        ) { error in
            XCTAssertEqual(error as? ResourceSealError, .duplicateResourcePath(file))
        }

        // A 32-byte cdhash is not the documented 20-byte form.
        XCTAssertThrowsError(
            try NestedCodeResourceSeal(
                path: nested,
                codeDirectoryHash: Data(repeating: 0x01, count: 32)
            )
        ) { error in
            XCTAssertEqual(error as? CodeResourcesError, .invalidHashLength(path: nested.rawValue, expected: 20, actual: 32))
        }
    }

    // MARK: - Serialization (independently computed vectors)

    func testCodeResourcesDigestMatchesIndependentVector() throws {
        let iconPath = try path("Assets/icon.png")
        let iconHash = try sha256(Data("icon-png-bytes\u{00}\u{01}".utf8))
        let iconDigest = try XCTUnwrap(Digest(algorithm: .sha256, bytes: iconHash))
        XCTAssertEqual(iconDigest.hexString, "5c4594f09338e9b9aa9fed75eaa29b18bc6b8229a760ee4a943478f0034fa206")
        let document = try CodeResourcesDocument(files2: [
            .file(try FileResourceSeal(path: iconPath, hash2: iconHash))
        ])

        let bytes = try document.serialized()
        XCTAssertEqual(try digest.digest(bytes, algorithm: .sha256).hexString,
                       "371ce8e39d430a0e35a3b24a3e6b818f12c8674579065dbd52a7abf197e4bef8")

        // The same digest is what SealedCodeResources pins for slot 3.
        let sealed = try SealedCodeResources(document: document)
        XCTAssertEqual(sealed.bytes, bytes)
    }

    func testNestedCodeDocumentDigestMatchesIndependentVector() throws {
        let iconPath = try path("Assets/icon.png")
        let nestedPath = try path("PlugIns/Ext.appex/Ext")
        let iconHash = try sha256(Data("icon-png-bytes\u{00}\u{01}".utf8))
        let codeDirectoryHash = try digest
            .digest(Data((0..<32).map(UInt8.init)), algorithm: .sha256)
            .bytes.prefix(20)
        let document = try CodeResourcesDocument(files2: [
            .file(try FileResourceSeal(path: iconPath, hash2: iconHash)),
            .nestedCode(try NestedCodeResourceSeal(
                path: nestedPath,
                codeDirectoryHash: codeDirectoryHash
            )),
        ])
        let bytes = try document.serialized()
        XCTAssertEqual(try digest.digest(bytes, algorithm: .sha256).hexString,
                       "50ecb4c77ea11d704afea778240203c04c501dd2a4b403dad27e1d58db1f2650")
    }

    // MARK: - Round trip

    func testTreeToDocumentToBytesToParsedDocument() throws {
        let iconPath = try path("Assets/icon.png")
        let textPath = try path("notes/readme.txt")
        let store = MemoryResourceContentStore(files: [
            iconPath: Data("icon-png-bytes\u{00}\u{01}".utf8),
            textPath: Data("alpha\n".utf8),
        ])
        let nestedSeal = try NestedCodeResourceSeal(
            path: try path("PlugIns/Ext.appex/Ext"),
            codeDirectoryHash: Data((0..<20).map(UInt8.init))
        )
        let generator = CodeResourcesGenerator(messageDigest: digest)
        let document = try generator.generate(from: store, nestedCode: [nestedSeal])

        let bytes = try document.serialized()
        let parsed = try CodeResourcesParser.parse(bytes)

        XCTAssertEqual(parsed.files2, document.files2)
        XCTAssertNil(parsed.rules2)
        // Re-serializing the parsed document reproduces the exact bytes:
        // the representation is faithful, not merely similar.
        XCTAssertEqual(try parsed.serialized(), bytes)
    }

    func testCallerSuppliedRulesRoundTrip() throws {
        let file = try path("a.txt")
        let document = try CodeResourcesDocument(
            files2: [.file(try FileResourceSeal(path: file, hash2: Data(repeating: 0x07, count: 32)))],
            rules2: [
                try CodeResourcesRule(pattern: "^Resources/", optional: true),
                try CodeResourcesRule(pattern: "^Embedded.provisionprofile$", weight: 1000),
            ]
        )
        let parsed = try CodeResourcesParser.parse(try document.serialized())
        XCTAssertEqual(parsed.rules2, document.rules2)
        XCTAssertEqual(try parsed.serialized(), try document.serialized())
    }

    // MARK: - Parser refusals

    private func codeResourcesXML(_ body: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        \(body)
        </plist>
        """.utf8)
    }

    func testParserRefusesUnsupportedAndMalformedDocuments() throws {
        XCTAssertThrowsError(try CodeResourcesParser.parse(Data())) {
            XCTAssertEqual($0 as? CodeResourcesError, .emptyInput)
        }
        XCTAssertThrowsError(try CodeResourcesParser.parse(Data("not a plist".utf8))) {
            XCTAssertEqual($0 as? CodeResourcesError, .malformedPlist)
        }
        XCTAssertThrowsError(
            try CodeResourcesParser.parse(codeResourcesXML("<array>\n<string>x</string>\n</array>"))
        ) { error in
            XCTAssertEqual(error as? CodeResourcesError, .malformedPlist)
        }

        // The v1 dictionaries are an explicit unsupported subset.
        XCTAssertThrowsError(
            try CodeResourcesParser.parse(codeResourcesXML("""
            <dict>
            \t<key>files</key>
            \t<dict/>
            </dict>
            """))
        ) { error in
            XCTAssertEqual(error as? CodeResourcesError, .unsupportedTopLevelKey("files"))
        }

        XCTAssertThrowsError(
            try CodeResourcesParser.parse(codeResourcesXML("<dict>\n\t<key>rules2</key>\n\t<dict/>\n</dict>"))
        ) { error in
            XCTAssertEqual(error as? CodeResourcesError, .missingFiles2)
        }

        // Entry with an unknown structure key.
        XCTAssertThrowsError(
            try CodeResourcesParser.parse(codeResourcesXML("""
            <dict>
            \t<key>files2</key>
            \t<dict>
            \t\t<key>a.txt</key>
            \t\t<dict>
            \t\t\t<key>symlink</key>
            \t\t\t<true/>
            \t\t</dict>
            \t</dict>
            </dict>
            """))
        ) { error in
            XCTAssertEqual(error as? CodeResourcesError, .invalidEntryStructure(path: "a.txt"))
        }

        // hash2 of the wrong length.
        XCTAssertThrowsError(
            try CodeResourcesParser.parse(codeResourcesXML("""
            <dict>
            \t<key>files2</key>
            \t<dict>
            \t\t<key>a.txt</key>
            \t\t<dict>
            \t\t\t<key>hash2</key>
            \t\t\t<data>AAAA</data>
            \t\t</dict>
            \t</dict>
            </dict>
            """))
        ) { error in
            XCTAssertEqual(error as? CodeResourcesError, .invalidEntryStructure(path: "a.txt"))
        }

        // A path that cannot be bundle-relative is refused, never laundered.
        XCTAssertThrowsError(
            try CodeResourcesParser.parse(codeResourcesXML("""
            <dict>
            \t<key>files2</key>
            \t<dict>
            \t\t<key>../escape.txt</key>
            \t\t<dict>
            \t\t\t<key>cdhash</key>
            \t\t\t<data>AAAAAAAAAAAAAAAAAAAAAA==</data>
            \t\t</dict>
            \t</dict>
            </dict>
            """))
        ) { error in
            XCTAssertEqual(error as? CodeResourcesError, .invalidPath("../escape.txt"))
        }

        // A binary-plist form of the same structure parses: reading accepts
        // any legal spelling, canonicalization governs writing.
        let binary = try PropertyListSerialization.data(
            fromPropertyList: ["files2": ["a.txt": ["cdhash": Data(repeating: 0, count: 20)]]],
            format: .binary,
            options: 0
        )
        let parsed = try CodeResourcesParser.parse(binary)
        XCTAssertEqual(parsed.files2.count, 1)
    }

    func testSealedCodeResourcesBounds() throws {
        XCTAssertThrowsError(try SealedCodeResources(bytes: Data())) { error in
            XCTAssertEqual(error as? CodeResourcesError, .emptyInput)
        }
        XCTAssertThrowsError(
            try SealedCodeResources(bytes: Data(repeating: 0x41, count: SealedCodeResources.maximumByteCount + 1))
        ) { error in
            XCTAssertEqual(error as? CodeResourcesError, .inputTooLarge)
        }
    }

    // MARK: - Filesystem store

    func testDirectoryStoreSealsATreeDeterministically() throws {
        let root = temporaryDirectory!
        try Data("alpha\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data(repeating: 0xFF, count: 10)
            .write(to: root.appendingPathComponent("nested").appendingPathComponent("b.bin"))

        let store = DirectoryResourceContentStore(bundleURL: root)
        let document = try CodeResourcesGenerator(messageDigest: digest).generate(from: store)
        XCTAssertEqual(document.files2.map(\.path.rawValue), ["a.txt", "nested/b.bin"])
        XCTAssertEqual(document.omitted, [])
        for case .file(let seal) in document.files2 {
            let stored = try Data(contentsOf: root.appendingPathComponent(seal.path.rawValue))
            XCTAssertEqual(seal.hash2, try sha256(stored))
        }
    }

    func testDirectoryStoreSymlinkPolicy() throws {
        let root = temporaryDirectory!
        let linkPath = try path("link")
        try Data("alpha\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("link").path,
            withDestinationPath: root.appendingPathComponent("a.txt").path
        )

        let store = DirectoryResourceContentStore(bundleURL: root)
        XCTAssertThrowsError(
            try CodeResourcesGenerator(messageDigest: digest).generate(from: store)
        ) { error in
            XCTAssertEqual(error as? ResourceSealError, .symbolicLinkRejected(linkPath))
        }
        let document = try CodeResourcesGenerator(messageDigest: digest)
            .generate(
                from: store,
                configuration: ResourceSealingConfiguration(symlinkPolicy: .exclude)
            )
        XCTAssertEqual(document.files2.map(\.path.rawValue), ["a.txt"])
        XCTAssertEqual(document.omitted.map(\.path.rawValue), ["link"])
    }

    func testBundlePathRejectsTraversalBeforeAnyStoreSeesIt() {
        // The resource-sealing boundary never receives an unrepresentable
        // path: BundlePath refuses it first.
        XCTAssertNil(BundlePath(rawValue: "../escape.txt"))
        XCTAssertNil(BundlePath(rawValue: "/absolute.txt"))
        XCTAssertNil(BundlePath(rawValue: "a/../../escape.txt"))
        XCTAssertNil(BundlePath(components: ["Frameworks", ".."]))
    }
}
