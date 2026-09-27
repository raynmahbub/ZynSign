import Foundation

/// Bounded snapshots, atomic replacement, no credentials. No cached report
/// is presented as current: only a new validation establishes current facts.
actor ReleaseReadinessHistory {
    private struct Envelope: Codable {
        let version: Int
        let reports: [ReleaseReadinessReport]
    }
    private let location: URL
    init(location: URL) { self.location = location }
    func reports() throws -> [ReleaseReadinessReport] {
        guard FileManager.default.fileExists(atPath: location.path) else { return [] }
        let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 8 * 1_024 * 1_024 else { throw HistoryError.unavailable }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: location))
        guard envelope.version == ReleaseReadinessReport.schemaVersion else { throw HistoryError.unavailable }
        return envelope.reports
    }
    func append(_ report: ReleaseReadinessReport) throws {
        try Task.checkCancellation()
        var values = try reports()
        values.insert(report, at: 0)
        var counts: [String: Int] = [:]
        values = Array(values.filter {
            counts[$0.recordID, default: 0] += 1
            return counts[$0.recordID, default: 0] <= 10
        }.prefix(50))
        let bytes = try JSONEncoder().encode(Envelope(version: ReleaseReadinessReport.schemaVersion, reports: values))
        guard bytes.count <= 8 * 1_024 * 1_024 else { throw HistoryError.unavailable }
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Task.checkCancellation()
        try bytes.write(to: location, options: .atomic)
    }
    enum HistoryError: Error { case unavailable }
}
