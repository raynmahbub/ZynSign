import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Rejects redirects that leave the HTTPS, credential-free request policy.
/// URL validation must apply to the final URL, not only the user-supplied URL.
final class HTTPSRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              case .success = DownloadURLPolicy.validateHTTPS(url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

/// URLSession transport for release feed bodies. One bounded GET; any
/// non-success status is a typed refusal, because a feed that answers with
/// an error has nothing to parse.
final class URLSessionReleaseFeedTransport: ReleaseFeedTransport, @unchecked Sendable {

    /// The most feed bytes accepted. Feeds beyond this are refused before the
    /// complete body can be accumulated in memory.
    static let maximumBodyBytes = 4 * 1024 * 1024

    private let session: URLSession

    init(session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: HTTPSRedirectPolicy(), delegateQueue: nil)
    }()) {
        self.session = session
    }

    func fetch(url: URL, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("ZynSign", forHTTPHeaderField: "User-Agent")

        // `data(for:)` materializes the entire response before returning, so it
        // cannot enforce a memory bound. AsyncBytes returns after headers and
        // lets us stop as soon as the declared/actual body exceeds the policy.
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ZynSignError.releaseFeedUnavailable(
                diagnosticDetail: "The release feed answered with status \(http.statusCode)."
            )
        }
        if response.expectedContentLength > Int64(Self.maximumBodyBytes) {
            throw ZynSignError.releaseFeedUnavailable(
                diagnosticDetail: "The release feed body exceeded \(Self.maximumBodyBytes) bytes."
            )
        }

        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(response.expectedContentLength), Self.maximumBodyBytes))
        }
        for try await byte in bytes {
            guard data.count < Self.maximumBodyBytes else {
                throw ZynSignError.releaseFeedUnavailable(
                    diagnosticDetail: "The release feed body exceeded \(Self.maximumBodyBytes) bytes."
                )
            }
            data.append(byte)
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
