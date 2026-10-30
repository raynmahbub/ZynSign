import Foundation
import XCTest
@testable import ZynSign

private actor FragmentedDeviceTransport: DeviceTransport {
    private var fragments: [Data]
    private var sent: [Data] = []

    init(_ fragments: [Data]) { self.fragments = fragments }
    func connect(pairing: DevicePairingRecord, port: Int) async throws {}
    func send(_ data: Data) async throws { sent.append(data) }
    func receive(maximumBytes: Int) async throws -> Data {
        guard !fragments.isEmpty else { return Data() }
        return fragments.removeFirst()
    }
    func close() async {}
}

final class DeviceTransportFramingTests: XCTestCase {
    func testExactReadCombinesFragments() async throws {
        let transport = FragmentedDeviceTransport([Data([1]), Data([2, 3]), Data([4])])
        let result = try await transport.receiveExactly(4, maximum: 4)
        XCTAssertEqual(result, Data([1, 2, 3, 4]))
    }

    func testExactReadRejectsEarlyEndAndOverlongChunk() async throws {
        let truncated = FragmentedDeviceTransport([Data([1, 2])])
        do {
            _ = try await truncated.receiveExactly(4, maximum: 4)
            XCTFail("Expected truncated frame")
        } catch {
            XCTAssertEqual(error as? DeviceProtocolError, .truncatedFrame(needed: 4, received: 2))
        }
        let oversized = FragmentedDeviceTransport([Data([1, 2, 3])])
        do {
            _ = try await oversized.receiveExactly(2, maximum: 2)
            XCTFail("Expected overlong chunk refusal")
        } catch {
            XCTAssertEqual(error as? DeviceProtocolError, .invalidFrameLength(3))
        }
    }

    func testExactReadRejectsUnboundedRequestBeforeReceiving() async throws {
        let transport = FragmentedDeviceTransport([Data([1])])
        do {
            _ = try await transport.receiveExactly(9, maximum: 8)
            XCTFail("Expected length refusal")
        } catch {
            XCTAssertEqual(error as? DeviceProtocolError, .invalidFrameLength(9))
        }
        let first = try await transport.receiveExactly(1, maximum: 1)
        XCTAssertEqual(first, Data([1]))
    }

    func testLockdownRequestAcceptsFragmentedResponse() async throws {
        let message = try PropertyListFraming.encodedMessage(["Request": "QueryType", "Type": LockdownProtocol.service])
        let fragments = message.map { Data([$0]) }
        let transport = FragmentedDeviceTransport(fragments)
        let response = try await LockdownStream(transport: transport).request(.queryType)
        guard case .success(let values) = response else { return XCTFail("Expected success") }
        XCTAssertEqual(values["Type"] as? String, LockdownProtocol.service)
    }
}

private struct FramingPairingStore: PairingRecordStoring {
    func save(_ record: DevicePairingRecord) throws {}
    func all() throws -> [DevicePairingRecord] { [] }
    func remove(hostIdentifier: String) throws {}
}

private actor SessionTestTransport: DeviceTransport {
    private var incoming: Data
    private(set) var closed = false
    private(set) var requests: [[String: String]] = []

    init(response: Data) { incoming = response }
    func connect(pairing: DevicePairingRecord, port: Int) async throws {}
    func send(_ data: Data) async throws {
        let body = Data(data.dropFirst(PropertyListFraming.lengthPrefixBytes))
        let values = try PropertyListFraming.decode(body)
        requests.append(values.compactMapValues { $0 as? String })
    }
    func receive(maximumBytes: Int) async throws -> Data {
        let count = min(maximumBytes, incoming.count)
        let result = Data(incoming.prefix(count))
        incoming.removeFirst(count)
        return result
    }
    func close() async { closed = true }
}

extension DeviceTransportFramingTests {
    func testSessionTLSUpgradeFailsClosedAndClosesTransport() async throws {
        let response = try PropertyListFraming.encodedMessage([
            "Request": "StartSession", "SessionID": "session", "EnableSessionSSL": true
        ])
        let transport = SessionTestTransport(response: response)
        let bridge = DeviceBridgeService(recordStore: FramingPairingStore(), makeTransport: { transport })
        let record = DevicePairingRecord(deviceCertificate: Data(), rootCertificate: Data(),
                                         hostCertificate: Data(), hostPrivateKey: Data(),
                                         hostIdentifier: "host", systemBUID: "buid")
        do {
            _ = try await bridge.connect(record: record)
            XCTFail("An unsupported TLS upgrade must fail closed")
        } catch {
            XCTAssertEqual(error as? DeviceProtocolError, .authenticatedTransportUnavailable)
        }
        let closed = await transport.closed
        let requests = await transport.requests
        XCTAssertTrue(closed)
        XCTAssertEqual(requests.map { $0["Request"] }, ["StartSession"])
    }
    func testServiceTLSRequirementFailsClosed() async throws {
        let session = try PropertyListFraming.encodedMessage([
            "Request": "StartSession", "SessionID": "session", "EnableSessionSSL": false
        ])
        let service = try PropertyListFraming.encodedMessage([
            "Request": "StartService", "Port": 1234, "EnableServiceSSL": true
        ])
        let transport = SessionTestTransport(response: session + service)
        let bridge = DeviceBridgeService(recordStore: FramingPairingStore(), makeTransport: { transport })
        let record = DevicePairingRecord(deviceCertificate: Data(), rootCertificate: Data(),
                                         hostCertificate: Data(), hostPrivateKey: Data(),
                                         hostIdentifier: "host", systemBUID: "buid")
        do {
            _ = try await bridge.install(package: Data([1]), bundleIdentifier: "com.example.test",
                                         fileName: "test.ipa", record: record)
            XCTFail("Service TLS must not be ignored")
        } catch {
            XCTAssertEqual(error as? DeviceProtocolError, .authenticatedTransportUnavailable)
        }
        let closed = await transport.closed
        let requests = await transport.requests
        XCTAssertTrue(closed)
        XCTAssertEqual(requests.map { $0["Request"] }, ["StartSession", "StartService"])
    }

}
