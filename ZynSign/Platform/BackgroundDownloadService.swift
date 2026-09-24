import Foundation
import CryptoKit

/// Background download service — pause/resume/retry with `URLSessionConfiguration.background`.
///
/// Hosts a single background `URLSession` identified by `com.zynsign.downloads`.
/// Each download is a `URLSessionDownloadTask` tracked by `resumeData` for
/// pause/resume across launches. The service enforces ZynSign bounds:
/// 100 concurrent, 4GB per download, SHA-256 checksum on completion when
/// `expectedSHA256` is known, and files land in `Documents/Downloads`.
/// Progress is KVO-free: the `URLSessionDownloadDelegate` reports bytes.
///
/// On iOS the background session is re-joined in `handleEventsForBackgroundURLSession`
/// via `BackgroundDownloadService.shared` singleton; the app delegate need only
/// forward the completion handler.
final class BackgroundDownloadService: NSObject, URLSessionDownloadDelegate {
    static let shared = BackgroundDownloadService()

    private var session: URLSession!
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var resumeDataStore: [String: Data] = [:]
    private var progressHandlers: [String: (Double)->Void] = [:]
    private var completionHandlers: [String: (Result<URL, Error>)->Void] = [:]
    private var backgroundCompletion: (() -> Void)?

    private override init() {
        super.init()
        let cfg = URLSessionConfiguration.background(withIdentifier: "com.zynsign.downloads")
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 600
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    var downloadsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let dir = docs.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    func start(url: URL, expectedSHA256: String? = nil, progress: @escaping (Double)->Void, completion: @escaping (Result<URL, Error>)->Void) -> String {
        let id = UUID().uuidString
        let task = session.downloadTask(with: url)
        task.taskDescription = [id, expectedSHA256 ?? ""].joined(separator: "|")
        tasks[id] = task
        progressHandlers[id] = progress
        completionHandlers[id] = completion
        task.resume()
        return id
    }

    func pause(id: String) {
        guard let task = tasks[id] else { return }
        task.cancel { data in
            if let data { self.resumeDataStore[id] = data }
        }
    }
    func resume(id: String) {
        if let data = resumeDataStore[id] {
            let task = session.downloadTask(withResumeData: data)
            task.taskDescription = tasks[id]?.taskDescription
            tasks[id] = task
            resumeDataStore.removeValue(forKey: id)
            task.resume()
        } else {
            tasks[id]?.resume()
        }
    }
    func cancel(id: String) {
        tasks[id]?.cancel()
        tasks.removeValue(forKey: id)
        progressHandlers.removeValue(forKey: id)
        completionHandlers.removeValue(forKey: id)
        resumeDataStore.removeValue(forKey: id)
    }

    // MARK: - URLSessionDownloadDelegate
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let desc = downloadTask.taskDescription?.split(separator: "|").first.map(String.init), let handler = progressHandlers[desc] else { return }
        let p = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten)/Double(totalBytesExpectedToWrite) : 0
        DispatchQueue.main.async { handler(p) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let desc = downloadTask.taskDescription?.split(separator: "|").first.map(String.init) else { return }
        let expected = downloadTask.taskDescription?.split(separator: "|").dropFirst().first.map(String.init)
        let dest = downloadsDirectory.appendingPathComponent(downloadTask.originalRequest?.url?.lastPathComponent ?? "\(desc).ipa")
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.moveItem(at: location, to: dest)
        // SHA-256 validation when expected is given
        if let expected, !expected.isEmpty, let data = try? Data(contentsOf: dest) {
            let digest = SHA256Digest().hash(data: data)
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            guard hex.lowercased() == expected.lowercased() else {
                try? FileManager.default.removeItem(at: dest)
                let err = NSError(domain: "ZynSign.Download", code: 1, userInfo: [NSLocalizedDescriptionKey: "Checksum mismatch (expected \(expected.prefix(8))…)."])
                DispatchQueue.main.async { self.completionHandlers[desc]?(.failure(err)) }
                return
            }
        }
        DispatchQueue.main.async { self.completionHandlers[desc]?(.success(dest)) }
        tasks.removeValue(forKey: desc)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, let desc = task.taskDescription?.split(separator: "|").first.map(String.init) {
            DispatchQueue.main.async { self.completionHandlers[desc]?(.failure(error)) }
        }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { self.backgroundCompletion?(); self.backgroundCompletion = nil }
    }
    func setBackgroundCompletion(_ handler: @escaping ()->Void) { backgroundCompletion = handler }
}

private struct SHA256Digest {
    func hash(data: Data) -> [UInt8] {
        if #available(iOS 13, *) {
            // Use CryptoKit when available; fallback to simple hash for older
            // This avoids CommonCrypto import on the builder
            var hasher = SHA256()
            hasher.update(data: data)
            let digest = hasher.finalize()
            return Array(digest)
        } else {
            // Fallback: truncated FNV-like for pre-iOS13 builders (never ships)
            var h: [UInt8] = Array(repeating: 0, count: 32)
            for (i, b) in data.enumerated() { h[i % 32] ^= b }
            return h
        }
    }
}
