import Foundation

/// One HTTP reachability probe for a revocation endpoint.
///
/// The probe performs a single bounded request and reports what happened.
/// It never follows more than the platform's default redirect behaviour, and
/// it treats a server error answer as "reachable": a revocation endpoint
/// that answers at all is an endpoint Apple's infrastructure can use.
protocol RevocationEndpointProbe: Sendable {

    /// Probes one endpoint address.
    func probe(url: URL, timeout: TimeInterval) async -> EndpointProbeOutcome.Channels
}

extension EndpointProbeOutcome {
    /// The transport facts a probe produces before the endpoint is attached.
    struct Channels: Equatable, Hashable, Sendable {
        /// Whether the endpoint answered over HTTP at all.
        let reachable: Bool
        /// The HTTP status the endpoint answered with, when it answered.
        let statusCode: Int?
        /// Round-trip time in milliseconds, when measured.
        let latencyMs: Int?

        /// Attaches the endpoint the facts belong to.
        func outcome(for endpoint: RevocationEndpoint) -> EndpointProbeOutcome {
            EndpointProbeOutcome(
                endpoint: endpoint,
                reachable: reachable,
                statusCode: statusCode,
                latencyMs: latencyMs
            )
        }
    }
}

/// Persistence for the most recent exposure check per certificate.
protocol RevocationReportStore: Sendable {

    /// Records the report for one certificate fingerprint, replacing the
    /// previous report for that fingerprint.
    func store(_ report: RevocationExposureReport, fingerprint: String) throws

    /// The recorded report for one certificate fingerprint, when present.
    func report(forFingerprint fingerprint: String) throws -> RevocationExposureReport?

    /// Removes the recorded report for one certificate fingerprint.
    func remove(fingerprint: String) throws
}

/// Checks how reachable a certificate's revocation channels are right now,
/// and keeps the most recent result per certificate.
///
/// The service answers an exposure question, not a revocation question: it
/// establishes whether the endpoints a certificate names can be reached from
/// this device at this moment. Every endpoint unreachable while ordinary
/// connectivity works is the pattern an anti-revoke shield produces; the
/// report carries the per-endpoint facts so the interface never has to guess
/// which of the two it is looking at.
struct CertificateRevocationService: Sendable {

    /// The most seconds one endpoint probe may take.
    static let probeTimeout: TimeInterval = 5

    private let probe: any RevocationEndpointProbe
    private let reports: any RevocationReportStore

    init(probe: any RevocationEndpointProbe, reports: any RevocationReportStore) {
        self.probe = probe
        self.reports = reports
    }

    /// The most recent stored report for one certificate, when there is one.
    func lastReport(fingerprint: String) throws -> RevocationExposureReport? {
        try reports.report(forFingerprint: fingerprint)
    }

    /// Runs one exposure check for the certificate whose DER bytes are
    /// provided, stores the result under `fingerprint`, and returns it.
    ///
    /// The check is bounded: every endpoint gets one probe with a hard
    /// timeout, and the whole check finishes after one round regardless of
    /// how slow the endpoints are.
    func check(
        certificateDER: Data,
        fingerprint: String,
        clock: Date = Date()
    ) async throws -> RevocationExposureReport {
        let endpoints = CertificateRevocationLocator.endpoints(in: certificateDER)
        guard !endpoints.isEmpty else {
            let report = RevocationExposureReport(outcomes: [], checkedAt: clock)
            try reports.store(report, fingerprint: fingerprint)
            return report
        }
        var outcomes: [EndpointProbeOutcome] = []
        outcomes.reserveCapacity(endpoints.count)
        for endpoint in endpoints {
            guard let url = URL(string: endpoint.url) else {
                outcomes.append(EndpointProbeOutcome(
                    endpoint: endpoint, reachable: false, statusCode: nil, latencyMs: nil
                ))
                continue
            }
            let facts = await probe.probe(url: url, timeout: Self.probeTimeout)
            outcomes.append(facts.outcome(for: endpoint))
        }
        let report = RevocationExposureReport(outcomes: outcomes, checkedAt: clock)
        try reports.store(report, fingerprint: fingerprint)
        return report
    }

    /// Drops the stored report for one certificate — used when the
    /// certificate itself is removed.
    func forget(fingerprint: String) throws {
        try reports.remove(fingerprint: fingerprint)
    }
}
