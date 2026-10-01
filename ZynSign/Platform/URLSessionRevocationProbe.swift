import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The URLSession-backed revocation endpoint probe.
///
/// One bounded GET per endpoint. Any HTTP answer — including a client or
/// server error — counts as reachable, because the question is whether the
/// endpoint can be reached, not whether it is healthy. The probe observes
/// response headers only; revocation bodies are never buffered or retained.
final class URLSessionRevocationProbe: RevocationEndpointProbe, @unchecked Sendable {

    private let makeSession: @Sendable (TimeInterval) -> URLSession

    init(makeSession: @escaping @Sendable (TimeInterval) -> URLSession = { timeout in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }) {
        self.makeSession = makeSession
    }

    func probe(url: URL, timeout: TimeInterval) async -> EndpointProbeOutcome.Channels {
        let session = makeSession(timeout)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        let started = ContinuousClock.now
        do {
            // Unlike data(for:), bytes(for:) returns at response headers and
            // does not materialize an attacker-controlled body. The session is
            // invalidated immediately after the reachability fact is captured.
            let (_, response) = try await session.bytes(for: request)
            let elapsed = ContinuousClock.now - started
            let latencyMs = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            return EndpointProbeOutcome.Channels(
                reachable: true,
                statusCode: statusCode,
                latencyMs: latencyMs
            )
        } catch {
            return EndpointProbeOutcome.Channels(reachable: false, statusCode: nil, latencyMs: nil)
        }
    }
}
