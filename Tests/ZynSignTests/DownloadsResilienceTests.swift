import XCTest
@testable import ZynSign

private final class HoldingDownloadURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

/// Downloads resilience: the guarantees that can be checked without starting
/// a transfer, kept honest about what they do not cover.
final class DownloadsResilienceTests: XCTestCase {

    func testDownloadURLPolicyEnforcesSizeAndProtocolBounds() {
        // Enforces the 4GB cap and refuses insecure transport
        XCTAssertEqual(DownloadURLPolicy.maximumArtifactBytes, 4 * 1024 * 1024 * 1024)
        XCTAssertEqual(DownloadURLPolicy.maximumCatalogBytes, 8 * 1024 * 1024)

        let httpURL = URL(string: "http://example.com/app.ipa")!
        XCTAssertEqual(DownloadURLPolicy.validateHTTPS(httpURL), .failure(.insecureTransport))

        let noHostURL = URL(string: "https:///app.ipa")!
        XCTAssertEqual(DownloadURLPolicy.validateHTTPS(noHostURL), .failure(.missingHost))
    }

    func testDownloadTransferAppliesHTTPSPolicyToRedirects() throws {
        let source = try XCTUnwrap(URL(string: "https://example.com/app.ipa"))
        let response = try XCTUnwrap(HTTPURLResponse(url: source, statusCode: 302, httpVersion: nil, headerFields: nil))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: source)
        let transfer = URLSessionDownloadTransfer()

        for (address, allowed) in [
            ("https://cdn.example.com/app.ipa", true),
            ("http://cdn.example.com/app.ipa", false),
            ("https://user:password@cdn.example.com/app.ipa", false),
        ] {
            let request = URLRequest(url: try XCTUnwrap(URL(string: address)))
            var result: URLRequest?
            transfer.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) {
                result = $0
            }
            XCTAssertEqual(result != nil, allowed, address)
        }
    }

    func testTransferRejectsInsecureInitialAddress() throws {
        final class Observer: DownloadTransferObserver {
            let onFinish: (DownloadTransferFinish) -> Void
            init(onFinish: @escaping (DownloadTransferFinish) -> Void) { self.onFinish = onFinish }
            func downloadTransfer(_ jobID: DownloadJobIdentifier, progress: DownloadTransferProgress) {}
            func downloadTransfer(_ jobID: DownloadJobIdentifier, finished: DownloadTransferFinish) {
                onFinish(finished)
            }
        }
        let done = expectation(description: "insecure address rejected")
        let observer = Observer { result in
            if case .failed(_, _, let retryable, _) = result {
                XCTAssertFalse(retryable)
            } else {
                XCTFail("Expected transfer failure, got \(result)")
            }
            done.fulfill()
        }
        let transfer = URLSessionDownloadTransfer()
        transfer.setObserver(observer)
        transfer.start(DownloadTransferRequest(
            jobID: DownloadJobIdentifier(),
            url: try XCTUnwrap(URL(string: "http://example.com/app.ipa")),
            destinationDirectory: FileManager.default.temporaryDirectory,
            resumeData: nil
        ))
        wait(for: [done], timeout: 2)
        withExtendedLifetime(observer) {}
    }

    func testOldTaskCallbacksCannotFinishOrReportProgressForReplacement() throws {
        final class Observer: DownloadTransferObserver {
            var progressCount = 0
            var finishes: [DownloadTransferFinish] = []
            let cancelled: XCTestExpectation
            init(_ cancelled: XCTestExpectation) { self.cancelled = cancelled }
            func downloadTransfer(_ jobID: DownloadJobIdentifier, progress: DownloadTransferProgress) { progressCount += 1 }
            func downloadTransfer(_ jobID: DownloadJobIdentifier, finished: DownloadTransferFinish) {
                finishes.append(finished)
                cancelled.fulfill()
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HoldingDownloadURLProtocol.self]
        var session: URLSession!
        var queue: OperationQueue!
        let transfer = URLSessionDownloadTransfer(configuration: configuration) { config, delegate, delegateQueue in
            queue = delegateQueue
            session = URLSession(configuration: config, delegate: delegate, delegateQueue: delegateQueue)
            return session
        }
        defer { session.invalidateAndCancel() }
        let cancelled = expectation(description: "replacement cancelled")
        let observer = Observer(cancelled)
        transfer.setObserver(observer)
        let id = DownloadJobIdentifier()
        let request = DownloadTransferRequest(
            jobID: id,
            url: try XCTUnwrap(URL(string: "https://example.com/held.ipa")),
            destinationDirectory: FileManager.default.temporaryDirectory,
            resumeData: nil
        )
        transfer.start(request)
        let found = expectation(description: "first task registered")
        var oldTask: URLSessionDownloadTask?
        queue.addOperation {
            session.getAllTasks { tasks in
                oldTask = tasks.first as? URLSessionDownloadTask
                found.fulfill()
            }
        }
        wait(for: [found], timeout: 5)
        let previous = try XCTUnwrap(oldTask)
        transfer.start(request)
        let checked = expectation(description: "old callbacks ignored")
        let staleFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1, 2, 3]).write(to: staleFile)
        defer { try? FileManager.default.removeItem(at: staleFile) }
        queue.addOperation {
            transfer.urlSession(session, downloadTask: previous, didWriteData: 1, totalBytesWritten: 1, totalBytesExpectedToWrite: 10)
            transfer.urlSession(session, downloadTask: previous, didFinishDownloadingTo: staleFile)
            transfer.urlSession(session, task: previous, didCompleteWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
            XCTAssertTrue(FileManager.default.fileExists(atPath: staleFile.path))
            XCTAssertEqual(observer.progressCount, 0)
            XCTAssertTrue(observer.finishes.isEmpty)
            checked.fulfill()
        }
        wait(for: [checked], timeout: 5)
        transfer.cancel(jobID: id)
        wait(for: [cancelled], timeout: 5)
        XCTAssertEqual(observer.finishes.count, 1)
        if case .cancelled = observer.finishes[0] {} else { XCTFail("Expected replacement cancellation") }
        withExtendedLifetime(observer) {}
    }

    func testDownloadTransferHonestyPromises() {
        // Background relaunch and universal resume are intentionally not claimed
        XCTAssertFalse(DownloadTransferHonesty.claimsBackgroundRelaunch)
        XCTAssertFalse(DownloadTransferHonesty.claimsUniversalResume)
    }

    func testDownloadResumeFactsReflectHonestCapabilities() {
        let notCaptured = DownloadResumeFact.notCaptured
        XCTAssertTrue(notCaptured.explanation.contains("starts it again"))

        let held = DownloadResumeFact.held
        XCTAssertTrue(held.explanation.contains("depends on the server"))
    }

    func testFileDownloadCenterStoreIsolatesArtifactsUnderRootDirectory() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadsResilienceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let store = FileDownloadCenterStore(rootDirectory: temp)
        let jobID = DownloadJobIdentifier()
        let incoming = try await store.prepareIncomingDirectory(jobID: jobID)
        let incomingPath = incoming.standardizedFileURL.path
        let rootPath = temp.standardizedFileURL.path
        XCTAssertTrue(
            incomingPath == rootPath || incomingPath.hasPrefix(rootPath + "/"),
            "\(incomingPath) is outside the download store root"
        )
    }

    func testPausingOrCancellingUnknownTransferIsANoOp() {
        let transfer = URLSessionDownloadTransfer()
        let unknownID = DownloadJobIdentifier()
        // Must not crash or throw on an unknown job
        transfer.pause(jobID: unknownID)
        transfer.cancel(jobID: unknownID)
    }
}
