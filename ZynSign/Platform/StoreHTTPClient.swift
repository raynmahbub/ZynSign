import Foundation

struct StoreHTTPResponse: Sendable {
    let data: Data
    let status: Int
    let etag: String?
    let modified: String?
}
protocol StoreFetching: Sendable {
    func fetch(_ url: URL, etag: String?, modified: String?, limit: Int) async throws -> StoreHTTPResponse
}

/// Prevent HTTPS downgrade/credential redirects before a request is sent.
final class StoreRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, (try? StoreURLPolicy.validate(url.absoluteString)) != nil else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}

struct StoreHTTPClient: StoreFetching {
    func fetch(_ url: URL, etag: String? = nil, modified: String? = nil, limit: Int) async throws -> StoreHTTPResponse {
        _ = try StoreURLPolicy.validate(url.absoluteString)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 60
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        let session = URLSession(configuration: config, delegate: StoreRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        request.setValue(modified, forHTTPHeaderField: "If-Modified-Since")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw StoreFailure.invalid("The source did not return an HTTP response.") }
        guard http.statusCode == 200 || http.statusCode == 304 else { throw StoreFailure.invalid("The server returned HTTP \(http.statusCode).") }
        guard response.expectedContentLength <= Int64(limit) else { throw StoreFailure.invalid("The server response exceeds the size limit.") }
        var data = Data()
        if http.statusCode == 200 {
            for try await byte in bytes {
                guard data.count < limit else { throw StoreFailure.invalid("The server response exceeds the size limit.") }
                data.append(byte)
            }
        }
        return StoreHTTPResponse(data: data, status: http.statusCode,
            etag: http.value(forHTTPHeaderField: "ETag"), modified: http.value(forHTTPHeaderField: "Last-Modified"))
    }
}
