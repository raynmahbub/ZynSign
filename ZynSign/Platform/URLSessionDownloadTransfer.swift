import Foundation

/// Foreground `URLSession` transfers for the Download Center.
///
/// This is not a background session, and it does not claim that a download
/// survives the process being killed. `waitsForConnectivity` keeps a live
/// task waiting through a brief network loss. Pause produces resume data only
/// when URLSession produces it. If it does not, the center is told so, and a
/// later attempt starts over. A server that rejects resume data fails the
/// attempt; the center does not describe that failure as a successful resume.
///
/// A background session that relaunches the app is intentionally not used.
/// ZynSign does not install `handleEventsForBackgroundURLSession`, so claiming
/// that behavior would be false.
///
/// Session callbacks and control calls share one serial queue. Progress is
/// reported a few times a second so a large package does not flood the
/// interface.
final class URLSessionDownloadTransfer: NSObject, URLSessionDownloadDelegate, DownloadTransferring {

    private let callbackQueue: OperationQueue
    private var session: URLSession?
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var destinations: [String: URL] = [:]
    private var pauseRequested: Set<String> = []
    private var finished: Set<String> = []
    private var lastProgressReport: [String: Date] = [:]
    private weak var observer: DownloadTransferObserver?
    private let maximumBytes: Int64
    private let progressInterval: TimeInterval = 0.25

    init(
        maximumBytes: Int64 = DownloadURLPolicy.maximumArtifactBytes,
        configuration: URLSessionConfiguration? = nil,
        makeSession: (URLSessionConfiguration, URLSessionDownloadDelegate, OperationQueue) -> URLSession = {
            URLSession(configuration: $0, delegate: $1, delegateQueue: $2)
        }
    ) {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "zynsign.download.transfer"
        self.callbackQueue = queue
        self.maximumBytes = maximumBytes
        super.init()
        let sessionConfiguration = configuration ?? URLSessionConfiguration.default
        sessionConfiguration.waitsForConnectivity = true
        sessionConfiguration.timeoutIntervalForRequest = 60
        sessionConfiguration.timeoutIntervalForResource = 60 * 60 * 4
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.urlCache = nil
        session = makeSession(sessionConfiguration, self, queue)
    }

    func setObserver(_ observer: DownloadTransferObserver?) {
        callbackQueue.addOperation { [weak self] in
            self?.observer = observer
        }
    }

    func start(_ request: DownloadTransferRequest) {
        callbackQueue.addOperation { [weak self] in
            self?.startOnQueue(request)
        }
    }

    func pause(jobID: DownloadJobIdentifier) {
        callbackQueue.addOperation { [weak self] in
            self?.pauseOnQueue(jobID)
        }
    }

    func cancel(jobID: DownloadJobIdentifier) {
        callbackQueue.addOperation { [weak self] in
            self?.cancelOnQueue(jobID)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        HTTPSRedirectPolicy().urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: request,
            completionHandler: completionHandler
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let jobID = activeJobID(of: downloadTask) else { return }
        let key = jobID.rawValue
        guard !pauseRequested.contains(key) else { return }
        if totalBytesExpectedToWrite > maximumBytes || totalBytesWritten > maximumBytes {
            downloadTask.cancel()
            finish(jobID, .failed(
                summary: "The download is larger than ZynSign will accept.",
                detail: nil,
                retryable: false,
                resumeData: nil
            ))
            return
        }
        let now = Date()
        let isFinal = totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite
        if let last = lastProgressReport[key], !isFinal, now.timeIntervalSince(last) < progressInterval {
            return
        }
        lastProgressReport[key] = now
        let expected: Int64? = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        observer?.downloadTransfer(jobID, progress: DownloadTransferProgress(
            receivedBytes: totalBytesWritten,
            expectedBytes: expected
        ))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let jobID = activeJobID(of: downloadTask) else { return }
        let key = jobID.rawValue
        guard !pauseRequested.contains(key) else { return }
        guard let directory = destinations[key] else {
            finish(jobID, .failed(summary: "The download finished without a destination.", detail: nil, retryable: true, resumeData: nil))
            return
        }
        guard let response = downloadTask.response as? HTTPURLResponse,
              let responseURL = response.url,
              case .success = DownloadURLPolicy.validateHTTPS(responseURL) else {
            finish(jobID, .failed(
                summary: "The download did not finish over an accepted HTTPS connection.",
                detail: nil,
                retryable: false,
                resumeData: nil
            ))
            return
        }
        guard (200...299).contains(response.statusCode) else {
            finish(jobID, .failed(
                summary: "The server refused the download (\(response.statusCode)).",
                detail: nil,
                retryable: true,
                resumeData: nil
            ))
            return
        }
        let destination = directory.appendingPathComponent("payload", isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            finish(jobID, .failed(
                summary: "The download could not be saved into its private folder.",
                detail: nil,
                retryable: true,
                resumeData: nil
            ))
            return
        }
        let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        guard bytes <= maximumBytes else {
            try? FileManager.default.removeItem(at: destination)
            finish(jobID, .failed(
                summary: "The download is larger than ZynSign will accept.",
                detail: nil,
                retryable: false,
                resumeData: nil
            ))
            return
        }
        tasks.removeValue(forKey: key)
        finish(jobID, .completed(fileURL: destination, byteCount: bytes))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let jobID = activeJobID(of: task) else { return }
        let key = jobID.rawValue
        // Keep the task associated with this attempt until the resume-data
        // callback arrives, so an older callback cannot finish a newer task.
        if pauseRequested.contains(key) { return }
        guard let error else {
            finish(jobID, .failed(
                summary: "The download completed without a saved file.",
                detail: nil,
                retryable: true,
                resumeData: nil
            ))
            return
        }
        let nsError = error as NSError
        let resume = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let cancelled = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
        if cancelled {
            finish(jobID, .cancelled)
            return
        }
        finish(jobID, .failed(
            summary: "The download stopped before it finished.",
            detail: resume == nil ? "No resume data was captured. A retry starts again." : DownloadResumeFact.held.explanation,
            retryable: true,
            resumeData: resume
        ))
    }

    // MARK: - Queue

    private func startOnQueue(_ request: DownloadTransferRequest) {
        let key = request.jobID.rawValue
        // Invalidate the old attempt before starting or rejecting its replacement.
        tasks.removeValue(forKey: key)?.cancel()
        destinations[key] = request.destinationDirectory
        finished.remove(key)
        pauseRequested.remove(key)
        lastProgressReport[key] = nil
        guard case .success = DownloadURLPolicy.validateHTTPS(request.url) else {
            finish(request.jobID, .failed(
                summary: "The download address must be HTTPS and must not contain credentials.",
                detail: nil,
                retryable: false,
                resumeData: nil
            ))
            return
        }
        guard let session else {
            finish(request.jobID, .failed(summary: "The download session is unavailable.", detail: nil, retryable: true, resumeData: nil))
            return
        }
        let task: URLSessionDownloadTask
        if let resumeData = request.resumeData, !resumeData.isEmpty {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: request.url)
        }
        task.taskDescription = key
        tasks[key] = task
        task.resume()
    }

