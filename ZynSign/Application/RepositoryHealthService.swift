import Foundation

/// Health of a repository/source feed, measured by the App Store pipeline.
///
/// `Fast`/`Slow` thresholds are ZynSign policy (not Apple documented):
/// - Fast: p95 < 800ms on last probe
/// - Slow: 800ms–3000ms
/// - Offline: no successful fetch or explicit failure on last probe
/// Probes are bounded: 3s timeout, single attempt, no retry, no credential.
enum RepositoryHealth: String, CaseIterable, Equatable {
    case fast = "Fast"
    case slow = "Slow"
    case offline = "Offline"
    case unknown = "Unknown"

    var systemImage: String {
        switch self {
        case .fast: return "bolt.fill"
        case .slow: return "tortoise.fill"
        case .offline: return "wifi.slash"
        case .unknown: return "questionmark.circle"
        }
    }
    var tint: String { rawValue }
}

struct RepositoryProbeResult: Equatable {
    let health: RepositoryHealth
    let latencyMilliseconds: Int?
    let httpStatus: Int?
    let errorCategory: String?
    let probedAt: Date
}

/// The boundary through which one health probe fetches a source document.
///
/// A probe is a bounded, credential-free GET, and that is all this port
/// offers. It exists so the network's failure modes — offline, slow, broken,
/// partial — can be reproduced in a test and in the Compatibility Lab
/// without reaching a real host, and so the probe itself contains no
/// transport policy of its own.
protocol RepositoryHealthTransport: Sendable {

    /// Performs one request, or throws the transport's own failure.
    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse)
}

/// The transport ZynSign uses: the shared session, with no credential and no
/// customisation beyond what the request itself asks for.
struct URLSessionRepositoryHealthTransport: RepositoryHealthTransport {

    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

/// Bounded health probe for a source URL.
/// Single GET, 3s timeout, validates that body is JSON and parses as AltSource.
///
/// The transport is injectable so a failure can be reproduced rather than
/// waited for: the Compatibility Lab probes through transports that never
/// reach a network, and asserts that every one of them still ends in a state
/// the interface can render.
struct RepositoryHealthProbe {

    /// How long one probe waits before it gives up.
    let timeout: TimeInterval

    /// The transport the probe fetches through.
    let transport: any RepositoryHealthTransport

    init(
        transport: any RepositoryHealthTransport = URLSessionRepositoryHealthTransport(),
        timeout: TimeInterval = 3.0
    ) {
        self.transport = transport
        self.timeout = timeout
    }

    func probe(url: URL) async -> RepositoryProbeResult {
        let start = Date()
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await transport.fetch(req)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            guard let http = response as? HTTPURLResponse else {
                return RepositoryProbeResult(health: .offline, latencyMilliseconds: ms, httpStatus: nil, errorCategory: "no http", probedAt: Date())
            }
            guard (200...299).contains(http.statusCode) else {
                return RepositoryProbeResult(health: .offline, latencyMilliseconds: ms, httpStatus: http.statusCode, errorCategory: "http \(http.statusCode)", probedAt: Date())
            }
            // Must be JSON and contain apps key to be considered valid feed
            let isJSON = (try? JSONSerialization.jsonObject(with: data)) != nil
            guard isJSON else {
                return RepositoryProbeResult(health: .offline, latencyMilliseconds: ms, httpStatus: http.statusCode, errorCategory: "not json", probedAt: Date())
            }
            let health: RepositoryHealth = ms < 800 ? .fast : (ms < 3000 ? .slow : .offline)
            return RepositoryProbeResult(health: health, latencyMilliseconds: ms, httpStatus: http.statusCode, errorCategory: nil, probedAt: Date())
        } catch {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            return RepositoryProbeResult(
                health: .offline,
                latencyMilliseconds: ms,
                httpStatus: nil,
                errorCategory: Self.transportErrorCategory(error),
                probedAt: Date()
            )
        }
    }

    /// Reduces a transport failure to one of a few fixed words.
    ///
    /// A platform error's own text can carry a host name, a path, or a
    /// credential-ish fragment, and the probe's result is shown in the
    /// interface and written to reports. The category is therefore chosen
    /// from a closed vocabulary: enough to tell an offline device from a
    /// timeout, never enough to leak what the network said.
    static func transportErrorCategory(_ error: Error) -> String {
        let failure = error as NSError
        guard failure.domain == NSURLErrorDomain else { return "transport" }
        switch failure.code {
        case NSURLErrorTimedOut: return "timeout"
        case NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost, NSURLErrorCallIsActive:
            return "offline"
        case NSURLErrorNetworkConnectionLost: return "connection lost"
        case NSURLErrorCancelled, NSURLErrorUserCancelledAuthentication: return "cancelled"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "host not found"
        case NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateNotYetValid:
            return "tls"
        case NSURLErrorBadServerResponse, NSURLErrorCannotParseResponse: return "bad response"
        default: return "transport"
        }
    }
}
