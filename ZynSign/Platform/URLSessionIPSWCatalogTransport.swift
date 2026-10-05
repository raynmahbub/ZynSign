import Foundation

/// Bounded, credential-free HTTPS transport for the public IPSW catalog.
final class URLSessionIPSWCatalogTransport: IPSWFirmwareCatalogTransport, @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(
                configuration: configuration,
                delegate: HTTPSRedirectPolicy(),
                delegateQueue: nil
            )
        }
    }

    func fetch(url: URL, timeout: TimeInterval) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else {
            throw IPSWFirmwareCatalogError.requestFailed
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ZynSign", forHTTPHeaderField: "User-Agent")

        // Stream the bounded JSON document so a bad or unexpectedly large
        // response cannot be materialized as an unbounded Data value.
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw IPSWFirmwareCatalogError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw IPSWFirmwareCatalogError.requestFailed
        }
        if response.expectedContentLength > Int64(IPSWFirmwareCatalogService.maximumResponseBytes) {
            throw IPSWFirmwareCatalogError.responseTooLarge
        }

        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(
                Int(response.expectedContentLength),
                IPSWFirmwareCatalogService.maximumResponseBytes
            ))
        }
        for try await byte in bytes {
            guard data.count < IPSWFirmwareCatalogService.maximumResponseBytes else {
                throw IPSWFirmwareCatalogError.responseTooLarge
            }
            data.append(byte)
        }
        return data
    }
}
