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

/// Bounded health probe for a source URL.
/// Single GET, 3s timeout, validates that body is JSON and parses as AltSource.
struct RepositoryHealthProbe {
    private let timeout: TimeInterval = 3.0

    func probe(url: URL) async -> RepositoryProbeResult {
        let start = Date()
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
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
            return RepositoryProbeResult(health: .offline, latencyMilliseconds: ms, httpStatus: nil, errorCategory: error.localizedDescription, probedAt: Date())
        }
    }
}
