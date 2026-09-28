import XCTest
import Combine
@testable import ZynSign

@MainActor
final class StoreDownloadQueueTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("StoreQueueTests-\(UUID())") }
    func testQueueIsBoundedDeduplicatesAndSupportsLivePauseCancel() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let factory = StoreFakeTransferFactory()
        let queue = StoreDownloadQueue(directory: root, factory: factory)
        let first = try StoreFixtures.source().apps[0]
        let id = try XCTUnwrap(queue.enqueue(first, sourceName: "First"))
        XCTAssertEqual(queue.enqueue(first, sourceName: "First"), id)
        _ = queue.enqueue(try StoreFixtures.source().apps[0], sourceName: "Second")
        _ = queue.enqueue(try StoreFixtures.source().apps[0], sourceName: "Third")
        XCTAssertEqual(factory.transfers.count, 2)
        XCTAssertEqual(queue.jobs.filter { $0.state == .queued }.count, 1)
        queue.pause(id)
        XCTAssertEqual(queue.jobs[0].state, .paused)
        XCTAssertEqual(factory.transfers[0].pauses, 1)
        queue.resume(id)
        XCTAssertEqual(queue.jobs[0].state, .downloading)
        queue.cancel(id)
        XCTAssertEqual(queue.jobs[0].state, .cancelled)
        XCTAssertEqual(factory.transfers.count, 3)
        XCTAssertEqual(factory.transfers[0].cancels, 1)
        for job in queue.jobs { queue.cancel(job.id) }
    }
    func testRetryUsesNewAttemptIdentityButSameSourceAndRelease() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let queue = StoreDownloadQueue(directory: root, factory: StoreFakeTransferFactory())
        let app = try StoreFixtures.source().apps[0]
        let id = try XCTUnwrap(queue.enqueue(app, sourceName: "Chosen Source"))
        queue.cancel(id); queue.retry(id)
        let retry = try XCTUnwrap(queue.jobs.first)
        XCTAssertNotEqual(retry.id, id)
        XCTAssertEqual(retry.sourceID, app.sourceID)
        XCTAssertEqual(retry.release, app.latest)
        XCTAssertEqual(retry.sourceName, "Chosen Source")
        queue.cancel(retry.id)
    }
    func testRelaunchDoesNotPretendAnInterruptedTransferResumed() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = StoreDownloadQueue(directory: root, factory: StoreFakeTransferFactory())
        let id = try XCTUnwrap(first.enqueue(try StoreFixtures.source().apps[0], sourceName: "Source"))
        first.pause(id)
        let secondFactory = StoreFakeTransferFactory()
        let second = StoreDownloadQueue(directory: root, factory: secondFactory)
        second.restore()
        XCTAssertEqual(second.jobs[0].state, .failed)
        XCTAssertTrue(second.jobs[0].failure?.contains("Interrupted") == true)
        XCTAssertTrue(secondFactory.transfers.isEmpty)
        first.cancel(id)
    }
    func testCompletionMakesPackageReadyButDoesNotImportOrInstall() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let factory = StoreFakeTransferFactory()
        let queue = StoreDownloadQueue(directory: root, factory: factory)
        _ = queue.enqueue(try StoreFixtures.source().apps[0], sourceName: "Source")
        let ready = expectation(description: "Ready for explicit import")
        // The completion handler assigns state and progress in two separate
        // @Published mutations, so the sink observes .ready twice; XCTest's
        // default over-fulfill assertion aborts the whole host process.
        ready.assertForOverFulfill = false
        let observation = queue.$jobs.sink { jobs in if jobs.first?.state == .ready { ready.fulfill() } }
        let file = queue.file(for: queue.jobs[0])
        try Data([0x50, 0x4b, 0x03, 0x04, 0]).write(to: file)
        factory.transfers[0].complete(.success(file))
        await fulfillment(of: [ready], timeout: 2)
        observation.cancel()
        XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertEqual(queue.jobs[0].state, .ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        queue.remove(queue.jobs[0].id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
    func testCorruptJournalRefusesNewWorkInsteadOfOverwritingIt() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = Data("bad journal".utf8), file = root.appendingPathComponent("jobs.json")
        try bytes.write(to: file)
        let factory = StoreFakeTransferFactory()
        let queue = StoreDownloadQueue(directory: root, factory: factory)
        XCTAssertNil(queue.enqueue(try StoreFixtures.source().apps[0], sourceName: "Source"))
        XCTAssertNotNil(queue.problem)
        XCTAssertTrue(factory.transfers.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
}
private final class StoreFakeTransferFactory: StoreTransferCreating, @unchecked Sendable {
    var transfers: [StoreFakeTransfer] = [] // only called by the main-actor test/queue
    func make(url: URL, destination: URL, expectedSize: Int64?, progress: @escaping @Sendable (Double?) -> Void,
              completion: @escaping @Sendable (Result<URL, Error>) -> Void) -> any StoreTransferring {
        let transfer = StoreFakeTransfer(completion: completion)
        transfers.append(transfer); return transfer
    }
}
private final class StoreFakeTransfer: StoreTransferring {
    var starts = 0, pauses = 0, resumes = 0, cancels = 0
    let complete: @Sendable (Result<URL, Error>) -> Void
    init(completion: @escaping @Sendable (Result<URL, Error>) -> Void) { complete = completion }
    func start() { starts += 1 }
    func pause() { pauses += 1 }
    func resume() { resumes += 1 }
    func cancel() { cancels += 1 }
}
