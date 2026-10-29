import Foundation
import XCTest
@testable import ZynSign

/// Taking a universal container apart and putting it back together is the only
/// way a fat binary can be re-signed: the format is a table of offsets, so a
/// byte inserted into one slice moves every later slice. These tests hold the
/// split/rebuild pair to what the rest of the pipeline needs — the container
/// survives a round trip, the table keeps saying the truth, and every way a
/// table can lie is refused instead of repaired.
final class MachOUniversalFileTests: XCTestCase {

    private func data(_ bytes: [UInt8]) -> Data { Data(bytes) }

    private func thin(_ fill: UInt8, commandSize: Int = 0) -> [UInt8] {
        MachOFixtures.thin(
            commands: commandSize == 0 ? [] : [MachOFixtures.command(0x28, size: commandSize)],
            payload: [UInt8](repeating: fill, count: 48)
        )
    }

    // MARK: - Round trip

    func testTheSplitRebuildRoundTripIsByteIdentical() throws {
        let container = data(MachOFixtures.fat([
            (cpu: MachOFixtures.arm64, subtype: 0, bytes: thin(0xA1)),
            (cpu: MachOFixtures.x86_64, subtype: 3, bytes: thin(0xB2))
        ]))
        let split = try MachOUniversalFile.split(container)
        XCTAssertEqual(split.slices.count, 2)
        XCTAssertEqual(try split.rebuild(), container)
    }

    func testSixtyFourBitRecordsRoundTrip() throws {
        let container = data(MachOFixtures.fat([
            (cpu: MachOFixtures.arm64, subtype: 2, bytes: thin(0xA1)),
            (cpu: MachOFixtures.x86_64, subtype: 3, bytes: thin(0xB2))
        ], magic: .fat64, alignmentExponent: 12))
        let split = try MachOUniversalFile.split(container)
        XCTAssertTrue(split.usesWideRecords)
        XCTAssertEqual(split.slices.first?.cpuSubtype, 2)
        XCTAssertEqual(split.slices.first?.alignmentExponent, 12)
        XCTAssertEqual(try split.rebuild(), container)
    }

    func testEachDeclaredArchitectureAndAlignmentSurvivesTheSplit() throws {
        let container = data(MachOFixtures.fat([
            (cpu: MachOFixtures.x86_64, subtype: 3, bytes: thin(0xA1)),
            (cpu: MachOFixtures.arm64, subtype: 1, bytes: thin(0xB2))
        ], alignmentExponent: 12))
        let split = try MachOUniversalFile.split(container)
        XCTAssertEqual(split.slices.map(\.cpu), [.x86_64, .arm64])
        XCTAssertEqual(split.slices.map(\.alignmentExponent), [12, 12])
        // A rebuild places each slice on the boundary its own exponent allows.
        let rebuilt = try split.rebuild()
        let reparsed = try MachOUniversalFile.split(rebuilt)
        XCTAssertEqual(reparsed.slices.map(\.bytes), split.slices.map(\.bytes))
    }

    // MARK: - Refusals

    func testAThinImageIsNotAContainer() {
        XCTAssertThrowsError(try MachOUniversalFile.split(data(thin(0x11)))) { error in
            XCTAssertEqual(error as? MachOUniversalFile.Failure, .notAUniversalContainer)
        }
    }

    func testAContainerWithoutSlicesIsMalformed() {
        var bytes = MachOFixtures.number(UInt64(0xCAFE_BABE), width: 4, order: .bigEndian)
        bytes += MachOFixtures.number(0, width: 4, order: .bigEndian)
        XCTAssertThrowsError(try MachOUniversalFile.split(data(bytes))) { error in
            XCTAssertEqual(error as? MachOUniversalFile.Failure, .malformedContainer)
        }
    }

    func testTooManyRecordsAreRefusedBeforeAnySliceIsRead() {
        var bytes = MachOFixtures.number(UInt64(0xCAFE_BABE), width: 4, order: .bigEndian)
        bytes += MachOFixtures.number(UInt64(MachOUniversalFile.maximumSliceCount + 1),
                                      width: 4, order: .bigEndian)
        bytes += [UInt8](repeating: 0, count: (MachOUniversalFile.maximumSliceCount + 1) * 20)
        XCTAssertThrowsError(try MachOUniversalFile.split(data(bytes))) { error in
            XCTAssertEqual(error as? MachOUniversalFile.Failure, .resourceLimitExceeded)
        }
    }

    func testTwoRecordsNamingTheSameArchitectureAreRefused() {
        let container = MachOFixtures.fat([
            (cpu: MachOFixtures.arm64, subtype: 0, bytes: thin(0xA1)),
            (cpu: MachOFixtures.arm64, subtype: 0, bytes: thin(0xB2))
        ])
        XCTAssertThrowsError(try MachOUniversalFile.split(data(container))) { error in
            XCTAssertEqual(error as? MachOUniversalFile.Failure, .ambiguousSlices)
        }
    }

