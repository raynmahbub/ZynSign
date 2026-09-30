import Foundation

/// One revocation endpoint a certificate points at.
struct RevocationEndpoint: Equatable, Hashable, Sendable {

    /// The channel the endpoint serves.
    enum Channel: String, CaseIterable, Hashable, Sendable {
        /// An OCSP responder, queried per certificate.
        case ocsp
        /// A certificate revocation list distribution point.
        case crl

        var displayName: String {
            switch self {
            case .ocsp: return "OCSP responder"
            case .crl: return "Revocation list"
            }
        }
    }

    /// The channel kind.
    let channel: Channel

    /// The endpoint address, exactly as embedded.
    let url: String
}

/// Extracts the revocation endpoints a DER certificate references.
///
/// Certificates name their revocation channels in two extensions: the
/// Authority Information Access extension (OCSP responders) and the CRL
/// Distribution Points extension (revocation lists). Both ultimately carry
/// their addresses as IA5 strings behind an explicit context tag, so a
/// bounded scan for the extension's object identifier, followed by a bounded
/// scan for the tagged address, recovers every address the certificate
/// publishes. The scan never interprets anything else in the certificate:
/// it is a locator, not a parser.
enum CertificateRevocationLocator {

    /// OCSP access method object identifier: 1.3.6.1.5.5.7.48.1
    static let ocspMethodOIDBytes: [UInt8] = [0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x30, 0x01]

    /// CRL Distribution Points extension object identifier: 2.5.29.31
    static let crlDistributionPointsOIDBytes: [UInt8] = [0x55, 0x1D, 0x1F]

    /// The most bytes after an object identifier hit the scan inspects for a
    /// tagged address. Real certificates place the address immediately after
    /// the method identifier; the window is generous, never unbounded.
    static let searchWindow = 512

    /// The most endpoints of one channel reported for a certificate.
    static let maximumEndpointsPerChannel = 8

    /// Locates every revocation endpoint the certificate bytes reference.
    ///
    /// The result carries OCSP endpoints first, then CRL endpoints, each
    /// group in order of appearance. Addresses that are not usable http or
    /// https URLs are skipped, because a revocation probe can only speak
    /// HTTP; the certificate still has the endpoint, it just has no HTTP form.
    static func endpoints(in certificateDER: Data) -> [RevocationEndpoint] {
        var found: [RevocationEndpoint] = []
        found += locate(
            in: certificateDER,
            oid: ocspMethodOIDBytes,
            channel: .ocsp,
            limit: maximumEndpointsPerChannel
        )
        found += locate(
            in: certificateDER,
            oid: crlDistributionPointsOIDBytes,
            channel: .crl,
            limit: maximumEndpointsPerChannel
        )
        return found
    }

    private static func locate(
        in data: Data,
        oid: [UInt8],
        channel: RevocationEndpoint.Channel,
        limit: Int
    ) -> [RevocationEndpoint] {
        let bytes = [UInt8](data)
        guard bytes.count > oid.count else { return [] }
        var endpoints: [RevocationEndpoint] = []
        var cursor = 0
        while endpoints.count < limit,
              let hit = firstOccurrence(of: oid, in: bytes, from: cursor) {
            cursor = hit + oid.count
            if let address = nextTaggedIA5String(in: bytes, after: cursor, window: searchWindow),
               isHTTPAddress(address),
               !endpoints.contains(where: { $0.url == address }) {
                endpoints.append(RevocationEndpoint(channel: channel, url: address))
            }
        }
        return endpoints
    }

    /// Finds the first occurrence of `needle` at or after `start`.
    private static func firstOccurrence(of needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let lastIndex = haystack.count - needle.count
        guard start <= lastIndex else { return nil }
        var index = start
        while index <= lastIndex {
            if Array(haystack[index..<(index + needle.count)]) == needle {
                return index
            }
            index += 1
        }
        return nil
    }

