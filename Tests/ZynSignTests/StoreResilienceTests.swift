import XCTest
@testable import ZynSign

/// Store and network resilience: that a network that misbehaves produces a
/// state, never a thrown error the screen was not built for.
///
/// Every case is reproduced through an injected transport. A failure that can
/// only be tested by waiting for it is a failure nobody tests.
final class StoreResilienceTests: XCTestCase {

    private let source = URL(string: "https://example.invalid/source.json")!

    func testAnUnreachableSourceIsReportedOffline() async {
        let result = await probe(UnreachableRepositoryTransport())
        XCTAssertEqual(result.health, .offline)
        XCTAssertEqual(result.errorCategory, "offline")
    }

    func testASlowSourceIsMeasuredAndReportedSlow() async {
        let result = await probe(SlowRepositoryTransport(delayMilliseconds: 900))
        XCTAssertEqual(result.health, .slow)
        XCTAssertGreaterThanOrEqual(result.latencyMilliseconds ?? 0, 800)
    }

    func testAFailingSourceCarriesItsStatus() async {
        let result = await probe(HTTPErrorRepositoryTransport(statusCode: 500))
        XCTAssertEqual(result.health, .offline)
        XCTAssertEqual(result.httpStatus, 500)
    }

    func testA200ThatIsNotJSONIsRefusedRatherThanParsed() async {
        let result = await probe(MalformedRepositoryTransport())
        XCTAssertEqual(result.health, .offline)
        XCTAssertEqual(result.errorCategory, "not json")
    }

    func testATruncatedBodyIsRefusedRatherThanParsed() async {
        let result = await probe(TruncatedRepositoryTransport())
        XCTAssertEqual(result.health, .offline)
        XCTAssertNotNil(result.errorCategory)
    }

    func testNoTransportFailureEscapesAsAnError() async {
        // The probe's contract is that it always produces a result. A throw
        // here would be a state the interface has no way to render.
        let transports: [any RepositoryHealthTransport] = [
            UnreachableRepositoryTransport(),
            SlowRepositoryTransport(delayMilliseconds: 900),
            HTTPErrorRepositoryTransport(statusCode: 404),
            MalformedRepositoryTransport(),
            TruncatedRepositoryTransport()
        ]
        for transport in transports {
            let result = await RepositoryHealthProbe(transport: transport).probe(url: source)
            if transport is SlowRepositoryTransport {
                // A slow source succeeds and is measured as slow — the point
                // of this sweep is that no outcome escapes as a thrown error.
                XCTAssertEqual(result.health, .slow, "\(type(of: transport))")
            } else {
                XCTAssertEqual(result.health, .offline, "\(type(of: transport))")
            }
        }
    }

    func testATransportFailureIsReducedToAFixedCategory() {
        // The category is shown in the interface and written to reports, so
        // it must never carry what the network said about itself.
        XCTAssertEqual(
            RepositoryHealthProbe.transportErrorCategory(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
            ),
            "timeout"
        )
        XCTAssertEqual(
            RepositoryHealthProbe.transportErrorCategory(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
            ),
            "offline"
        )
        XCTAssertEqual(
            RepositoryHealthProbe.transportErrorCategory(
                NSError(domain: "example.invalid", code: 42)
            ),
            "transport"
        )
    }

    // MARK: - Support

    private func probe(_ transport: any RepositoryHealthTransport) async -> RepositoryProbeResult {
        await RepositoryHealthProbe(transport: transport).probe(url: source)
    }
}
