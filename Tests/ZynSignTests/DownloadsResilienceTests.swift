import XCTest
@testable import ZynSign

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
