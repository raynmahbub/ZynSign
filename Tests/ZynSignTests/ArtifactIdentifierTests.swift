import XCTest
@testable import ZynSign

final class ArtifactIdentifierTests: XCTestCase {

    func testInitWithUUIDRoundTripsThroughRawValue() throws {
        let uuid = try XCTUnwrap(UUID(uuidString: "6B3FD418-6C5E-4E2A-9B1A-2C3D4E5F6071"))
        let identifier = ArtifactIdentifier(uuid: uuid)
        XCTAssertEqual(identifier.uuid, uuid)
        let rehydrated = try XCTUnwrap(ArtifactIdentifier(rawValue: identifier.rawValue))
        XCTAssertEqual(rehydrated, identifier)
    }

    func testInitWithInvalidRawValueReturnsNil() {
        XCTAssertNil(ArtifactIdentifier(rawValue: "not-an-identifier"))
        XCTAssertNil(ArtifactIdentifier(rawValue: ""))
    }

    func testIdentifiersWithSameUUIDAreEqual() throws {
        let uuid = try XCTUnwrap(UUID(uuidString: "6B3FD418-6C5E-4E2A-9B1A-2C3D4E5F6071"))
        XCTAssertEqual(ArtifactIdentifier(uuid: uuid), ArtifactIdentifier(uuid: uuid))
    }

    func testIdentifiersWithDifferentUUIDsAreNotEqual() throws {
        let first = try XCTUnwrap(UUID(uuidString: "6B3FD418-6C5E-4E2A-9B1A-2C3D4E5F6071"))
        let second = try XCTUnwrap(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
        XCTAssertNotEqual(ArtifactIdentifier(uuid: first), ArtifactIdentifier(uuid: second))
    }

    func testFreshIdentifiersAreDistinct() {
        XCTAssertNotEqual(ArtifactIdentifier(), ArtifactIdentifier())
    }

    func testHashabilityCollapsesEqualIdentifiers() throws {
        let uuid = try XCTUnwrap(UUID(uuidString: "6B3FD418-6C5E-4E2A-9B1A-2C3D4E5F6071"))
        let identifiers: Set<ArtifactIdentifier> = [ArtifactIdentifier(uuid: uuid), ArtifactIdentifier(uuid: uuid)]
        XCTAssertEqual(identifiers.count, 1)
    }

    func testDescriptionIsTheRawValue() throws {
        let uuid = try XCTUnwrap(UUID(uuidString: "6B3FD418-6C5E-4E2A-9B1A-2C3D4E5F6071"))
        let identifier = ArtifactIdentifier(uuid: uuid)
        XCTAssertEqual(identifier.description, identifier.rawValue)
    }
}
