import Foundation

/// A transfer the Download Center has asked the platform to run.
struct DownloadTransferRequest: Equatable, Sendable {
    let jobID: DownloadJobIdentifier
    let url: URL
    let destinationDirectory: URL
    let resumeData: Data?
}

/// Bytes the platform has observed. `expectedBytes` is the server's declared
/// size, never a catalog hint.
struct DownloadTransferProgress: Equatable, Sendable {
    let receivedBytes: Int64
    let expectedBytes: Int64?
}

/// How a platform transfer ended.
///
/// `paused` carries resume data only when the platform produced it. `nil`
/// means the transfer cannot continue and a later attempt starts over.
enum DownloadTransferFinish: Equatable, Sendable {
    case completed(fileURL: URL, byteCount: Int64)
    case paused(resumeData: Data?)
    case failed(summary: String, detail: String?, retryable: Bool, resumeData: Data?)
    case cancelled
}

/// Receives transfer events. Implementations must hop to the main actor
/// before touching the center. The platform must not call these synchronously
/// from `start`, `pause`, or `cancel`.
protocol DownloadTransferObserver: AnyObject {
    func downloadTransfer(_ jobID: DownloadJobIdentifier, progress: DownloadTransferProgress)
    func downloadTransfer(_ jobID: DownloadJobIdentifier, finished: DownloadTransferFinish)
}

/// The platform boundary that moves bytes.
///
/// The center does not know whether the implementation is a foreground
/// session, a future background session, or a test double. Resume is whatever
/// `DownloadTransferFinish` reports — the center does not assume it.
protocol DownloadTransferring: AnyObject {
    func setObserver(_ observer: DownloadTransferObserver?)
    func start(_ request: DownloadTransferRequest)
    func pause(jobID: DownloadJobIdentifier)
    func cancel(jobID: DownloadJobIdentifier)
}

/// Validates a downloaded file without importing it.
protocol DownloadValidating: AnyObject {
    func validate(fileAt url: URL, expectedSHA256: String?) async -> DownloadArtifactValidation
}

/// Persistence and file isolation for the Download Center.
///
/// Every mutating method is confined to the center's own directory. Imported
/// library artifacts are not reachable through this port.
protocol DownloadCenterStoring: Sendable {
    func load() async throws -> DownloadCenterSnapshot?
    func save(_ snapshot: DownloadCenterSnapshot) async throws
    func prepareIncomingDirectory(jobID: DownloadJobIdentifier) async throws -> URL
    func promoteToArtifact(from fileURL: URL, jobID: DownloadJobIdentifier) async throws
    func isolate(from fileURL: URL, jobID: DownloadJobIdentifier) async throws
    func artifactURL(jobID: DownloadJobIdentifier) async -> URL?
    func removeJobFiles(jobID: DownloadJobIdentifier, includingArtifact: Bool) async
    func storeResumeData(_ data: Data, jobID: DownloadJobIdentifier) async throws
    func loadResumeData(jobID: DownloadJobIdentifier) async -> Data?
    func clearTemporaryData(keepingResumeFor jobIDs: Set<DownloadJobIdentifier>) async -> Int
    func storageReport(completedJobIDs: Set<DownloadJobIdentifier>) async -> DownloadStorageReport
    func recoverUnreferencedFiles(referencedJobIDs: Set<DownloadJobIdentifier>) async
}

/// Hands a validated file to the Import Hub. The center does not import by
/// any other path, and it does not sign.
protocol DownloadImporting: AnyObject {
    func importDownloadedPackage(at fileURL: URL) async -> [ImportJobIdentifier]
}

/// Hands a validated download to the Import Hub. The file is copied by the
/// hub's own intake. This type does not delete it and does not sign.
final class ImportHubDownloadImporter: DownloadImporting {
    private let hub: ImportHub

    /// Nonisolated so composition can build the importer while wiring the
    /// environment. The hub is only used after hopping to the main actor.
    nonisolated init(hub: ImportHub) {
        self.hub = hub
    }

    func importDownloadedPackage(at fileURL: URL) async -> [ImportJobIdentifier] {
        let hub = hub
        return await MainActor.run {
            hub.receive([fileURL], origin: .downloadCenter)
        }
    }
}

/// Local notifications for download outcomes. A refusal is not an error:
/// the in-app notice stands on its own.
protocol DownloadNotifying: Sendable {
    func notify(_ notice: DownloadNotice) async
}

/// A notifier that posts nothing.
struct UnavailableDownloadNotifier: DownloadNotifying {
    func notify(_ notice: DownloadNotice) async {}
}

/// Fetches repository metadata. The directory validates the bytes; the
/// fetcher only returns them, or throws when the network refuses.
protocol RepositoryCatalogFetching: Sendable {
    func fetch(from url: URL) async throws -> Data
}

/// Fetches an install manifest and returns the package address it names,
/// or `nil` when the manifest is missing, malformed, or does not name an
/// acceptable https package.
protocol InstallManifestResolving: Sendable {
    func resolveInstallManifest(at url: URL) async -> URL?
}
