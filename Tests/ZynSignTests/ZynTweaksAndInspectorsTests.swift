import Foundation
import XCTest
@testable import ZynSign

final class ZynTweaksAndInspectorsTests: XCTestCase {

    func testTweakMachOAnalyzerDetectsCydiaSubstrateAndRecommendsRewrite() {
        var bytes = Data(count: 2048)
        func put32(_ o: Int, _ v: UInt32) {
            bytes[o] = UInt8(v & 0xFF)
            bytes[o + 1] = UInt8((v >> 8) & 0xFF)
            bytes[o + 2] = UInt8((v >> 16) & 0xFF)
            bytes[o + 3] = UInt8((v >> 24) & 0xFF)
        }
        put32(0, 0xFEED_FACF)
        put32(4, 0x0100_000C)
        put32(8, 0)
        put32(12, 0x6) // MH_DYLIB
        let dep = Array("/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate".utf8) + [0]
        let cmdSize = (24 + dep.count + 7) & ~7
        put32(16, 1)
        put32(20, UInt32(cmdSize))
        put32(32, 0x0C)
        put32(36, UInt32(cmdSize))
        put32(40, 24)
        for (i, b) in dep.enumerated() { bytes[32 + 24 + i] = b }

        let report = TweakMachOAnalyzer.analyze(bytes)
        XCTAssertTrue(report.isValidMachO)
        XCTAssertEqual(report.hookingRuntime, .cydiaSubstrate)
        XCTAssertTrue(report.recommendation.replaceSubstrateWithElleKit)
    }

    func testAutoInjectRuleMatchesExactAndWildcardPatterns() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zynsign-autoinject-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = FileTweakAutoInjectStore(location: dir.appendingPathComponent("rules.json"))
        let tweakID = UUID()
        let rule = TweakAutoInjectRule(
            tweakID: tweakID,
            scope: .matchingBundleIDs,
            targetBundleIdentifiers: ["com.example.alpha", "io.zynsign.*"],
            excludedBundleIdentifiers: ["io.zynsign.blocked"]
        )
        try store.saveRule(rule)

