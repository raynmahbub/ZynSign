import Foundation
import Combine

struct StoreDownloadJob: Codable, Identifiable, Equatable {
    enum State: String, Codable { case queued, downloading, paused, ready, failed, cancelled }
    let id: UUID
    let appID: String
    let sourceID: UUID
    let sourceName: String
    let name: String
    let bundleID: String
    let release: CatalogRelease
    var state: State = .queued
    var progress: Double?
    var failure: String?
}

/// Persisted, bounded queue parallel to SigningQueue, sharing scheduling policy.
/// Only an explicit import crosses into ImportHub's existing validation/job queue.
@MainActor
final class StoreDownloadQueue: ObservableObject {
    @Published private(set) var jobs: [StoreDownloadJob] = []
    @Published var problem: String?
    private let directory: URL
    private var transfers: [UUID: any StoreTransferring] = [:]
    private let factory: any StoreTransferCreating
    private var restored = false
    nonisolated init(directory: URL, factory: any StoreTransferCreating = StoreTransferFactory()) {
        self.directory = directory; self.factory = factory
    }
    private var journal: URL { directory.appendingPathComponent("jobs.json") }
    func file(for job: StoreDownloadJob) -> URL { directory.appendingPathComponent(job.id.uuidString + ".ipa") }

    func restore() {
        guard !restored else { return }
        do {
            if FileManager.default.fileExists(atPath: journal.path) {
                let size = try journal.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 8 * 1024 * 1024 else { throw StoreFailure.invalid("The download journal is too large.") }
                let data = try Data(contentsOf: journal)
                var loaded = try JSONDecoder().decode([StoreDownloadJob].self, from: data)
                guard loaded.count <= 500, Set(loaded.map(\.id)).count == loaded.count else { throw StoreFailure.invalid("Invalid download journal.") }
                for i in loaded.indices {
                    _ = try StoreURLPolicy.validate(loaded[i].release.downloadURL.absoluteString)
                    if [.queued, .downloading, .paused].contains(loaded[i].state) {
                        loaded[i].state = .failed; loaded[i].failure = "Interrupted. Retry starts a fresh transfer."
                    } else if loaded[i].state == .ready && !FileManager.default.fileExists(atPath: file(for: loaded[i]).path) {
                        loaded[i].state = .failed; loaded[i].failure = "The downloaded file is missing."
                    }
                }
                jobs = loaded
            }
            restored = true; save()
        } catch { problem = "Could not restore downloads: \(error.localizedDescription)" }
    }
    @discardableResult
    func enqueue(_ app: CatalogApp, sourceName: String) -> UUID? {
        restore()
        guard restored else { return nil }
        if let job = jobs.first(where: { $0.appID == app.id && $0.release == app.latest && ![.failed, .cancelled].contains($0.state) }) { return job.id }
        guard jobs.count < 500 else { problem = "Remove finished jobs before adding more downloads."; return nil }
        guard (try? StoreURLPolicy.validate(app.latest.downloadURL.absoluteString)) != nil else { problem = "Unsafe download URL."; return nil }
        let job = StoreDownloadJob(id: UUID(), appID: app.id, sourceID: app.sourceID, sourceName: sourceName,
                                   name: app.name, bundleID: app.bundleID, release: app.latest)
        jobs.append(job)
        guard save() else { jobs.removeAll { $0.id == job.id }; return nil }
        pump(); return job.id
    }
    func pause(_ id: UUID) {
        guard let i = index(id), jobs[i].state == .downloading else { return }
        transfers[id]?.pause(); jobs[i].state = .paused; save()
    }
    func resume(_ id: UUID) {
        guard let i = index(id), jobs[i].state == .paused else { return }
        jobs[i].state = .downloading; transfers[id]?.resume(); save()
    }
    func cancel(_ id: UUID) {
        guard let i = index(id), [.queued, .downloading, .paused].contains(jobs[i].state) else { return }
        jobs[i].state = .cancelled
        transfers[id]?.cancel(); transfers[id] = nil; save(); pump()
    }
    func retry(_ id: UUID) {
        guard let i = index(id), [.failed, .cancelled].contains(jobs[i].state) else { return }
        // Do not overlap a cancelling delegate with a fresh attempt for the same ID.
        let old = jobs[i]
        jobs.remove(at: i)
        jobs.append(StoreDownloadJob(id: UUID(), appID: old.appID, sourceID: old.sourceID,
            sourceName: old.sourceName, name: old.name, bundleID: old.bundleID, release: old.release))
        try? FileManager.default.removeItem(at: file(for: old))
        save(); pump()
    }
    func remove(_ id: UUID) {
        guard let i = index(id), [.ready, .failed, .cancelled].contains(jobs[i].state) else { return }
        do {
            let url = file(for: jobs[i])
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            jobs.remove(at: i); save()
        } catch { problem = error.localizedDescription }
    }
    func importPackage(_ job: StoreDownloadJob, into hub: ImportHub) -> Bool {
        guard let current = jobs.first(where: { $0.id == job.id }), current.state == .ready,
              FileManager.default.fileExists(atPath: file(for: current).path) else {
            problem = "The package is not available. Retry the download."; return false
        }
        hub.receive([file(for: current)], origin: .storeDownload)
        return true
    }
    private func index(_ id: UUID) -> Int? { jobs.firstIndex { $0.id == id } }
    private func pump() {
        while JobQueueCapacity.hasCapacity(running: transfers.count, limit: 2), let job = jobs.first(where: { $0.state == .queued }) {
            guard let i = index(job.id) else { return }
            jobs[i].state = .downloading
            guard save() else { jobs[i].state = .queued; return }
            let transfer = factory.make(url: job.release.downloadURL, destination: file(for: job), expectedSize: job.release.size,
                progress: { [weak self] progress in
                    Task { @MainActor in
                        guard let self, let i = self.index(job.id), self.jobs[i].state == .downloading else { return }
                        self.jobs[i].progress = progress.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
                    }
                }, completion: { [weak self] result in
                    Task { @MainActor in self?.settle(job.id, result: result) }
                })
            transfers[job.id] = transfer; transfer.start()
        }
    }
    private func settle(_ id: UUID, result: Result<URL, Error>) {
        transfers[id] = nil
        guard let i = index(id), [.downloading, .paused].contains(jobs[i].state) else {
            // A late cancelled attempt may only clean its own UUID-named file.
            let state = index(id).map { jobs[$0].state }
            if state == nil || state == .cancelled {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString + ".ipa"))
            }
            pump(); return
        }
        switch result {
        case .success(let url):
            guard url.standardizedFileURL == file(for: jobs[i]).standardizedFileURL,
                  FileManager.default.fileExists(atPath: url.path) else {
                jobs[i].state = .failed; jobs[i].failure = "The transfer did not deliver an isolated package."
                save(); pump(); return
            }
            jobs[i].state = .ready; jobs[i].progress = 1
        case .failure(let error): jobs[i].state = .failed; jobs[i].failure = error.localizedDescription
        }
        save(); pump()
    }
    @discardableResult
    private func save() -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(jobs)
            guard data.count <= 8 * 1024 * 1024 else { throw StoreFailure.invalid("The download journal is full. Remove finished jobs first.") }
            try data.write(to: journal, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch { problem = "Download state could not be saved: \(error.localizedDescription)"; return false }
    }
}