    func testOverlappingSlicesAreRefused() {
        var container = MachOFixtures.fat([
            (cpu: MachOFixtures.arm64, subtype: 0, bytes: thin(0xA1)),
            (cpu: MachOFixtures.x86_64, subtype: 3, bytes: thin(0xB2))
        ])
        // Point the second record four bytes into the first slice. Both ranges
        // still fit the file; only the overlap gives it away.
        let firstSliceOffset = (0..<4).reduce(0) { $0 << 8 | Int(container[8 + 8 + $1]) }
        MachOFixtures.put(UInt64(firstSliceOffset + 4), at: 8 + 20 + 8, in: &container)
        XCTAssertThrowsError(try MachOUniversalFile.split(data(container))) { error in
            XCTAssertEqual(error as? MachOUniversalFile.Failure, .ambiguousSlices)
        }
    }

    func testASliceThatDoesNotFitTheFileIsRefused() {
        var container = MachOFixtures.fat([
            (cpu: MachOFixtures.arm64, subtype: 0, bytes: thin(0xA1)),
            (cpu: MachOFixtures.x86_64, subtype: 3, bytes: thin(0xB2))
        ])
        MachOFixtures.put(UInt64(container.count + 4), at: 8 + 20 + 12, in: &container)
        XCTAssertThrowsError(try MachOUniversalFile.split(data(container))) { error in
            XCTAssertEqual(error as? MachOUniversalFile.Failure, .malformedContainer)
        }
    }

    func testASliceThatIgnoresItsOwnAlignmentIsRefused() {
        var container = MachOFixtures.fat([
            (cpu: MachOFixtures.arm64, subtype: 0, bytes: thin(0xA1)),
            (cpu: MachOFixtures.x86_64, subtype: 3, bytes: thin(0xB2))
        ], alignmentExponent: 2)
        // Declare a 4 KiB alignment the actual offsets do not honour.
        MachOFixtures.put(12, at: 8 + 16, in: &container)
        MachOFixtures.put(12, at: 8 + 20 + 16, in: &container)
        XCTAssertThrowsError(try MachOUniversalFile.split(data(container))) { error in
            XCTAssertEqual(error as? MachOUniversalFile.Failure, .malformedContainer)
        }
    }

    func testASliceThatIsNotAnImageIsRefused() {
        let container = MachOFixtures.fat([
            (cpu: MachOFixtures.arm64, subtype: 0, bytes: [UInt8](repeating: 0x7F, count: 64)),
            (cpu: MachOFixtures.x86_64, subtype: 3, bytes: thin(0xB2))
        ])
        XCTAssertThrowsError(try MachOUniversalFile.split(data(container))) { error in
            XCTAssertEqual(error as? MachOUniversalFile.Failure, .unsupportedSlice)
        }
    }

    func testASliceWhoseCommandTableRunsPastItsEndIsRefused() {
        var broken = thin(0xA1)
        MachOFixtures.put(512, at: 20, in: &broken, order: .littleEndian)
        let container = MachOFixtures.fat([
            (cpu: MachOFixtures.arm64, subtype: 0, bytes: broken),
            (cpu: MachOFixtures.x86_64, subtype: 3, bytes: thin(0xB2))
        ])
        XCTAssertThrowsError(try MachOUniversalFile.split(data(container))) { error in
            XCTAssertEqual(error as? MachOUniversalFile.Failure, .unsupportedSlice)
        }
    }

    // MARK: - Replacement

    func testReplacingOneSliceLeavesTheOtherExactAndInPlace() throws {
        let container = data(MachOFixtures.fat([
            (cpu: MachOFixtures.arm64, subtype: 0, bytes: thin(0xA1)),
            (cpu: MachOFixtures.x86_64, subtype: 3, bytes: thin(0xB2))
        ]))
        let split = try MachOUniversalFile.split(container)
        let arm64Key = try XCTUnwrap(split.slices.first).architectureKey
        let replacement = thin(0xC3, commandSize: 16)

        let updated = try split.replacingSlice(for: arm64Key, with: data(replacement))
        XCTAssertEqual(updated.slices[0].cpuSubtype, 0)
        XCTAssertEqual(updated.slices[0].bytes, data(replacement))
        XCTAssertEqual(updated.slices[1].bytes, split.slices[1].bytes)

        let rebuilt = try MachOUniversalFile.split(try updated.rebuild())
        XCTAssertEqual(rebuilt.slices.map(\.bytes), updated.slices.map(\.bytes))
    }

    func testReplacingAnArchitectureThatIsNotThereIsRefused() throws {
        let split = try MachOUniversalFile.split(data(MachOFixtures.fat([
            (cpu: MachOFixtures.arm64, subtype: 0, bytes: thin(0xA1))
        ])))
        XCTAssertThrowsError(try split.replacingSlice(for: "\(MachOFixtures.x86_64)-3",
                                                      with: data(thin(0xC3)))) { error in
            XCTAssertEqual(error as? MachOUniversalFile.Failure, .ambiguousSlices)
        }
    }

    func testReplacingASliceWithSomethingThatIsNotAnImageIsRefused() throws {
        let split = try MachOUniversalFile.split(data(MachOFixtures.fat([
            (cpu: MachOFixtures.arm64, subtype: 0, bytes: thin(0xA1))
        ])))
        let key = try XCTUnwrap(split.slices.first).architectureKey
        XCTAssertThrowsError(try split.replacingSlice(
            for: key, with: Data(repeating: 0x00, count: 64))) { error in
            XCTAssertEqual(error as? MachOUniversalFile.Failure, .unsupportedSlice)
        }
    }
}
