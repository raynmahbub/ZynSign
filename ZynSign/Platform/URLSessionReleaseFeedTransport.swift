import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// URLSession transport for release feed bodies. One bounded GET; any
/// non-success status is a typed refusal, because a feed that answers with
/// an error has nothing to parse.
final class URLSessionReleaseFeedTransport: ReleaseFeedTransport, @unchecked Sendable {

    /// The most feed bytes accepted. Feeds beyond this are refused rather
    /// than buffered.
    static let maximumBodyBytes = 4 * 1024 * 1024

    private let session: URLSession

    init(session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()) {
        self.session = session
    }

    func fetch(url: URL, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("ZynSign", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ZynSignError.releaseFeedUnavailable(
                diagnosticDetail: "The release feed answered with status \(http.statusCode)."
            )
        }
        guard data.count <= Self.maximumBodyBytes else {
            throw ZynSignError.releaseFeedUnavailable(
                diagnosticDetail: "The release feed body exceeded \(Self.maximumBodyBytes) bytes."
            )
        }
        return data
    }
}

/// File-backed catalog of the repository feeds the user added.
final class FileReleaseFeedCatalog: ReleaseFeedCatalogStore, @unchecked Sendable {

    private struct Document: Codable {
        let schemaVersion: Int
        var feeds: [ReleaseFeedReference]
    }

    static let currentSchemaVersion = 1

    private let location: URL
    private let access = NSLock()
    private var cached: [ReleaseFeedReference]?

    init(location: URL) {
        self.location = location
    }

    private func loadedOrRead() throws -> [ReleaseFeedReference] {
        if let cached { return cached }
        guard FileManager.default.fileExists(atPath: location.path) else {
            cached = []
            return []
        }
        do {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: location))
            cached = document.feeds
            return document.feeds
        } catch {
            throw ZynSignError.releaseFeedUnreadable(
                diagnosticDetail: "The release feed catalog could not be read."
            )
        }
    }

    private func persist(_ feeds: [ReleaseFeedReference]) throws {
        let document = Document(schemaVersion: Self.currentSchemaVersion, feeds: feeds)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        try FileManager.default.createDirectory(
            at: location.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: location, options: .atomic)
        cached = feeds
    }

    func all() throws -> [ReleaseFeedReference] {
        access.lock()
        defer { access.unlock() }
        return try loadedOrRead()
    }

    func add(_ reference: ReleaseFeedReference) throws {
        access.lock()
        defer { access.unlock() }
        var feeds = try loadedOrRead()
        guard !feeds.contains(where: { $0.owner == reference.owner && $0.repository == reference.repository }) else { return }
        feeds.append(reference)
        try persist(feeds)
    }

    func replace(_ reference: ReleaseFeedReference) throws {
        access.lock()
        defer { access.unlock() }
        var feeds = try loadedOrRead()
        guard let index = feeds.firstIndex(where: { $0.owner == reference.owner && $0.repository == reference.repository }) else { return }
        feeds[index] = reference
        try persist(feeds)
    }

    func remove(_ reference: ReleaseFeedReference) throws {
        access.lock()
        defer { access.unlock() }
        var feeds = try loadedOrRead()
        let before = feeds.count
        feeds.removeAll { $0.owner == reference.owner && $0.repository == reference.repository }
        guard feeds.count != before else { return }
        try persist(feeds)
    }
}
