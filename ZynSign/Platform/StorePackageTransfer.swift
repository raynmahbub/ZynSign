import Foundation

/// One foreground transfer. Suspension is supported only during this process;
/// relaunches become explicit interrupted jobs, not a false promise of resumption.
final class StorePackageTransfer: NSObject, URLSessionDownloadDelegate, StoreTransferring, @unchecked Sendable {
    private var session: URLSession!
    private var task: URLSessionDownloadTask!
    private let destination: URL
    private let expectedSize: Int64?
    private let progress: @Sendable (Double?) -> Void
    private let completion: @Sendable (Result<URL, Error>) -> Void
    private var result: Result<URL, Error>?
    private var lastProgress = Date.distantPast
    private static let limit: Int64 = 4 * 1024 * 1024 * 1024

    init(url: URL, destination: URL, expectedSize: Int64?, progress: @escaping @Sendable (Double?) -> Void,
         completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        self.destination = destination; self.expectedSize = expectedSize
        self.progress = progress; self.completion = completion
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 3600
        let delegateQueue = OperationQueue(); delegateQueue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        task = session.downloadTask(with: url)
    }
    func start() { task.resume() }
    func pause() { task.suspend() }
    func resume() { task.resume() }
    func cancel() { task.cancel() }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.flatMap { try? StoreURLPolicy.validate($0.absoluteString) } == nil ? nil : request)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > Self.limit || totalBytesExpectedToWrite > Self.limit {
            result = .failure(StoreFailure.invalid("The package exceeds the 4 GB limit.")); downloadTask.cancel(); return
        }
        guard Date().timeIntervalSince(lastProgress) >= 0.2 else { return }
        lastProgress = Date()
        progress(totalBytesExpectedToWrite > 0 ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let http = downloadTask.response as? HTTPURLResponse, http.statusCode == 200 else {
                throw StoreFailure.invalid("The package server did not return HTTP 200.")
            }
            let size = Int64(try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            guard size > 4, size <= Self.limit, expectedSize == nil || expectedSize == size else {
                throw StoreFailure.invalid("The package is empty, too large, or does not match the source's declared size.")
            }
            let handle = try FileHandle(forReadingFrom: location)
            defer { try? handle.close() }
            guard try handle.read(upToCount: 4) == Data([0x50, 0x4b, 0x03, 0x04]) else {
                throw StoreFailure.invalid("The response is not a ZIP/IPA container. No package was retained.")
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: destination)
            result = .success(destination)
        } catch { result = .failure(error) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        completion(result ?? .failure(error ?? StoreFailure.invalid("The transfer ended without a package.")))
        session.finishTasksAndInvalidate()
    }
}
