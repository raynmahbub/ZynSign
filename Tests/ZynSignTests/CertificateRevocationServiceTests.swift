import XCTest
@testable import ZynSign

/// Tests for the revocation exposure service over a scripted probe and an
/// in-memory report store.
final class CertificateRevocationServiceTests: XCTestCase {

    private final class ScriptedProbe: RevocationEndpointProbe, @unchecked Sendable {
        var answers: [String: EndpointProbeOutcome.Channels] = [:]
        private(set) var probed: [URL] = []

        func probe(url: URL, timeout: TimeInterval) async -> EndpointProbeOutcome.Channels {
            probed.append(url)
            return answers[url.absoluteString] ?? EndpointProbeOutcome.Channels(reachable: false, statusCode: nil, latencyMs: nil)
        }
    }

    private final class InMemoryReports: RevocationReportStore, @unchecked Sendable {
        var stored: [String: RevocationExposureReport] = [:]
        func store(_ report: RevocationExposureReport, fingerprint: String) throws { stored[fingerprint] = report }
        func report(forFingerprint fingerprint: String) throws -> RevocationExposureReport? { stored[fingerprint] }
        func remove(fingerprint: String) throws { stored[fingerprint] = nil }
    }

    private var probe: ScriptedProbe!
    private var reports: InMemoryReports!
    private var service: CertificateRevocationService!

    override func setUp() {
        super.setUp()
        probe = ScriptedProbe()
        reports = InMemoryReports()
        service = CertificateRevocationService(probe: probe, reports: reports)
    }

    private func certificateDER(ocspURL: String? = nil, crlURL: String? = nil) -> Data {
        var bytes: [UInt8] = []
        if let ocspURL {
            bytes += CertificateRevocationLocator.ocspMethodOIDBytes
            bytes += [0x86, UInt8(ocspURL.utf8.count)] + Array(ocspURL.utf8)
        }
        if let crlURL {
            bytes += CertificateRevocationLocator.crlDistributionPointsOIDBytes
            bytes += [0x86, UInt8(crlURL.utf8.count)] + Array(crlURL.utf8)
        }
        return Data(bytes)
    }

    func testCertificateWithoutEndpointsStoresNoEndpointsVerdict() async throws {
        let report = try await service.check(certificateDER: Data([0x30, 0x00]), fingerprint: "aa")
        XCTAssertEqual(report.verdict, .noEndpoints)
        XCTAssertEqual(try service.lastReport(fingerprint: "aa")?.verdict, .noEndpoints)
        XCTAssertTrue(probe.probed.isEmpty)
    }

    func testExposedWhenEveryEndpointAnswers() async throws {
        probe.answers["http://ocsp.example.com/"] = EndpointProbeOutcome.Channels(reachable: true, statusCode: 200, latencyMs: 12)
        let report = try await service.check(
            certificateDER: certificateDER(ocspURL: "http://ocsp.example.com/"),
            fingerprint: "bb"
        )
        XCTAssertEqual(report.verdict, .exposed)
        XCTAssertEqual(report.outcomes.first?.latencyMs, 12)
    }

    func testShieldedWhenNoEndpointAnswers() async throws {
        let report = try await service.check(
            certificateDER: certificateDER(ocspURL: "http://blocked.example.com/"),
            fingerprint: "cc"
        )
        XCTAssertEqual(report.verdict, .shielded)
        XCTAssertFalse(report.anyEndpointAnswered)
    }

    func testPartialWhenSomeEndpointsAnswer() async throws {
        probe.answers["http://ocsp.example.com/"] = EndpointProbeOutcome.Channels(reachable: true, statusCode: 200, latencyMs: nil)
        let report = try await service.check(
            certificateDER: certificateDER(
                ocspURL: "http://ocsp.example.com/",
                crlURL: "http://blocked.example.com/x.crl"
            ),
            fingerprint: "dd"
        )
        XCTAssertEqual(report.verdict, .partial)
        XCTAssertTrue(report.anyEndpointAnswered)
        XCTAssertEqual(probe.probed.count, 2)
    }

    func testRecheckingReplacesTheStoredReport() async throws {
        _ = try await service.check(certificateDER: Data([0x30, 0x00]), fingerprint: "ee")
        probe.answers["http://ocsp.example.com/"] = EndpointProbeOutcome.Channels(reachable: true, statusCode: 200, latencyMs: nil)
        let second = try await service.check(
            certificateDER: certificateDER(ocspURL: "http://ocsp.example.com/"),
            fingerprint: "ee"
        )
        XCTAssertEqual(second.verdict, .exposed)
        XCTAssertEqual(try service.lastReport(fingerprint: "ee")?.verdict, .exposed)
    }

    func testForgetRemovesTheStoredReport() async throws {
        _ = try await service.check(certificateDER: Data([0x30, 0x00]), fingerprint: "ff")
        try service.forget(fingerprint: "ff")
        XCTAssertNil(try service.lastReport(fingerprint: "ff"))
    }
}