    /// Reads the first context-tag `[6]` IA5 string — the GeneralName
    /// uniformResourceIdentifier form — inside `window` bytes of `cursor`.
    private static func nextTaggedIA5String(in bytes: [UInt8], after cursor: Int, window: Int) -> String? {
        let end = min(bytes.count, cursor + window)
        var index = cursor
        while index < end {
            let tag = bytes[index]
            // Context-specific, primitive, tag 6: 0x86.
            if tag == 0x86 {
                index += 1
                guard index < end else { return nil }
                guard let (length, consumed) = readDERLength(bytes, at: index) else { return nil }
                index = consumed
                guard length > 0, length <= 2048, index + length <= bytes.count else { return nil }
                let slice = Array(bytes[index..<(index + length)])
                // IA5 is a 7-bit alphabet; anything outside it is not a URL.
                guard slice.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
                return String(decoding: slice, as: UTF8.self)
            }
            index += 1
        }
        return nil
    }

    /// Reads a definite DER length at `position`. Returns the value and the
    /// index of the first content byte.
    private static func readDERLength(_ bytes: [UInt8], at position: Int) -> (Int, Int)? {
        guard position < bytes.count else { return nil }
        let first = bytes[position]
        if first < 0x80 {
            return (Int(first), position + 1)
        }
        let countBytes = Int(first & 0x7F)
        guard countBytes > 0, countBytes <= 4, position + countBytes < bytes.count else { return nil }
        var value = 0
        for offset in 1...countBytes {
            value = value * 256 + Int(bytes[position + offset])
        }
        return (value, position + 1 + countBytes)
    }

    private static func isHTTPAddress(_ address: String) -> Bool {
        address.lowercased().hasPrefix("http://") || address.lowercased().hasPrefix("https://")
    }
}

/// The reachability outcome for one revocation endpoint.
struct EndpointProbeOutcome: Equatable, Hashable, Sendable {
    /// The endpoint that was probed.
    let endpoint: RevocationEndpoint

    /// Whether the endpoint answered over HTTP at all.
    let reachable: Bool

    /// The HTTP status the endpoint answered with, when it answered.
    let statusCode: Int?

    /// Round-trip time in milliseconds, when measured.
    let latencyMs: Int?
}

/// What one exposure check established about a certificate.
struct RevocationExposureReport: Equatable, Hashable, Sendable {

    /// The overall read of the probe results.
    enum Verdict: String, Equatable, Hashable, Sendable {
        /// Every revocation endpoint the certificate names is reachable right
        /// now: the device can be asked about this certificate, and Apple's
        /// servers can answer. Nothing blocks that conversation.
        case exposed
        /// At least one endpoint is unreachable while others answer: the
        /// revocation channel is partially obstructed.
        case partial
        /// The certificate names revocation endpoints and none of them is
        /// reachable from this device right now. Consistent with an
        /// anti-revoke DNS shield being active; also consistent with being
        /// offline. The report carries the detail that distinguishes them.
        case shielded
        /// The certificate publishes no revocation endpoint to probe.
        case noEndpoints
        /// No probe has run yet for this certificate.
        case notChecked
    }

    /// The verdict the outcomes produce.
    let verdict: Verdict

    /// One outcome per endpoint, in locator order.
    let outcomes: [EndpointProbeOutcome]

    /// When the check ran.
    let checkedAt: Date

    /// Whether at least one endpoint answered, distinguishing "shielded"
    /// from "offline": offline devices usually fail every probe including
    /// general connectivity, which the caller may establish separately.
    var anyEndpointAnswered: Bool { outcomes.contains { $0.reachable } }

    /// The verdict the probe outcomes imply, before any persistence.
    static func verdict(for outcomes: [EndpointProbeOutcome]) -> Verdict {
        guard !outcomes.isEmpty else { return .noEndpoints }
        let answered = outcomes.filter(\.reachable).count
        if answered == 0 { return .shielded }
        if answered == outcomes.count { return .exposed }
        return .partial
    }

    /// Builds a report from probe outcomes.
    init(outcomes: [EndpointProbeOutcome], checkedAt: Date = Date()) {
        self.verdict = Self.verdict(for: outcomes)
        self.outcomes = outcomes
        self.checkedAt = checkedAt
    }

    /// The not-checked report.
    static let notChecked = RevocationExposureReport(
        verdict: .notChecked, outcomes: [], checkedAt: Date.distantPast
    )

    /// Rebuilds a stored report from its parts. The verdict is taken as
    /// recorded; persistence round-trips never recompute it.
    init(verdict: Verdict, outcomes: [EndpointProbeOutcome], checkedAt: Date) {
        self.verdict = verdict
        self.outcomes = outcomes
        self.checkedAt = checkedAt
    }
}