        let reloaded = try store.allRules()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertTrue(reloaded[0].matches(bundleIdentifier: "com.example.alpha"))
        XCTAssertTrue(reloaded[0].matches(bundleIdentifier: "io.zynsign.studio"))
        XCTAssertFalse(reloaded[0].matches(bundleIdentifier: "io.zynsign.blocked"))
        XCTAssertFalse(reloaded[0].matches(bundleIdentifier: "org.other.app"))
    }

    func testBoundedDebDeflateRejectsOversizedAndTruncatedStreams() throws {
        let small = try XCTUnwrap(Data(base64Encoded: "80jNyclXSMovzUtJTVFISU3OT0ktAgA="))
        XCTAssertEqual(try BoundedDebTarDecoder.decode(small, kind: .deflate, limit: 21), Data("Hello bounded decoder".utf8))
        XCTAssertThrowsError(try BoundedDebTarDecoder.decode(small, kind: .deflate, limit: 20))
        XCTAssertThrowsError(try BoundedDebTarDecoder.decode(Data(small.dropLast()), kind: .deflate, limit: 100))
        let bomb = try XCTUnwrap(Data(base64Encoded: "7cEBDQAAAMKgbO9fyhxuQAEAAAAAAAAA7wY="))
        XCTAssertThrowsError(try BoundedDebTarDecoder.decode(bomb, kind: .deflate, limit: 1024)) { error in
            XCTAssertEqual(error as? DebArchiveParser.DebError, .archiveTooLarge(limit: 1024))
        }
    }

    func testDebArchiveUsesBoundedGzipDecoderAndChecksTrailer() throws {
        let encoded = "H4sIAAAAAAACA+3NMQrCQBQE0H8UT5BkYYO1mtJLJGgRUIRVi9zexUqsRRDfa2aYZpp2P09lLEs7HM+X5rCc5ik+rKvWff/M6j2r/NLrnlJOOVZdfMH9ehtLvY//tNnuhgAAAAAAAAAAAODnPABH6wD8ACgAAA=="
        let gzip = try XCTUnwrap(Data(base64Encoded: encoded))
        let archive = Self.makeArArchive(entries: [("data.tar.gz", gzip)])
        XCTAssertEqual(try DebArchiveReader.unpack(archive).payloads.first?.bytes, Data("ABCD".utf8))
        var damaged = gzip
        damaged[damaged.count - 8] ^= 1
        XCTAssertThrowsError(try DebArchiveReader.unpack(Self.makeArArchive(entries: [("data.tar.gz", damaged)])))
        XCTAssertThrowsError(try DebArchiveParser.unpack(archive), "Compressed members require a bounded decoder")
    }

    func testDebArchiveParserUnpacksUncompressedDataTarPayload() throws {
        let tarPayload = Self.makeSingleFileUSTar(
            path: "./Library/MobileSubstrate/DynamicLibraries/DemoTweak.dylib",
            content: Data([0xCF, 0xFA, 0xED, 0xFE, 1, 2, 3, 4])
        )
        let debBytes = Self.makeArArchive(entries: [
            ("debian-binary", Data("2.0\n".utf8)),
            ("data.tar", tarPayload)
        ])

        let unpacked = try DebArchiveParser.unpack(debBytes)
        XCTAssertEqual(unpacked.payloads.count, 1)
        XCTAssertEqual(unpacked.payloads.first?.kind, .dylib)
        XCTAssertEqual(unpacked.payloads.first?.topLevelName, "DemoTweak.dylib")
    }

    func testDebRejectsMalformedTarInsteadOfReturningPartialPayloads() throws {
        let valid = Self.makeSingleFileUSTar(path: "./Library/Demo.dylib", content: Data([1]))
        var corrupt = valid
        corrupt[0] ^= 1 // invalidates the header checksum
        let incomplete = Data(valid.dropLast(1024))
        let unsafe = Self.makeSingleFileUSTar(path: "../../Demo.dylib", content: Data([1]))
        for tar in [corrupt, incomplete, unsafe] {
            let archive = Self.makeArArchive(entries: [("data.tar", tar)])
            XCTAssertThrowsError(try DebArchiveParser.unpack(archive))
        }
    }

    func testDebRejectsCollidingFlattenedPayloadsAndDuplicateDataMembers() throws {
        let first = Self.makeSingleFileUSTar(path: "./one/Demo.dylib", content: Data([1]))
        let second = Self.makeSingleFileUSTar(path: "./two/demo.dylib", content: Data([2]))
        var combined = Data(first.dropLast(1024))
        combined.append(second)
        let collision = Self.makeArArchive(entries: [("data.tar", combined)])
        XCTAssertThrowsError(try DebArchiveParser.unpack(collision)) { error in
            XCTAssertEqual(error as? DebArchiveParser.DebError, .duplicatePayload)
        }
        let duplicate = Self.makeArArchive(entries: [("data.tar", first), ("data.tar", second)])
        XCTAssertThrowsError(try DebArchiveParser.unpack(duplicate))
        var trailing = Self.makeArArchive(entries: [("data.tar", first)])
        trailing.append(0)
        XCTAssertThrowsError(try DebArchiveParser.unpack(trailing))
    }

    func testFailedArchiveExtractionDoesNotLeaveDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("bad.deb")
        try Data("not a deb".utf8).write(to: archive)
        do {
            _ = try await FileArchiveTools.extractArchive(at: archive, in: root)
            XCTFail("Malformed archive should fail")
        } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["bad.deb"])
    }

    private static func makeArArchive(entries: [(String, Data)]) -> Data {
        var out = Data("!<arch>\n".utf8)
        for (name, body) in entries {
            let paddedName = name.padding(toLength: 16, withPad: " ", startingAt: 0)
            let timestamp = "0".padding(toLength: 12, withPad: " ", startingAt: 0)
            let uid = "0".padding(toLength: 6, withPad: " ", startingAt: 0)
            let gid = "0".padding(toLength: 6, withPad: " ", startingAt: 0)
            let mode = "100644".padding(toLength: 8, withPad: " ", startingAt: 0)
            let size = "\(body.count)".padding(toLength: 10, withPad: " ", startingAt: 0)
            let header = "\(paddedName)\(timestamp)\(uid)\(gid)\(mode)\(size)`\n"
            out.append(Data(header.utf8))
            out.append(body)
            if body.count % 2 != 0 { out.append(0x0A) }
        }
        return out
    }

    private static func makeSingleFileUSTar(path: String, content: Data) -> Data {
        var header = Data(count: 512)
        for (i, b) in path.utf8.prefix(100).enumerated() { header[i] = b }
        for (i, b) in "0000644\0".utf8.enumerated() { header[100 + i] = b }
        let octalSize = String(content.count, radix: 8)
        let padCount = max(0, 11 - octalSize.count)
        let sizeField = String(repeating: "0", count: padCount) + octalSize + "\0"
        for (i, b) in sizeField.utf8.enumerated() { header[124 + i] = b }
        header[156] = UInt8(ascii: "0")
        for i in 148..<156 { header[i] = 0x20 }
        let sum = header.reduce(0) { $0 + Int($1) }
        let sumOctal = String(sum, radix: 8)
        let sumField = String(repeating: "0", count: max(0, 6 - sumOctal.count)) + sumOctal + "\0 "
        for (i, b) in sumField.utf8.prefix(8).enumerated() { header[148 + i] = b }

        var archive = header
        archive.append(content)
        let remainder = content.count % 512
        if remainder != 0 {
            archive.append(Data(count: 512 - remainder))
        }
        archive.append(Data(count: 1024))
        return archive
    }
}
