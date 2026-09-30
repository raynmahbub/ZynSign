import XCTest
@testable import ZynSign

/// Tests for the revocation endpoint locator over synthetic DER.
///
/// The fixtures below are not real certificates: they are byte sequences
/// shaped like the ones a locator must survive — the OCSP method object
/// identifier and the CRL distribution points identifier, each followed by
/// a tagged address — so the locator's scanning rules can be exercised
/// deterministically without a certificate store.
final class CertificateRevocationLocatorTests: XCTestCase {

    private func data(_ bytes: [UInt8]) -> Data { Data(bytes) }

    /// Builds `[6] <url>` — the GeneralName URI form the locator reads.
    private func taggedURI(_ url: String) -> [UInt8] {
        let ascii = Array(url.utf8)
        return [0x86, UInt8(ascii.count)] + ascii
    }

    func testLocatesAnOCSPResponder() {
        var bytes: [UInt8] = [0x30, 0x10]
        bytes += CertificateRevocationLocator.ocspMethodOIDBytes
        bytes += taggedURI("http://ocsp.example.com/")
        let endpoints = CertificateRevocationLocator.endpoints(in: data(bytes))
        XCTAssertEqual(endpoints.count, 1)
        XCTAssertEqual(endpoints.first?.channel, .ocsp)
        XCTAssertEqual(endpoints.first?.url, "http://ocsp.example.com/")
    }

    func testLocatesACRLDistributionPoint() {
        var bytes: [UInt8] = [0x30, 0x10]
        bytes += CertificateRevocationLocator.crlDistributionPointsOIDBytes
        bytes += taggedURI("http://crl.example.com/root.crl")
        let endpoints = CertificateRevocationLocator.endpoints(in: data(bytes))
        XCTAssertEqual(endpoints.count, 1)
        XCTAssertEqual(endpoints.first?.channel, .crl)
    }

    func testBothChannelsTogetherWithOCSPFirst() {
        var bytes: [UInt8] = []
        bytes += CertificateRevocationLocator.ocspMethodOIDBytes + taggedURI("http://ocsp.example.com/")
        bytes += [0x00, 0x00]
        bytes += CertificateRevocationLocator.crlDistributionPointsOIDBytes + taggedURI("http://crl.example.com/a.crl")
        let endpoints = CertificateRevocationLocator.endpoints(in: data(bytes))
        XCTAssertEqual(endpoints.map(\.channel), [.ocsp, .crl])
    }

    func testNonHTTPAddressesAreSkipped() {
        var bytes: [UInt8] = CertificateRevocationLocator.ocspMethodOIDBytes
        bytes += taggedURI("ldap://directory.example.com/cn=x")
        XCTAssertTrue(CertificateRevocationLocator.endpoints(in: data(bytes)).isEmpty)
    }

    func testDuplicatesCollapse() {
        var bytes: [UInt8] = []
        bytes += CertificateRevocationLocator.ocspMethodOIDBytes + taggedURI("http://ocsp.example.com/")
        bytes += [0x00]
        bytes += CertificateRevocationLocator.ocspMethodOIDBytes + taggedURI("http://ocsp.example.com/")
        XCTAssertEqual(CertificateRevocationLocator.endpoints(in: data(bytes)).count, 1)
    }

    func testEmptyAndTinyInputsFindNothing() {
        XCTAssertTrue(CertificateRevocationLocator.endpoints(in: Data()).isEmpty)
        XCTAssertTrue(CertificateRevocationLocator.endpoints(in: data([0x30, 0x01, 0x00])).isEmpty)
    }

    func testNonASCIIAddressIsRefused() {
        var bytes: [UInt8] = CertificateRevocationLocator.ocspMethodOIDBytes
        bytes += [0x86, 0x04, 0xC3, 0xA9, 0x74, 0xE9]
        XCTAssertTrue(CertificateRevocationLocator.endpoints(in: data(bytes)).isEmpty)
    }

    func testVerdictRules() {
        let ocsp = RevocationEndpoint(channel: .ocsp, url: "http://ocsp.example.com/")
        let answered = EndpointProbeOutcome(endpoint: ocsp, reachable: true, statusCode: 200, latencyMs: 40)
        let blocked = EndpointProbeOutcome(endpoint: ocsp, reachable: false, statusCode: nil, latencyMs: nil)
        XCTAssertEqual(RevocationExposureReport.verdict(for: []), .noEndpoints)
        XCTAssertEqual(RevocationExposureReport.verdict(for: [answered]), .exposed)
        XCTAssertEqual(RevocationExposureReport.verdict(for: [blocked]), .shielded)
        XCTAssertEqual(RevocationExposureReport.verdict(for: [answered, blocked]), .partial)
    }
}
