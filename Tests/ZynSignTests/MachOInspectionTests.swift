import Foundation
import XCTest
@testable import ZynSign

final class MachOInspectionTests: XCTestCase {
    private final class RecordingParser: MachOParsing {
        var calls = 0
        var receivedByteCount: Int?
        let result: Result<MachOImage, MachOParsingError>

        init(_ result: Result<MachOImage, MachOParsingError>) {
            self.result = result
        }

        func parse(_ bytes: Data) throws -> MachOImage {
            calls += 1
            receivedByteCount = bytes.count
            return try result.get()
        }
    }

    func testInspectionPassesCallerProvidedBytesToParserOnce() throws {
        let data = Data(MachOFixtures.thin())
        let expected = try ReadOnlyMachOParser().parse(data)
        let parser = RecordingParser(.success(expected))

        let inspected = try MachOInspection(parser: parser).inspect(bytes: data)

        XCTAssertEqual(inspected, expected)
        XCTAssertEqual(parser.calls, 1)
        XCTAssertEqual(parser.receivedByteCount, data.count)
        XCTAssertEqual(data, Data(MachOFixtures.thin()))
    }

    func testStructuredFailureIsPreserved() {
        let failure = MachOParsingError(.invalidOffset, at: .signatureRegion,
                                        architectureIndex: 1)
        let parser = RecordingParser(.failure(failure))
        XCTAssertThrowsError(try MachOInspection(parser: parser).inspect(bytes: Data([0x01]))) { error in
            XCTAssertEqual(error as? MachOParsingError, failure)
        }
        XCTAssertEqual(parser.calls, 1)
    }

    func testDefaultUseCaseDoesNotRequireArchiveOrSigningCapability() throws {
        let result = try MachOInspection().inspect(bytes: Data(MachOFixtures.thin()))
        XCTAssertEqual(result.slices.count, 1)
        XCTAssertNil(result.slice(at: 0)?.embeddedSignature)
    }
}