    private func pauseOnQueue(_ jobID: DownloadJobIdentifier) {
        let key = jobID.rawValue
        guard let task = tasks[key] else {
            finish(jobID, .paused(resumeData: nil))
            return
        }
        guard pauseRequested.insert(key).inserted else { return }
        task.cancel(byProducingResumeData: { [weak self] data in
            self?.callbackQueue.addOperation {
                guard let self, self.activeJobID(of: task) == jobID,
                      self.pauseRequested.contains(key) else { return }
                self.finish(jobID, .paused(resumeData: data))
            }
        })
    }

    private func cancelOnQueue(_ jobID: DownloadJobIdentifier) {
        let key = jobID.rawValue
        tasks[key]?.cancel()
        finish(jobID, .cancelled)
    }

    /// A job can be restarted while URLSession still has callbacks queued for
    /// its previous task. Only the currently registered task may mutate it.
    private func activeJobID(of task: URLSessionTask) -> DownloadJobIdentifier? {
        guard let jobID = task.taskDescription.flatMap(DownloadJobIdentifier.init(rawValue:)),
              let current = tasks[jobID.rawValue], current === task else { return nil }
        return jobID
    }

    private func finish(_ jobID: DownloadJobIdentifier, _ result: DownloadTransferFinish) {
        let key = jobID.rawValue
        guard finished.insert(key).inserted else { return }
        pauseRequested.remove(key)
        destinations.removeValue(forKey: key)
        lastProgressReport[key] = nil
        tasks.removeValue(forKey: key)
        observer?.downloadTransfer(jobID, finished: result)
    }
}

/// Fetches repository documents and install manifests over https.
///
/// Bodies are size-capped. A non-success status or an oversized body produces
/// no catalog and no package address.
struct URLSessionRepositoryClient: RepositoryCatalogFetching, InstallManifestResolving {

    var timeout: TimeInterval = 20

    func fetch(from url: URL) async throws -> Data {
        guard case .success = DownloadURLPolicy.validateHTTPS(url) else {
            throw ZynSignError.downloadCenterStorageFailure(diagnosticDetail: "Refused a non-https repository address.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: HTTPSRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ZynSignError.downloadCenterStorageFailure(diagnosticDetail: "The repository request was not successful.")
        }
        let maximum = DownloadURLPolicy.maximumCatalogBytes
        if response.expectedContentLength > Int64(maximum) {
            throw ZynSignError.downloadCenterStorageFailure(diagnosticDetail: "The repository document exceeds the parse limit.")
        }
        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(response.expectedContentLength), maximum))
        }
        for try await byte in bytes {
            guard data.count < maximum else {
                throw ZynSignError.downloadCenterStorageFailure(diagnosticDetail: "The repository document exceeds the parse limit.")
            }
            data.append(byte)
        }
        return data
    }

    func resolveInstallManifest(at url: URL) async -> URL? {
        guard let data = try? await fetch(from: url) else { return nil }
        return InstallManifestParser.ipaURL(from: data)
    }
}
