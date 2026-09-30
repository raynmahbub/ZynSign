import Foundation

/// File-backed persistence for the most recent revocation exposure report
/// per certificate fingerprint.
///
/// One JSON document, replaced atomically on every write. Reports are keyed
/// by the certificate's fingerprint because fingerprints are how the rest of
/// the app names certificates without touching their bytes. A damaged
/// document is reported as unreadable and left in place, matching the other
/// file-backed stores.
final class FileRevocationReportStore: RevocationReportStore, @unchecked Sendable {

    static let currentSchemaVersion = 1

    private struct Document: Codable {
        let schemaVersion: Int
        var reports: [String: StoredReport]
    }

    private struct StoredReport: Codable {
        let verdict: String
        let checkedAt: Date
        let outcomes: [StoredOutcome]
    }

    private struct StoredOutcome: Codable {
        let channel: String
        let url: String
        let reachable: Bool
        let statusCode: Int?
        let latencyMs: Int?
    }

    private let location: URL
    private var cached: [String: StoredReport]?
    private let access = NSLock()

    init(location: URL) {
        self.location = location
    }

    private func loadedOrRead() throws -> [String: StoredReport] {
        if let cached { return cached }
        guard FileManager.default.fileExists(atPath: location.path) else {
            cached = [:]
            return [:]
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let document = try decoder.decode(Document.self, from: Data(contentsOf: location))
            guard document.schemaVersion == Self.currentSchemaVersion else {
                throw ZynSignError.structuredCatalogUnreadable(
                    area: "revocation-reports",
                    diagnosticDetail: "The revocation report document declares schema version \(document.schemaVersion)."
                )
            }
            cached = document.reports
            return document.reports
        } catch let error as ZynSignError {
            throw error
        } catch {
            throw ZynSignError.structuredCatalogUnreadable(
                area: "revocation-reports",
                diagnosticDetail: "The revocation report document could not be read.",
                underlyingError: error
            )
        }
    }

    private func persist(_ reports: [String: StoredReport]) throws {
        let document = Document(schemaVersion: Self.currentSchemaVersion, reports: reports)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)
        try FileManager.default.createDirectory(
            at: location.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: location, options: .atomic)
        cached = reports
    }

    func store(_ report: RevocationExposureReport, fingerprint: String) throws {
        access.lock()
        defer { access.unlock() }
        var reports = try loadedOrRead()
        reports[fingerprint] = StoredReport(
            verdict: report.verdict.rawValue,
            checkedAt: report.checkedAt,
            outcomes: report.outcomes.map { outcome in
                StoredOutcome(
                    channel: outcome.endpoint.channel.rawValue,
                    url: outcome.endpoint.url,
                    reachable: outcome.reachable,
                    statusCode: outcome.statusCode,
                    latencyMs: outcome.latencyMs
                )
            }
        )
        try persist(reports)
    }

    func report(forFingerprint fingerprint: String) throws -> RevocationExposureReport? {
        access.lock()
        defer { access.unlock() }
        guard let stored = try loadedOrRead()[fingerprint] else { return nil }
        let verdict = RevocationExposureReport.Verdict(rawValue: stored.verdict) ?? .notChecked
        let outcomes = stored.outcomes.map { outcome in
            EndpointProbeOutcome(
                endpoint: RevocationEndpoint(
                    channel: RevocationEndpoint.Channel(rawValue: outcome.channel) ?? .ocsp,
                    url: outcome.url
                ),
                reachable: outcome.reachable,
                statusCode: outcome.statusCode,
                latencyMs: outcome.latencyMs
            )
        }
        return RevocationExposureReport(
            verdict: verdict,
            outcomes: outcomes,
            checkedAt: stored.checkedAt
        )
    }

    func remove(fingerprint: String) throws {
        access.lock()
        defer { access.unlock() }
        var reports = try loadedOrRead()
        guard reports.removeValue(forKey: fingerprint) != nil else { return }
        try persist(reports)
    }
}
