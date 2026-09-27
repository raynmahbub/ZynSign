import Foundation

/// File-backed Download Center storage.
///
/// The snapshot is replaced atomically and carries a revision. A stale save is
/// refused. Package files, partials, isolated rejects, and resume data live
/// under this store's root and nowhere else. Every deletion checks that the
/// target is inside that root, so a crafted job identifier cannot reach the
/// library or any other directory.
actor FileDownloadCenterStore: DownloadCenterStoring {

    static let currentSchemaVersion = 1

    let rootDirectory: URL

    private var knownRevision: Int?
    private let fileManager = FileManager.default

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    func load() async throws -> DownloadCenterSnapshot? {
        let location = snapshotURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: location.path, isDirectory: &isDirectory) else { return nil }
        guard !isDirectory.boolValue else {
            throw ZynSignError.downloadCenterSnapshotUnreadable(
                diagnosticDetail: "The download center location is a directory rather than a file."
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: location)
        } catch {
            throw ZynSignError.downloadCenterStorageFailure(
                diagnosticDetail: "The download center snapshot could not be read.",
                underlyingError: error
            )
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw ZynSignError.downloadCenterSnapshotUnreadable(
                diagnosticDetail: "The download center snapshot is not a document this build recognises.",
                underlyingError: error
            )
        }
        guard envelope.schemaVersion <= Self.currentSchemaVersion else {
            throw ZynSignError.downloadCenterSnapshotUnreadable(
                diagnosticDetail: "The download center snapshot declares schema version \(envelope.schemaVersion); this build reads up to version \(Self.currentSchemaVersion)."
            )
        }
        var seen = Set<String>()
        for job in envelope.snapshot.jobs {
            guard seen.insert(job.id).inserted else {
                throw ZynSignError.downloadCenterSnapshotUnreadable(
                    diagnosticDetail: "The download center snapshot lists a job more than once."
                )
            }
        }
        knownRevision = envelope.snapshot.revision
        return envelope.snapshot
    }

    func save(_ snapshot: DownloadCenterSnapshot) async throws {
        if let knownRevision, snapshot.revision < knownRevision {
            throw ZynSignError.downloadCenterStorageFailure(
                diagnosticDetail: "Refused a stale download center snapshot."
            )
        }
        do {
            try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Envelope(schemaVersion: Self.currentSchemaVersion, snapshot: snapshot))
            try data.write(to: snapshotURL, options: .atomic)
            knownRevision = snapshot.revision
        } catch let error as ZynSignError {
            throw error
        } catch {
            throw ZynSignError.downloadCenterStorageFailure(
                diagnosticDetail: "The download center snapshot could not be written.",
                underlyingError: error
            )
        }
    }

    func prepareIncomingDirectory(jobID: DownloadJobIdentifier) async throws -> URL {
        guard let directory = childDirectory(incomingRoot, jobID: jobID) else {
            throw ZynSignError.downloadCenterStorageFailure(diagnosticDetail: "Refused an unsafe download folder name.")
        }
        if fileManager.fileExists(atPath: directory.path) {
            try? fileManager.removeItem(at: directory)
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ZynSignError.downloadCenterStorageFailure(
                diagnosticDetail: "Could not prepare the download folder.",
                underlyingError: error
            )
        }
        return directory
    }

    func promoteToArtifact(from fileURL: URL, jobID: DownloadJobIdentifier) async throws {
        guard let destination = artifactURLUnchecked(jobID) else {
            throw ZynSignError.downloadCenterStorageFailure(diagnosticDetail: "Refused an unsafe artifact name.")
        }
        guard isInsideRoot(fileURL), fileManager.fileExists(atPath: fileURL.path) else {
            throw ZynSignError.downloadCenterStorageFailure(diagnosticDetail: "Refused to store a file from outside download storage.")
        }
        do {
            try fileManager.createDirectory(at: artifactsRoot, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: fileURL, to: destination)
        } catch {
            throw ZynSignError.downloadCenterStorageFailure(
                diagnosticDetail: "The validated download could not be stored.",
                underlyingError: error
            )
        }
    }

    func isolate(from fileURL: URL, jobID: DownloadJobIdentifier) async throws {
        guard let directory = childDirectory(isolatedRoot, jobID: jobID) else {
            throw ZynSignError.downloadCenterStorageFailure(diagnosticDetail: "Refused an unsafe isolation folder.")
        }
        guard isInsideRoot(fileURL), fileManager.fileExists(atPath: fileURL.path) else {
            throw ZynSignError.downloadCenterStorageFailure(diagnosticDetail: "Refused to isolate a file from outside download storage.")
        }
        let destination = directory.appendingPathComponent("payload", isDirectory: false)
        guard isInsideRoot(destination) else {
            throw ZynSignError.downloadCenterStorageFailure(diagnosticDetail: "Refused an isolation path outside download storage.")
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: fileURL, to: destination)
        } catch {
            throw ZynSignError.downloadCenterStorageFailure(
                diagnosticDetail: "The rejected download could not be isolated.",
                underlyingError: error
            )
        }
    }

    func artifactURL(jobID: DownloadJobIdentifier) async -> URL? {
        guard let url = artifactURLUnchecked(jobID), fileManager.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func removeJobFiles(jobID: DownloadJobIdentifier, includingArtifact: Bool) async {
        if let incoming = childDirectory(incomingRoot, jobID: jobID) { removeIfInsideRoot(incoming) }
        if let isolated = childDirectory(isolatedRoot, jobID: jobID) { removeIfInsideRoot(isolated) }
        if let resume = resumeURL(jobID) { removeIfInsideRoot(resume) }
        if includingArtifact, let artifact = artifactURLUnchecked(jobID) { removeIfInsideRoot(artifact) }
    }

    func storeResumeData(_ data: Data, jobID: DownloadJobIdentifier) async throws {
        guard let url = resumeURL(jobID) else {
            throw ZynSignError.downloadCenterStorageFailure(diagnosticDetail: "Refused an unsafe resume-data name.")
        }
        do {
            try fileManager.createDirectory(at: resumeRoot, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw ZynSignError.downloadCenterStorageFailure(
                diagnosticDetail: "Resume data could not be saved.",
                underlyingError: error
            )
        }
    }

    func loadResumeData(jobID: DownloadJobIdentifier) async -> Data? {
        guard let url = resumeURL(jobID) else { return nil }
        return try? Data(contentsOf: url)
    }

    func clearTemporaryData(keepingResumeFor jobIDs: Set<DownloadJobIdentifier>) async -> Int {
        let keep = Set(jobIDs.map(\.rawValue))
        var removed = 0
        removed += removeChildren(of: incomingRoot, keeping: keep)
        removed += removeChildren(of: isolatedRoot, keeping: [])
        removed += removeChildren(of: resumeRoot, keeping: keep, droppingExtension: "resume")
        return removed
    }

    func storageReport(completedJobIDs: Set<DownloadJobIdentifier>) async -> DownloadStorageReport {
        let artifacts = files(in: artifactsRoot)
        let artifactBytes = artifacts.reduce(Int64(0)) { $0 + size(of: $1) }
        let completedNames = Set(completedJobIDs.map { $0.rawValue + ".ipa" })
        let completedFiles = artifacts.filter { completedNames.contains($0.lastPathComponent) }
        let temporaryFiles = files(in: incomingRoot) + files(in: isolatedRoot) + files(in: resumeRoot)
        return DownloadStorageReport(
            downloadedIPABytes: artifactBytes,
            downloadedIPACount: artifacts.count,
            completedDownloadCount: completedFiles.count,
            completedRetainedBytes: completedFiles.reduce(Int64(0)) { $0 + size(of: $1) },
            temporaryBytes: temporaryFiles.reduce(Int64(0)) { $0 + size(of: $1) },
            temporaryCount: temporaryFiles.count
        )
    }

    func recoverUnreferencedFiles(referencedJobIDs: Set<DownloadJobIdentifier>) async {
        let keep = Set(referencedJobIDs.map(\.rawValue))
        _ = removeChildren(of: incomingRoot, keeping: keep)
        _ = removeChildren(of: isolatedRoot, keeping: keep)
        _ = removeChildren(of: resumeRoot, keeping: keep, droppingExtension: "resume")
        _ = removeChildren(of: artifactsRoot, keeping: keep, droppingExtension: "ipa")
    }

    // MARK: - Locations

    private var snapshotURL: URL { rootDirectory.appendingPathComponent("center.json") }
    private var incomingRoot: URL { rootDirectory.appendingPathComponent("Incoming", isDirectory: true) }
    private var isolatedRoot: URL { rootDirectory.appendingPathComponent("Isolated", isDirectory: true) }
    private var artifactsRoot: URL { rootDirectory.appendingPathComponent("Artifacts", isDirectory: true) }
    private var resumeRoot: URL { rootDirectory.appendingPathComponent("Resume", isDirectory: true) }

    private func artifactURLUnchecked(_ jobID: DownloadJobIdentifier) -> URL? {
        guard isSafeComponent(jobID.rawValue) else { return nil }
        let url = artifactsRoot.appendingPathComponent(jobID.rawValue).appendingPathExtension("ipa")
        return isInsideRoot(url) ? url : nil
    }

    private func resumeURL(_ jobID: DownloadJobIdentifier) -> URL? {
        guard isSafeComponent(jobID.rawValue) else { return nil }
        let url = resumeRoot.appendingPathComponent(jobID.rawValue).appendingPathExtension("resume")
        return isInsideRoot(url) ? url : nil
    }

    private func childDirectory(_ root: URL, jobID: DownloadJobIdentifier) -> URL? {
        guard isSafeComponent(jobID.rawValue) else { return nil }
        let url = root.appendingPathComponent(jobID.rawValue, isDirectory: true)
        return isInsideRoot(url) ? url : nil
    }

    private func isSafeComponent(_ name: String) -> Bool {
        !name.isEmpty && name == (name as NSString).lastPathComponent && !name.contains("..") && !name.contains("/")
    }

    private func isInsideRoot(_ url: URL) -> Bool {
        let root = rootDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
    }

    private func removeIfInsideRoot(_ url: URL) {
        guard isInsideRoot(url) else { return }
        try? fileManager.removeItem(at: url)
    }

    private func removeChildren(of directory: URL, keeping: Set<String>, droppingExtension: String? = nil) -> Int {
        guard isInsideRoot(directory),
              let children = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else {
            return 0
        }
        var removed = 0
        for child in children {
            guard isInsideRoot(child) else { continue }
            let token = droppingExtension == nil ? child.lastPathComponent : child.deletingPathExtension().lastPathComponent
            guard !keeping.contains(token) else { continue }
            try? fileManager.removeItem(at: child)
            removed += 1
        }
        return removed
    }

    private func files(in directory: URL) -> [URL] {
        guard isInsideRoot(directory),
              let children = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles) else {
            return []
        }
        var found: [URL] = []
        for child in children where isInsideRoot(child) {
            let values = try? child.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isRegularFile == true {
                found.append(child)
            } else if values?.isDirectory == true {
                found.append(contentsOf: files(in: child))
            }
        }
        return found
    }

    private func size(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private struct Envelope: Codable {
        var schemaVersion: Int
        var snapshot: DownloadCenterSnapshot
    }
}
